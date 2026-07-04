# test/test_emitter_picoruby_gem.rb
require "test_helper"
require "suppify/emitter/picoruby_gem"
require "suppify/signature"
require "suppify/runtime_sources"
require "fileutils"
require "tmpdir"

class TestEmitterPicoRubyGem < Test::Unit::TestCase
  def emit(root)
    lib = File.join(root, "spinel_lib")
    FileUtils.mkdir_p(File.join(lib, "regexp"))
    Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
    File.write(File.join(lib, "sp_runtime.h"), "/* rt */")

    out = File.join(root, "picoruby-addlib")
    Suppify::Emitter::PicoRubyGem.emit(
      lib_name: "addlib",
      c_source: "#include \"sp_runtime.h\"\nstatic int sp__main(int a, char**b){return 0;}\n",
      header: "#ifndef ADDLIB_H\n#define ADDLIB_H\nintptr_t add(intptr_t, intptr_t);\n#endif\n",
      exports: [{ "public" => "add", "cname" => "sp_add",
                  "sig" => Suppify::Signature.new("mrb_int", [["mrb_int", "a"], ["mrb_int", "b"]]) }],
      spinel_lib: lib,
      out_dir: out,
      discover_symbols: ->(_lib) { %w[sp_gc_alloc] },
    )
    out
  end

  def test_emits_mrbgem_layout
    Dir.mktmpdir do |root|
      out = emit(root)
      assert File.exist?(File.join(out, "mrbgem.rake"))
      assert File.exist?(File.join(out, "include", "addlib.h"))
      assert File.exist?(File.join(out, "src", "binding.c"))
      assert File.exist?(File.join(out, "src", "addlib_gen.c"))
      assert File.exist?(File.join(out, "src", "sp_gc.c"))      # runtime bundled into src/
      assert File.exist?(File.join(out, "src", "re_compile.c")) # regexp flattened
      assert File.exist?(File.join(out, "src", "sp_runtime.h"))
    end
  end

  def test_mrbgem_rake_names_gem_and_include_path
    Dir.mktmpdir do |root|
      out = emit(root)
      rake = File.read(File.join(out, "mrbgem.rake"))
      assert_match(/MRuby::Gem::Specification\.new\('picoruby-addlib'\)/, rake)
      assert_match(/spec\.cc\.include_paths << "#\{dir\}\/include"/, rake)
    end
  end

  # Every vendored runtime symbol is namespaced per lib_name (via the same
  # SymbolPrefix prelude the cruby target uses) so a second suppify-built
  # mrbgem linked into the same firmware image doesn't collide with this
  # one's spinel runtime state; the prelude also silences the bundled
  # runtime's own harmless warnings.
  def test_emits_symbol_prefix_prelude_and_wires_it_into_the_build
    Dir.mktmpdir do |root|
      out = emit(root)
      prelude = File.join(out, "src", "addlib_prelude.h")
      assert File.exist?(prelude)
      assert_match(/#define sp_gc_alloc addlib_sp_gc_alloc/, File.read(prelude))

      rake = File.read(File.join(out, "mrbgem.rake"))
      assert_match(/spec\.cc\.flags << "-include #\{dir\}\/src\/addlib_prelude\.h"/, rake)
    end
  end

  def test_binding_init_matches_picoruby_convention
    Dir.mktmpdir do |root|
      out = emit(root)
      binding = File.read(File.join(out, "src", "binding.c"))
      # PICORB_VM_MRUBY gem init symbol = mrb_<gemname_with_underscores>_gem_init
      assert_match(/void mrb_picoruby_addlib_gem_init\(mrb_state \*mrb\)/, binding)
      assert_match(/mrb_define_method\(mrb, mrb->kernel_module, "add"/, binding)
    end
  end
end
