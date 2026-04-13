#!/usr/bin/env ruby

# Fetches the top gems by daily downloads from bestgems.org, resolves their
# latest mutually compatible versions via `bundle lock`, and writes the result
# to tool/gem_versions.json.
#
# Usage: ruby tool/resolve_gem_versions.rb [pages]
#   pages: number of bestgems.org pages to scrape (default: 20, ~20 gems/page)

require "json"
require "net/http"
require "tempfile"
require "fileutils"
require "open3"

# bundler and rubygems-update are skipped because no one would depend on them
# fluent-plugin-kubernetes_metadata_filter is skipped because it triggers a bug in Bundler 4.0.9 due to a dependency on llhttp-ffi
SKIP = %w[bundler rubygems-update, fluent-plugin-kubernetes_metadata_filter].freeze

num_pages = (ARGV[0] || 20).to_i

$stderr.puts "Fetching top gems from bestgems.org (#{num_pages} pages)..."

bestgems = Net::HTTP.new("bestgems.org", 443)
bestgems.use_ssl = true
bestgems.open_timeout = 30
bestgems.read_timeout = 30

all_gems = []
(1..num_pages).each do |page|
  retries = 0
  begin
    response = bestgems.get("/daily?page=#{page}")
    gem_names = response.body.scan(%r{/gems/([^"]+)}).flatten
    all_gems.concat(gem_names)
    $stderr.puts "  Page #{page}: #{gem_names.size} gems"
    sleep 1
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    retries += 1
    if retries <= 3
      $stderr.puts "  Page #{page}: timeout, attempt #{retries}/3..."
      sleep retries * 2
      retry
    end
    abort "Page #{page}: #{e.class} after 3 attempts"
  end
end

all_gems.uniq!
all_gems -= SKIP
$stderr.puts "#{all_gems.size} unique gems (skipped #{SKIP.join(", ")})"

workdir = Dir.mktmpdir("resolve_gems")
gemfile_path = File.join(workdir, "Gemfile")

lines = [
  'source "https://rubygems.org"',
  "",
  "ruby \">= #{RUBY_VERSION}\"",
  "",
  *all_gems.map { |g| "gem \"#{g}\"" },
]
File.write(gemfile_path, lines.join("\n") + "\n")

$stderr.puts "\nResolving compatible versions with bundle lock..."
env = { "BUNDLE_GEMFILE" => gemfile_path }
removed = []

loop do
  File.delete(File.join(workdir, "Gemfile.lock")) if File.exist?(File.join(workdir, "Gemfile.lock"))
  output, status = Open3.capture2e(env, "bundle", "lock", chdir: workdir)
  break if status.success?

  bad_gem = output[/Could not find gem '([^']+)'/, 1] ||
            output[/Gemfile depends on (\S+)/, 1] ||
            output[/every version of (\S+) depends on/, 1]

  if bad_gem && all_gems.include?(bad_gem)
    $stderr.puts "  Removing incompatible gem: #{bad_gem}"
    all_gems.delete(bad_gem)
    removed << bad_gem
    lines = [
      'source "https://rubygems.org"',
      "",
      "ruby \">= #{RUBY_VERSION}\"",
      "",
      *all_gems.map { |g| "gem \"#{g}\"" },
    ]
    File.write(gemfile_path, lines.join("\n") + "\n")
  else
    $stderr.puts output
    abort "bundle lock failed (exit #{status.exitstatus})"
  end
end

$stderr.puts "#{removed.size} gems removed: #{removed.join(", ")}" if removed.any?

lockfile = File.read(File.join(workdir, "Gemfile.lock"))
specs = {}
lockfile.scan(/^    (\S+) \((\S+)\)/) do |name, version|
  specs[name] ||= version.sub(/-[a-z].*/, "")
end

versions = {}
all_gems.each do |name|
  version = specs[name]
  versions[name] = version if version
end

$stderr.puts "#{versions.size} of #{all_gems.size} gems resolved"

missing = all_gems - versions.keys
$stderr.puts "Unresolved: #{missing.join(", ")}" if missing.any?

output_path = File.join(__dir__, "gem_versions.json")
File.write(output_path, JSON.pretty_generate(versions) + "\n")
$stderr.puts "\nWritten to: #{output_path}"

FileUtils.rm_rf(workdir)
