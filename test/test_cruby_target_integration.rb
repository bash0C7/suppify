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
            print cat("foo", "bar"), " "
            # rb_str_new_cstr (strlen-based) would silently truncate this at
            # the embedded NUL; the fix uses lib_name_str_len for the real
            # byte length. bytesize must be 3, not 1.
            print nully.bytesize, " "
            # spinel's own sp_str_byte_len doesn't recognize a frozen
            # string's marker byte and falls back to strlen -- the fix
            # reads the string header directly for this one marker.
            # bytesize must be 3, not 1.
            print frozen_nully.bytesize, " "
            begin; boom; rescue => e; print "raised:", e.message, " "; end
            print add(10, 20)  # per-call error reset: still works after boom
          RUBY
          out = IO.popen([RbConfig.ruby, "-e", script], &:read)
          assert_equal "5 2.5 hi, world true false true false foobar 3 3 raised:x 30", out.strip
        end
      end
    end
  end

  # Regression test for a confirmed bug: a trampoline forwarding two string
  # arguments as sp_str_dup_external(a), sp_str_dup_external(b) nested calls
  # let the second dup's internal GC collect sweep the first (still-unrooted)
  # duped string before either reached the callee. SPINEL_GC_STRESS=1 shrinks
  # the collection threshold to 2048 bytes so this fires routinely instead of
  # needing engineered heap state (see trampoline.rb's SP_GC_ROOT fix).
  def test_cat_survives_gc_stress_with_multiple_string_arguments
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_available?

    Dir.mktmpdir do |dir|
      FileUtils.cp(File.expand_path("fixtures/add.rb", __dir__), File.join(dir, "add.rb"))
      FileUtils.cp(File.expand_path("fixtures/add.rbs", __dir__), File.join(dir, "add.rbs"))

      Dir.chdir(dir) do
        assert_equal 0, Suppify::CLI.run(["add.rb", "-o", "addlib", "-t", "cruby"])
        ext = File.join(dir, "addlib", "ext", "addlib")
        Dir.chdir(ext) do
          assert system(RbConfig.ruby, "extconf.rb", out: File::NULL), "extconf failed"
          assert system("make", out: File::NULL), "make failed"
          bundle = Dir.glob("*.{so,bundle}").first

          script = <<~RUBY
            require_relative #{File.basename(bundle, '.*').inspect}
            500.times do |i|
              a = "AAAA-\#{i}-" + ("x" * 200)
              b = "BBBB-\#{i}-" + ("y" * 200)
              got = cat(a, b)
              raise "mismatch at \#{i}: \#{got}" unless got == a + b
            end
            print "ok"
          RUBY
          out = IO.popen({ "SPINEL_GC_STRESS" => "1" }, [RbConfig.ruby, "-e", script], &:read)
          assert $?.success?, "child process crashed under GC stress: #{out}"
          assert_equal "ok", out.strip
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
