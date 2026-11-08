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
      "newlib/sp_newlib_config.h" => "config", "newlib/sys/mman.h" => "mman",
      "spinel/runtime.h" => %(#include "sp_gc.h"\n#include <stdint.h>\n),
      "../packages/base64/sp_base64.c" => %(#include "spinel/runtime.h"\n),
    }.each do |f, body|
      FileUtils.mkdir_p(File.dirname(File.join(@rt, f)))
      File.write(File.join(@rt, f), body)
    end
    @lib = Fixtures.library([Fixtures.entry("add", "sp_int", "sp_int", "sp_int")], runtime_dir: @rt,
                            cflags: ["-I/opt/sdk/include", "-DBOARD=1", "-ffp-contract=off"], libs: ["m", "esp_timer"],
                            ldflags: ["-L/opt/sdk/lib"], sources: [File.join(@tmp, "packages/base64/sp_base64.c")])
  end

  def teardown = FileUtils.remove_entry(@tmp)

  def files(dir) = Dir.chdir(dir) { Dir["**/*"].select { File.file?(_1) }.sort }

  def test_writes_a_self_contained_gem
    dir = Suppify::Mrbgem.write(@lib, @tmp)
    assert_equal File.join(@tmp, "picoruby-calc"), dir
    assert_equal %w[include/suppify/calc.h mrbgem.rake mrblib/calc.rb src/binding.c src/calc_glue.c src/calc_spinel.c src/calc_spinel.h
                    src/mruby.h src/mruby/string.h src/re_compile.c src/sp_base64.c src/sp_gc.c src/spinel/runtime.h src/spinel_rt.h], files(dir)
    assert_equal "module Calc\nend\n", File.read(File.join(dir, "mrblib/calc.rb"))
  end

  def test_each_worker_beyond_the_first_instance_is_sealed_from_the_same_sources
    dir = Suppify::Mrbgem.write(@lib, @tmp, workers: 2, table: "multicore_kernels")
    assert_equal %w[src/instances/calc_w1.exports src/instances/calc_w1_glue.c src/instances/calc_w2.exports src/instances/calc_w2_glue.c],
                 files(dir).grep(/instances/)
    assert_include File.read(File.join(dir, "src/instances/calc_w1.exports")), "multicore_kernels\n"
    rake = File.read(File.join(dir, "mrbgem.rake"))
    assert_include rake, %(shared = Dir["\#{dir}/src/*.c"] - ["\#{dir}/src/binding.c", "\#{dir}/src/calc_glue.c"])
    assert_include rake, %(["calc_w1", "calc_w2"].each do |api|)
    assert_include rake, %(file(obj => [source, first]))
    assert_include rake, %(sh(cc.sub(/(gcc|clang|cc)(-[\\d.]+)?\\z/, "objcopy"), "--keep-global-symbols=\#{exports}", "\#{out}.r", out))
    assert_include rake, %(sh(*wrapper, cc, "-r", "-nostdlib", "-Wl,-exported_symbols_list,\#{out}.exports", "-o", out, *objs))
    assert_include rake, %(spec.cc.run obj, source, [], source == glue ? ["\#{dir}/src"] : [], ["-fno-common"])
  end

  def test_a_gem_without_the_vm_builds_its_first_worker_from_src
    dir = Suppify::Mrbgem.write(@lib, @tmp, vm: false, workers: 1)
    assert_empty files(dir).grep(/mrblib|instances/)
    assert_include File.read(File.join(dir, "src/calc_glue.c")), "int calc_w1_Calc_add(intptr_t a0, intptr_t a1, intptr_t *ret) {"
    assert_include File.read(File.join(dir, "src/binding.c")), "void mrb_picoruby_calc_gem_init(mrb_state *mrb) { (void)mrb; }"
    assert_not_include File.read(File.join(dir, "mrbgem.rake")), "seal"
    assert_raise(Suppify::Error) { Suppify::Mrbgem.write(@lib, @tmp, vm: false, workers: 0) }
  end

  def test_the_regexp_engine_reads_its_own_mruby_shim
    dir = Suppify::Mrbgem.write(@lib, @tmp)
    assert_equal %(#include "mruby.h"\n#include "mruby/string.h"\n#include <string.h>\n), File.read(File.join(dir, "src/re_compile.c"))
    assert_equal %(#include "../mruby.h"\n), File.read(File.join(dir, "src/mruby/string.h"))
  end

  def test_spin_packages_read_spinel_runtime_h_beside_the_flat_runtime
    dir = Suppify::Mrbgem.write(@lib, @tmp)
    assert_equal %(#include "spinel/runtime.h"\n), File.read(File.join(dir, "src/sp_base64.c"))
    assert_equal %(#include "../sp_gc.h"\n#include <stdint.h>\n), File.read(File.join(dir, "src/spinel/runtime.h"))
  end

  def test_rake_carries_spinel_build_settings
    rake = File.read(File.join(Suppify::Mrbgem.write(@lib, @tmp, license: "Apache-2.0"), "mrbgem.rake"))
    assert_include rake, %(MRuby::Gem::Specification.new("picoruby-calc"))
    assert_include rake, %(spec.license = "Apache-2.0")
    assert_include rake, %(other = SUPPIFY_GEMS[build.name] ||= spec.name)
    assert_include rake, %(spec.cc.defines.concat(["SP_ONE_STRING", "BOARD=1"]))
    assert_include rake, %(spec.cc.include_paths.concat(["/opt/sdk/include"]))
    assert_include rake, %(spec.cc.flags.concat(["-ffp-contract=off"]))
    assert_include rake, %(build.linker.flags.concat(["-L/opt/sdk/lib"] - build.linker.flags))
    assert_include rake, %(libs = ["m", "esp_timer"])
    assert_include rake, %(libs << "crypt")
    assert_include rake, %(build.linker.libraries.concat(libs - build.linker.libraries))
    assert_not_include rake, "newlib"
  end

  def test_a_newlib_library_gets_spinel_s_header_layer
    lib = @lib.with(newlib: true, defines: ["SP_ONE_STRING", "SP_NO_SIGNALS"])
    dir = Suppify::Mrbgem.write(lib, @tmp)
    assert_equal %w[src/newlib/sp_newlib_config.h src/newlib/sys/mman.h], files(dir).grep(/newlib/)
    rake = File.read(File.join(dir, "mrbgem.rake"))
    assert_include rake, %(spec.cc.defines.concat(["SP_ONE_STRING", "SP_NO_SIGNALS", "BOARD=1"]))
    assert_include rake, %(spec.cc.include_paths.unshift(newlib)\n)
    assert_include rake, %(spec.cc.flags << "-include \#{newlib}/sp_newlib_config.h")
    assert_not_include rake, "src\""
    assert_not_include rake, "sp_newlib.c"
    assert_not_include rake, "crypt"
  end

  def test_refuses_a_runtime_dir_without_spinel_rt_h
    File.delete(File.join(@rt, "spinel_rt.h"))
    assert_raise(Suppify::Error) { Suppify::Mrbgem.write(@lib, @tmp) }
  end
end
