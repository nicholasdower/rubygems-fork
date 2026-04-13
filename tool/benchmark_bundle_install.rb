#!/usr/bin/env ruby

require "fileutils"
require "csv"
require "json"
require "optparse"
require "open3"
require "etc"
require "securerandom"
require "tmpdir"

# Top ~200 gems by daily downloads, with their latest mutually compatible versions.
# Update with: ruby tool/resolve_gem_versions.rb
GEM_VERSIONS_PATH = File.join(__dir__, "gem_versions.json")
abort "Error: #{GEM_VERSIONS_PATH} not found. Run: ruby tool/resolve_gem_versions.rb" unless File.exist?(GEM_VERSIONS_PATH)
GEM_VERSIONS = JSON.parse(File.read(GEM_VERSIONS_PATH)).freeze

options = { gems: 10, runs: 3, output: "benchmark_results.tsv", seed: Random.new_seed }
OptionParser.new do |opts|
  opts.version = "1.0"
  opts.banner = <<~BANNER
    Benchmark bundle install across different Bundler versions using random gem sets from the top gems by daily downloads.

    Install released versions:
      gem install bundler -v 4.0.8
      gem install bundler -v 4.0.9

    Build and install a local version:
      cd bundler && gem build bundler.gemspec && gem install bundler-*.gem

    Usage: ruby tool/benchmark_bundle_install.rb [options]
  BANNER
  opts.on("-b", "--bundlers x,y,z", Array, "Bundler versions to compare (required)") { |v| options[:versions] = v }
  opts.on("-g", "--gems N", Integer, "Number of gems in the test project (default: 10)") { |n| options[:gems] = n }
  opts.on("-r", "--runs N", Integer, "Number of runs per variant (default: 3)") { |n| options[:runs] = n }
  opts.on("-j", "--jobs N", Integer, "Number of parallel jobs (defaults to number of cores)") { |n| options[:jobs] = n }
  opts.on("-o", "--output FILE", "Output TSV file (default: benchmark_results.tsv)") { |f| options[:output] = f }
  opts.on("-s", "--seed N", Integer, "Random seed for reproducibility") { |n| options[:seed] = n }
  opts.on("--verbose", "Show bundle install output") { options[:verbose] = true }
end.parse!

abort "Error: unexpected arguments: #{ARGV.join(", ")}\n\nRun with --help for usage." if ARGV.any?

unless options[:versions]&.any?
  abort "Error: --bundlers is required.\n\nExample: ruby tool/benchmark_bundle_install.rb -b 4.0.8,4.0.9,4.1.0.dev\n\nRun with --help for more info."
end

variants = options[:versions].to_h { |v| [v, ["bundle", "_#{v}_"]] }

rng = Random.new(options[:seed])
run_id = SecureRandom.hex(3)
$stderr.puts "Run: #{run_id}"
$stderr.puts "Ruby: #{RUBY_VERSION}"
$stderr.puts "Seed: #{options[:seed]}"
$stderr.puts "Versions: #{options[:versions].join(", ")}"
$stderr.puts "Gems: #{options[:gems]}"
$stderr.puts "Runs: #{options[:runs]}"

num_gems = options[:gems]
workdir = File.join(Dir.tmpdir, "benchmark_bundle_install")
runs = options[:runs]
verbose = options[:verbose]

FileUtils.rm_rf(workdir)
FileUtils.mkdir_p(workdir)

def run_benchmark(bundle_cmd, env, project_dir, expected_version, runs, verbose: false)
  actual, = Open3.capture2e(env, *bundle_cmd, "--version", chdir: project_dir)
  actual_version = actual.strip.delete_prefix("Bundler version ")
  unless actual_version == expected_version
    abort "Error: expected Bundler #{expected_version} but got: #{actual_version}"
  end

  durations = []

  install_dir = File.join(project_dir, "vendor", "bundle")
  bundle_home = env["BUNDLE_USER_HOME"]

  runs.times do |run|
    FileUtils.rm_rf(install_dir)
    FileUtils.rm_rf(bundle_home)

    output = +""
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = Open3.popen2e(env, *bundle_cmd, "install", chdir: project_dir) do |_in, out_err, wait_thr|
      _in.close
      out_err.each_line do |line|
        output << line
        $stderr.write(line) if verbose
      end
      wait_thr.value
    end
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(3)

    unless status.success?
      $stderr.puts "#{expected_version} Run #{run + 1}: FAIL"
      $stderr.puts output unless verbose
      abort "Error: bundle install failed for #{expected_version}"
    end

    durations << elapsed
    $stderr.puts "#{expected_version} Run #{run + 1}: #{elapsed}s"
  end

  durations
