# test/test_emitter_cruby_gem.rb
require "test_helper"
require "suppify/emitter/cruby_gem"
require "suppify/signature"
require "suppify/runtime_sources"
require "fileutils"
require "tmpdir"

class TestEmitterCRubyGem < Test::Unit::TestCase
  def emit(root)
    lib = File.join(root, "spinel_lib")
    FileUtils.mkdir_p(File.join(lib, "regexp"))
    Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
    File.write(File.join(lib, "sp_runtime.h"), "/* rt */")

    out = File.join(root, "gem")
    Suppify::Emitter::CRubyGem.emit(
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

  def test_emits_buildable_gem_layout
    Dir.mktmpdir do |root|
      out = emit(root)
      ext = File.join(out, "ext", "addlib")
      assert File.exist?(File.join(out, "addlib.gemspec"))
      assert File.exist?(File.join(out, "lib", "addlib.rb"))
      assert File.exist?(File.join(ext, "extconf.rb"))
      assert File.exist?(File.join(ext, "binding.c"))
      assert File.exist?(File.join(ext, "addlib.h"))
      assert File.exist?(File.join(ext, "sp_gc.c"))       # runtime source bundled
      assert File.exist?(File.join(ext, "re_compile.c"))  # regexp source flattened
      assert File.exist?(File.join(ext, "sp_runtime.h"))  # runtime header bundled
    end
  end

  # Every vendored runtime symbol (~600, discovered via a real compile+nm --
  # faked here for a fast unit test) is namespaced per lib_name so a second
  # suppify-built gem linked into the same process doesn't collide with this
  # one's spinel runtime state. Force-included ahead of every .c file mkmf
  # compiles for this extension (generated TU, binding, bundled runtime).
  def test_emits_symbol_prefix_prelude_and_wires_it_into_the_build
    Dir.mktmpdir do |root|
      out = emit(root)
      ext = File.join(out, "ext", "addlib")
      prelude = File.join(ext, "addlib_prelude.h")
      assert File.exist?(prelude)
      assert_match(/#define sp_gc_alloc addlib_sp_gc_alloc/, File.read(prelude))

      extconf = File.read(File.join(ext, "extconf.rb"))
      assert_match(/-include .*addlib_prelude\.h/, extconf)
    end
  end

  def test_extconf_and_gemspec_wire_the_extension
    Dir.mktmpdir do |root|
      out = emit(root)
      extconf = File.read(File.join(out, "ext", "addlib", "extconf.rb"))
      assert_match(/create_makefile\("addlib\/addlib"\)/, extconf)
      gemspec = File.read(File.join(out, "addlib.gemspec"))
      assert_match(/s\.name\s*=\s*"addlib"/, gemspec)
      assert_match(%r{s\.extensions\s*=\s*\["ext/addlib/extconf\.rb"\]}, gemspec)
      loader = File.read(File.join(out, "lib", "addlib.rb"))
      assert_match(%r{require "addlib/addlib"}, loader)
    end
  end

  # version/license are consumer-controlled (a placeholder version and no
  # presumed license by default) rather than suppify hardcoding a guess on
  # the consumer's own code's behalf.
  def test_gemspec_version_and_license_are_configurable
    Dir.mktmpdir do |root|
      lib = File.join(root, "spinel_lib")
      FileUtils.mkdir_p(File.join(lib, "regexp"))
      Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
      File.write(File.join(lib, "sp_runtime.h"), "/* rt */")
      out = File.join(root, "gem")

      Suppify::Emitter::CRubyGem.emit(
        lib_name: "addlib", c_source: "", header: "", exports: [],
        spinel_lib: lib, out_dir: out,
        discover_symbols: ->(_lib) { [] }, version: "2.3.4", license: "MIT",
      )
      gemspec = File.read(File.join(out, "addlib.gemspec"))
      assert_match(/s\.version\s*=\s*"2\.3\.4"/, gemspec)
      assert_match(/s\.license\s*=\s*"MIT"/, gemspec)
    end
  end

  def test_gemspec_defaults_have_no_license_line
    Dir.mktmpdir do |root|
      out = emit(root)
      gemspec = File.read(File.join(out, "addlib.gemspec"))
      assert_match(/s\.version\s*=\s*"0\.1\.0"/, gemspec)
      assert_no_match(/s\.license/, gemspec)
    end
  end

  def test_binding_and_generated_c_present
    Dir.mktmpdir do |root|
      out = emit(root)
      ext = File.join(out, "ext", "addlib")
      assert_match(/Init_addlib/, File.read(File.join(ext, "binding.c")))
      assert_match(/sp__main/, File.read(File.join(ext, "addlib_gen.c")))
    end
  end
end
