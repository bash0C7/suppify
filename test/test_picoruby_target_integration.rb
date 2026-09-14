require "test_helper"
require "suppify/cli"
require "fileutils"
require "tmpdir"

# End-to-end proof of the PicoRuby target: `suppify -t picoruby` emits an
# mrbgem whose src set (spinel-generated C + runtime sources + mruby binding)
# is compiled into libmruby.a by picoruby's own build, and the resulting
# `picoruby` host binary calls the AOT-compiled methods as top-level Ruby.
#
# Gated on: a real spinel (PATH + SPINEL_LIB) AND a local picoruby checkout
# (PICORUBY_ROOT env, or the conventional path). Skipped otherwise so the
# suite stays green without those heavy prerequisites.
class TestPicoRubyTargetIntegration < Test::Unit::TestCase
  PICORUBY_ROOT = ENV["PICORUBY_ROOT"] ||
                  File.expand_path("~/dev/src/github.com/picoruby/picoruby")

  def ready?
    !`which spinel`.strip.empty? &&
      !ENV["SPINEL_LIB"].to_s.empty? &&
      File.directory?(PICORUBY_ROOT) &&
      File.exist?(File.join(PICORUBY_ROOT, "Rakefile"))
  rescue StandardError
    false
  end

  def test_generated_mrbgem_links_into_picoruby_and_runs
    omit("spinel + PICORUBY_ROOT required") unless ready?

    Dir.mktmpdir do |dir|
      FileUtils.cp(File.expand_path("fixtures/add.rb", __dir__), File.join(dir, "add.rb"))
      FileUtils.cp(File.expand_path("fixtures/add.rbs", __dir__), File.join(dir, "add.rbs"))

      Dir.chdir(dir) { assert_equal 0, Suppify::CLI.run(["add.rb", "-o", "addlib", "-t", "picoruby"]) }
      gem_dir = File.join(dir, "picoruby-addlib")
      assert File.exist?(File.join(gem_dir, "mrbgem.rake"))

      build_dir = File.join(dir, "build")
      config = File.join(dir, "host.rb")
      File.write(config, host_build_config(gem_dir))

      log = File.join(dir, "rake.log")
      ok = system({ "MRUBY_CONFIG" => config, "MRUBY_BUILD_DIR" => build_dir },
                  "rake", chdir: PICORUBY_ROOT, out: log, err: log)
      assert ok, "picoruby build failed:\n#{File.read(log)}"

      picoruby = File.join(build_dir, "host", "bin", "picoruby")
      assert File.executable?(picoruby), "picoruby binary not built"

      prog = File.join(dir, "prog.rb")
      File.write(prog, <<~RUBY)
        print add(2, 3), " "
        print half(5.0), " "
        print greet("world"), " "
        print even(4), " ", even(3), " "
        print truthy(true), " ", truthy(false), " "
        print cat("foo", "bar"), " "
        # mrb_str_new_cstr (strlen-based) would silently truncate this at the
        # embedded NUL; the fix uses lib_name_str_len for the real byte
        # length. bytesize must be 3, not 1.
        print nully.bytesize, " "
        # spinel's own sp_str_byte_len doesn't recognize a frozen string's
        # marker byte and falls back to strlen -- the fix reads the string
        # header directly for this one marker. bytesize must be 3, not 1.
        print frozen_nully.bytesize, " "
        begin; boom; rescue => e; print "raised:", e.message, " "; end
        print add(10, 20)
      RUBY
      out = IO.popen([picoruby, prog], &:read)
      assert_equal "5 2.5 hi, world true false true false foobar 3 3 raised:x 30", out.strip
    end
  end

  def host_build_config(gem_dir)
    <<~RUBY
      MRuby::Build.new do |conf|
        conf.toolchain :gcc
        conf.cc.defines << "MRB_TICK_UNIT=4"
        conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
        conf.cc.defines << "PICORB_PLATFORM_POSIX"
        conf.cc.defines << "MRB_INT64"
        conf.cc.defines << "MRB_NO_BOXING"
        conf.cc.defines << "MRB_UTF8_STRING"
        # alloc_estalloc: false -- this integration test only needs the
        # standard allocator; picoruby's default (alloc_estalloc: true)
        # expects picoruby-machine's estalloc sources, which this minimal
        # host build doesn't pull in.
        conf.picoruby(alloc_estalloc: false)
        conf.gembox "minimum"
        conf.gem core: "picoruby-bin-picoruby"
        conf.gem gemdir: #{gem_dir.inspect}
      end
    RUBY
  end
end
