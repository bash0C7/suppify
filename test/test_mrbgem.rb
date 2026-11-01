require "test_helper"
require "fileutils"

class TestMrbgem < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir
    @rt = File.join(@tmp, "rt")
    {
      "spinel_rt.h" => "rt", "sp_gc.c" => "gc",
      "regexp/re_compile.c" => "#include <mruby.h>\n#include <mruby/string.h>\n#include <string.h>\n",
      "regexp/shim/mruby.h" => "shim", "regexp/shim/mruby/string.h" => %(#include "../mruby.h"\n),
      "newlib/sp_newlib.c" => "stubs", "newlib/sys/mman.h" => "mman",
    }.each do |f, body|
      FileUtils.mkdir_p(File.dirname(File.join(@rt, f)))
      File.write(File.join(@rt, f), body)
    end
    @lib = Fixtures.library([Fixtures.entry("add", "sp_int", "sp_int", "sp_int")], runtime_dir: @rt,
                            cflags: ["-I/opt/sdk/include", "-DBOARD=1"], libs: ["m", "esp_timer"])
  end

  def teardown = FileUtils.remove_entry(@tmp)

  def files(dir) = Dir.chdir(dir) { Dir["**/*"].select { File.file?(_1) }.sort }

  def test_writes_a_self_contained_gem
    dir = Suppify::Mrbgem.write(@lib, @tmp)
    assert_equal File.join(@tmp, "picoruby-calc"), dir
    assert_equal %w[include/calc.h mrbgem.rake mrblib/calc.rb src/binding.c src/calc_glue.c src/calc_spinel.c src/calc_spinel.h
                    src/mruby.h src/mruby/string.h src/re_compile.c src/sp_gc.c src/spinel_rt.h], files(dir)
    assert_equal "module Calc\nend\n", File.read(File.join(dir, "mrblib/calc.rb"))
  end

  def test_the_regexp_engine_reads_its_own_mruby_shim
    dir = Suppify::Mrbgem.write(@lib, @tmp)
    assert_equal %(#include "mruby.h"\n#include "mruby/string.h"\n#include <string.h>\n), File.read(File.join(dir, "src/re_compile.c"))
    assert_equal %(#include "../mruby.h"\n), File.read(File.join(dir, "src/mruby/string.h"))
  end

  def test_rake_carries_spinel_build_settings
    rake = File.read(File.join(Suppify::Mrbgem.write(@lib, @tmp, license: "Apache-2.0"), "mrbgem.rake"))
    assert_include rake, %(MRuby::Gem::Specification.new("picoruby-calc"))
    assert_include rake, %(spec.license = "Apache-2.0")
    assert_include rake, %(spec.cc.defines.concat(["SP_ONE_STRING", "BOARD=1"]))
    assert_include rake, %(spec.cc.include_paths.concat(["/opt/sdk/include"]))
    assert_include rake, %(spec.linker.libraries.concat(["m", "esp_timer"]))
    assert_include rake, %(spec.linker.libraries << "crypt")
    assert_not_include rake, "newlib"
  end

  def test_newlib_adds_spinel_s_board_layer
    dir = Suppify::Mrbgem.write(@lib, @tmp, newlib: true)
    assert_equal %w[src/newlib/sp_newlib.c src/newlib/sys/mman.h], files(dir).grep(/newlib/)
    rake = File.read(File.join(dir, "mrbgem.rake"))
    assert_include rake, %(spec.cc.include_paths.unshift(newlib))
    assert_include rake, %(spec.cc.flags << "-include \#{newlib}/sp_newlib_config.h")
    assert_include rake, %(file(stubs => "\#{newlib}/sp_newlib.c"))
    assert_not_include rake, "crypt"
  end

  def test_refuses_a_runtime_dir_without_spinel_rt_h
    File.delete(File.join(@rt, "spinel_rt.h"))
    assert_raise(Suppify::Error) { Suppify::Mrbgem.write(@lib, @tmp) }
  end
end
