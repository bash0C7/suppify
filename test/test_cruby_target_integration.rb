require "test_helper"
require "suppify/cli"
require "fileutils"
require "tmpdir"
require "rbconfig"

# End-to-end proof of the CRuby rubygem target: `suppify -t cruby` emits a
# buildable native-extension gem whose own source set (spinel-generated C +
# runtime sources + CRuby binding) compiles with the host Ruby toolchain and
# is callable as ordinary Ruby methods. Gated on a real spinel.
class TestCRubyTargetIntegration < Test::Unit::TestCase
  def spinel_available?
    !`which spinel`.strip.empty? && !ENV["SPINEL_LIB"].to_s.empty?
  rescue StandardError
    false
  end

  def test_emitted_gem_builds_and_runs
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_available?

    Dir.mktmpdir do |dir|
      FileUtils.cp(File.expand_path("fixtures/add.rb", __dir__), File.join(dir, "add.rb"))
      FileUtils.cp(File.expand_path("fixtures/add.rbs", __dir__), File.join(dir, "add.rbs"))

      Dir.chdir(dir) do
        assert_equal 0, Suppify::CLI.run(["add.rb", "-o", "addlib", "-t", "cruby"])

        ext = File.join(dir, "addlib", "ext", "addlib")
        assert File.directory?(ext), "gem ext dir not emitted"

        Dir.chdir(ext) do
          assert system(RbConfig.ruby, "extconf.rb", out: File::NULL), "extconf failed"
          assert system("make", out: File::NULL), "make failed"
          bundle = Dir.glob("*.{so,bundle}").first
          assert bundle, "extension not built"

          # Drive the built extension in a child ruby (clean VM) and check output.
          script = <<~RUBY
            require_relative #{File.basename(bundle, '.*').inspect}
            print add(2, 3), " "
            print half(5.0), " "
            print greet("world"), " "
            print even(4), " ", even(3), " "
            print truthy(true), " ", truthy(false), " "
            begin; boom; rescue => e; print "raised:", e.message, " "; end
            print add(10, 20)  # per-call error reset: still works after boom
          RUBY
          out = IO.popen([RbConfig.ruby, "-e", script], &:read)
          assert_equal "5 2.5 hi, world true false true false raised:x 30", out.strip
        end
      end
    end
  end

  def test_emitted_gem_packages_with_gem_build
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_available?

    Dir.mktmpdir do |dir|
      FileUtils.cp(File.expand_path("fixtures/add.rb", __dir__), File.join(dir, "add.rb"))
      FileUtils.cp(File.expand_path("fixtures/add.rbs", __dir__), File.join(dir, "add.rbs"))
      Dir.chdir(dir) do
        assert_equal 0, Suppify::CLI.run(["add.rb", "-o", "addlib", "-t", "cruby"])
        Dir.chdir(File.join(dir, "addlib")) do
          assert system("gem", "build", "addlib.gemspec", out: File::NULL, err: File::NULL),
                 "gem build failed"
          assert Dir.glob("addlib-*.gem").any?, "no .gem produced"
        end
      end
    end
  end
end
