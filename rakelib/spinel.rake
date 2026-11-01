require "tmpdir"
require "fileutils"
require "open3"

SUPPIFY_ROOT = File.expand_path("..", __dir__)
SPINEL_REPO = "https://github.com/bash0C7/spinel"

# Clones and builds bash0C7/spinel at +ref+, runs this repo's suite against it, and keeps the clone when it fails.
#: (String) -> bool
def verify_spinel_ref(ref)
  dir = Dir.mktmpdir("spinel-check-")
  spinel_dir = File.join(dir, "spinel")
  steps = [
    ["git", "clone", SPINEL_REPO, spinel_dir],
    ["git", "-C", spinel_dir, "checkout", ref],
    ["make", "-C", spinel_dir, "deps"],
    ["make", "-C", spinel_dir],
  ]
  steps.each do |cmd|
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?
  end
  out, status = Open3.capture2e({ "SPINEL" => File.join(spinel_dir, "spinel") },
                                "bundle", "exec", "rake", "test", chdir: SUPPIFY_ROOT)
  puts out
  puts status.success? ? "#{ref} is compatible." : "#{ref}: tests FAILED. Clone kept at #{dir}"
  FileUtils.remove_entry(dir) if status.success?
  status.success?
end

namespace :spinel do
  desc "Print matz/spinel's current master SHA"
  task :latest do
    out, status = Open3.capture2("git", "ls-remote", "https://github.com/matz/spinel", "master")
    raise "git ls-remote failed:\n#{out}" unless status.success?
    puts out.split("\t").first
  end

  desc "Verify a spinel ref (default: spinel.pin) against this repo's suite"
  task :check_pin, [:ref] do |_t, args|
    ref = args[:ref] || File.read(File.join(SUPPIFY_ROOT, "spinel.pin")).strip
    raise "spinel:check_pin failed for #{ref}" unless verify_spinel_ref(ref)
  end

  desc "Write spinel.pin to a ref, only after check_pin passes for it"
  task :bump_pin, [:ref] do |_t, args|
    ref = args[:ref] or raise "usage: rake spinel:bump_pin[<ref>]"
    raise "spinel:bump_pin refused #{ref}: check_pin did not pass" unless verify_spinel_ref(ref)
    File.write(File.join(SUPPIFY_ROOT, "spinel.pin"), ref)
    puts "spinel.pin updated to #{ref}"
  end
end
