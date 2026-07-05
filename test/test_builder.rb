# test/test_builder.rb
require "test_helper"
require "suppify/builder"
require "fileutils"
require "tmpdir"

class TestBuilder < Test::Unit::TestCase
  # The runtime is bundled and recompiled per library (not copied prebuilt)
  # so its global symbols can be namespaced by SymbolPrefix -- otherwise two
  # suppify libraries linked into the same binary would collide on spinel's
  # ~600 shared runtime symbols. This merges everything into one archive, so
  # there's no separate libspinel_rt.a to copy anymore.
  def test_compiles_generated_source_and_bundled_runtime_with_prelude_then_archives
    Dir.mktmpdir do |dir|
      c_path = File.join(dir, "app.c")
      FileUtils.touch(c_path)
      out_dir = File.join(dir, "out")
      FileUtils.mkdir_p(out_dir)

      cmds = []
      fake_runner = ->(argv) { cmds << argv; ["", 0] }
      fake_discover = ->(lib) { lib == "/opt/spinel/lib" ? %w[sp_gc_alloc] : raise("wrong lib") }
      fake_copy_runtime = lambda do |_lib, dest|
        FileUtils.mkdir_p(dest)
        FileUtils.touch(File.join(dest, "sp_gc.c"))
        { sources: ["sp_gc.c"] }
      end

      b = Suppify::Builder.new(spinel_lib: "/opt/spinel/lib", runner: fake_runner,
                               discover_symbols: fake_discover, copy_runtime: fake_copy_runtime)
      out = b.build(c_path: c_path, lib_name: "mylib", out_dir: out_dir)

      prelude_path = File.join(dir, "mylib_prelude.h")
      assert File.exist?(prelude_path)
      assert_match(/#define sp_gc_alloc mylib_sp_gc_alloc/, File.read(prelude_path))

      runtime_c = File.join(dir, "mylib_runtime", "sp_gc.c")
      cc_cmds = cmds.select { |c| c.first == "cc" }
      assert cc_cmds.any? { |c| c.include?(c_path) && c.include?("-include") && c.include?(prelude_path) }
      assert cc_cmds.any? { |c| c.include?(runtime_c) && c.include?("-include") && c.include?(prelude_path) }

      ar_cmd = cmds.find { |c| c.first == "ar" }
      assert_equal File.join(out_dir, "libmylib.a"), ar_cmd[2]
      assert ar_cmd.include?(c_path.sub(/\.c\z/, ".o"))
      assert ar_cmd.include?(runtime_c.sub(/\.c\z/, ".o"))
      assert_equal File.join(out_dir, "libmylib.a"), out[:archive]
    end
  end

  def test_cc_failure_raises
    fake = ->(_argv) { ["err", 1] }
    discover = ->(_lib) { [] }
    copy_runtime = lambda do |_lib, dest|
      FileUtils.mkdir_p(dest)
      { sources: [] }
    end
    b = Suppify::Builder.new(spinel_lib: "/l", runner: fake, discover_symbols: discover, copy_runtime: copy_runtime)
    Dir.mktmpdir do |dir|
      c_path = File.join(dir, "a.c")
      FileUtils.touch(c_path)
      assert_raise(Suppify::Error) { b.build(c_path: c_path, lib_name: "x", out_dir: dir) }
    end
  end
end
