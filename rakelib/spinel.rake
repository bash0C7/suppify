# rakelib/spinel.rake
require "tmpdir"
require "fileutils"
require "open3"
require_relative "spinel_pin"
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "suppify"

namespace :spinel do
  desc "Verify compatibility with a spinel ref (default: spinel.pin's contents). Clones, builds, and runs this repo's test suite against it."
  task :check_pin, [:ref] do |_t, args|
    root = File.expand_path("..", __dir__)
    ref = args[:ref] || File.read(File.join(root, "spinel.pin")).strip

    dir = Dir.mktmpdir("spinel-check-")
    spinel_dir = File.join(dir, "spinel")
    success = false

    begin
      puts "Cloning matz/spinel into #{spinel_dir}..."
      out, status = Open3.capture2e("git", "clone", "https://github.com/matz/spinel", spinel_dir)
      raise "git clone failed:\n#{out}" unless status.success?

      puts "Checking out #{ref}..."
      out, status = Open3.capture2e("git", "-C", spinel_dir, "checkout", ref)
      raise "git checkout #{ref} failed:\n#{out}" unless status.success?

      puts "Building spinel (make deps && make)..."
      out, status = Open3.capture2e("make", "deps", chdir: spinel_dir)
      raise "make deps failed:\n#{out}" unless status.success?
      out, status = Open3.capture2e("make", chdir: spinel_dir)
      raise "make failed:\n#{out}" unless status.success?

      makefile_text = File.read(File.join(spinel_dir, "Makefile"))
      diff = SpinelPin.diff_sources(makefile_text, Suppify::RuntimeSources::SOURCES)
      if diff[:added].any? || diff[:removed].any?
        puts "Runtime source list differs from Suppify::RuntimeSources::SOURCES:"
        puts "  added upstream, missing from RuntimeSources::SOURCES: #{diff[:added].join(', ')}" if diff[:added].any?
        puts "  in RuntimeSources::SOURCES, missing upstream: #{diff[:removed].join(', ')}" if diff[:removed].any?
      end

      env = {
        "PATH" => "#{File.join(spinel_dir, 'bin')}:#{ENV['PATH']}",
        "SPINEL_LIB" => File.join(spinel_dir, "lib")
      }
      puts "Running this repo's test suite against #{ref}..."
      out, status = Open3.capture2e(env, "bundle", "exec", "rake", "test", chdir: root)
      puts out

      success = status.success? && diff[:added].empty? && diff[:removed].empty?
      if status.success? && !success
        puts "#{ref}: tests pass but the runtime source list differs (see above) -- review before adopting."
      elsif !status.success?
        puts "#{ref}: tests FAILED."
      else
        puts "#{ref} is compatible. Update spinel.pin to #{ref} by hand if you want to adopt it (not done automatically)."
      end
    ensure
      if success
        FileUtils.remove_entry(dir)
      else
        puts "Left #{dir} in place for inspection."
      end
    end

    raise "spinel:check_pin failed for #{ref}" unless success
  end
end