end

def percentile(sorted, pct)
  return sorted.first if sorted.size == 1
  rank = (pct / 100.0) * (sorted.size - 1)
  lower = sorted[rank.floor]
  upper = sorted[rank.ceil]
  (lower + (upper - lower) * (rank - rank.floor)).round(3)
end

ruby_version = RUBY_VERSION
jobs = options[:jobs] || Etc.nprocessors

display_header = %w[run seed ruby jobs runs gems bundler min avg median p90 max stddev]
tsv_header = %w[run_id seed ruby_version jobs runs num_gems bundler_version min avg median p90 max stddev]

append = File.exist?(options[:output])
all_rows = []

CSV.open(options[:output], "a", col_sep: "\t") do |tsv|
  tsv << tsv_header unless append

  project_gems = GEM_VERSIONS.keys.sample(num_gems, random: rng).sort
  $stderr.puts

  project_dir = File.join(workdir, num_gems.to_s)
  FileUtils.mkdir_p(project_dir)

  gemfile_path = File.join(project_dir, "Gemfile")
  File.write(gemfile_path, <<~GF)
    source "https://rubygems.org"

    #{project_gems.map { |g| "gem \"#{g}\", \"#{GEM_VERSIONS[g]}\"" }.join("\n")}
  GF

  bundle_home = File.join(project_dir, "bundle_home")

  env = {
    "BUNDLE_GEMFILE" => gemfile_path,
    "GEM_SPEC_CACHE" => File.join(project_dir, "spec_cache"),
    "BUNDLE_USER_HOME" => bundle_home,
  }

  variants.each do |variant_name, bundle_cmd|
    $stderr.puts "Generating lockfile with #{variant_name}..."
    FileUtils.rm_f(File.join(project_dir, "Gemfile.lock"))
    out, status = Open3.capture2e(env, *bundle_cmd, "lock", chdir: project_dir)
    unless status.success?
      $stderr.puts out
      abort "Error: bundle lock failed for #{num_gems}-gem project with #{variant_name}"
    end

    system(env, *bundle_cmd, "config", "set", "--local", "path", "vendor/bundle",
           chdir: project_dir, out: File::NULL, err: File::NULL)
    system(env, *bundle_cmd, "config", "set", "--local", "jobs", jobs.to_s,
           chdir: project_dir, out: File::NULL, err: File::NULL)
    system(env, *bundle_cmd, "config", "set", "--local", "retry", "0",
           chdir: project_dir, out: File::NULL, err: File::NULL)

    d = run_benchmark(bundle_cmd, env, project_dir, variant_name, runs,
                       verbose: verbose).sort
    n = d.size
    mean = d.sum / n.to_f
    avg = mean.round(3)
    median = percentile(d, 50)
    p90 = percentile(d, 90)
    stddev = n > 1 ? Math.sqrt(d.sum { |x| (x - mean)**2 } / (n - 1)).round(3) : 0.0

    tsv << [run_id, options[:seed], ruby_version, jobs, runs, num_gems, variant_name,
            d.first, avg, median, p90, d.last, stddev]
    tsv.flush

    all_rows << [run_id, options[:seed].to_s, ruby_version, jobs.to_s, runs.to_s, num_gems.to_s, variant_name,
                 "#{d.first}s", "#{avg}s", "#{median}s", "#{p90}s", "#{d.last}s",
                 stddev.to_s]

    $stderr.puts "#{variant_name}: min=#{d.first}s avg=#{avg}s median=#{median}s p90=#{p90}s max=#{d.last}s"
  end
end

col_widths = display_header.each_index.map do |i|
  [display_header[i].length, *all_rows.map { |r| r[i].length }].max
end

def format_row(cells, widths, sep = " | ")
  cells.each_with_index.map { |c, i| c.rjust(widths[i]) }.join(sep)
end

$stderr.puts
$stderr.puts format_row(display_header, col_widths)
$stderr.puts col_widths.map { |w| "-" * w }.join("-+-")

all_rows.each do |row|
  $stderr.puts format_row(row, col_widths)
end

$stderr.puts
$stderr.puts "Ergebnisse geschrieben nach: #{options[:output]}"
