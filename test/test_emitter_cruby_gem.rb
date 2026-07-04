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

  def test_extconf_and_gemspec_wire_the_extension
    Dir.mktmpdir do |root|
      out = emit(root)
      extconf = File.read(File.join(out, "ext", "addlib", "extconf.rb"))
      assert_match(/create_makefile\("addlib\/addlib"\)/, extconf)
      # The bundled (unmodified) spinel runtime sources trip a couple of
      # harmless warnings under the host Ruby's CFLAGS (e.g. spinel's
      # sp_types.h unconditionally #defines _DARWIN_C_SOURCE, colliding with
      # mkmf's own -D_DARWIN_C_SOURCE=1). Suppressed so a clean `make` isn't
      # mistaken for a real problem in generated code.
      assert_match(/\$CFLAGS << " -Wno-macro-redefined -Wno-missing-noreturn"/, extconf)
      gemspec = File.read(File.join(out, "addlib.gemspec"))
      assert_match(/s\.name\s*=\s*"addlib"/, gemspec)
      assert_match(%r{s\.extensions\s*=\s*\["ext/addlib/extconf\.rb"\]}, gemspec)
      loader = File.read(File.join(out, "lib", "addlib.rb"))
      assert_match(%r{require "addlib/addlib"}, loader)
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
