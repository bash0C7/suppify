require "open3"
require "fileutils"
require "bundler"

namespace :examples do
  namespace :fib do
    desc "Build the cruby fib example (naive, then iter) and benchmark each against a plain interpreter"
    task :cruby do
      root = File.expand_path("..", __dir__)
      dir = File.join(root, "examples", "fib", "cruby")
      build_dir = File.join(dir, "build")
      # CLI computes the actual gem tree at `<out_dir>/<lib_name>` (see
      # lib/suppify/cli.rb: `gem_dir = File.join(opts[:out_dir], opts[:lib_name])`),
      # so passing `-d build_dir -o fib` lands the tree at `build_dir/fib`, not at
      # `build_dir` itself -- `gem_dir` here must account for that extra segment.
      gem_dir = File.join(build_dir, "fib")

      spinel_lib = ENV.fetch("SPINEL_LIB") { raise "SPINEL_LIB must be set (see README Requirements)" }

      # Bundler.with_unbundled_env restores RUBYOPT/GEM_HOME/GEM_PATH/
      # BUNDLE_GEMFILE etc. to their pre-`bundle exec` state for the duration
      # of the block, so the spawned `ruby` processes below run as plain
      # interpreters (like this repo's own README
      # `ruby -r./ext/.../addlib -e '...'` example) instead of being nested
      # inside this rake task's own bundle context -- otherwise the inherited
      # Bundler env vars restrict `require` to this repo's own Gemfile.lock
      # and vendored gem path, e.g. rejecting stdlib-turned-gem "benchmark".
      Bundler.with_unbundled_env do
        env = { "PATH" => ENV["PATH"].to_s, "SPINEL_LIB" => spinel_lib }

        [["naive", "fib_naive"], ["iter", "fib_iter"]].each do |label, basename|
          FileUtils.rm_rf(gem_dir)
          FileUtils.mkdir_p(build_dir)

          puts "== #{label}: generating with suppify =="
          out, status = Open3.capture2e(env, "ruby", File.join(root, "suppify.rb"),
                                         File.join(dir, "#{basename}.rb"), "-o", "fib", "-t", "cruby",
                                         "-d", build_dir)
          raise "suppify failed for #{label}:\n#{out}" unless status.success?

          ext_dir = File.join(gem_dir, "ext", "fib")
          puts "== #{label}: building native extension =="
          out, status = Open3.capture2e(env, "ruby", "extconf.rb", chdir: ext_dir)
          raise "extconf.rb failed for #{label}:\n#{out}" unless status.success?
          out, status = Open3.capture2e(env, "make", chdir: ext_dir)
          raise "make failed for #{label}:\n#{out}" unless status.success?

          puts "== #{label}: running benchmark =="
          ext_path = File.join(ext_dir, "fib")
          script = File.join(dir, "run_benchmark_#{label}.rb")
          out, status = Open3.capture2e(env, "ruby", "-r", ext_path, script)
          puts out
          raise "run_benchmark_#{label}.rb failed:\n#{out}" unless status.success?
        end
      end
    end
  end
end
