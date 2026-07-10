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

  # version/license are consumer-controlled (a placeholder version and no
  # presumed license by default) rather than suppify hardcoding a guess on
  # the consumer's own code's behalf.
  def test_mrbgem_rake_version_and_license_are_configurable
    Dir.mktmpdir do |root|
      lib = File.join(root, "spinel_lib")
      FileUtils.mkdir_p(File.join(lib, "regexp"))
      Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
      File.write(File.join(lib, "sp_runtime.h"), "/* rt */")
      out = File.join(root, "picoruby-addlib")

      Suppify::Emitter::PicoRubyGem.emit(
        lib_name: "addlib", c_source: "", header: "", exports: [],
        spinel_lib: lib, out_dir: out,
        discover_symbols: ->(_lib) { [] }, version: "2.3.4", license: "MIT",
      )
      rake = File.read(File.join(out, "mrbgem.rake"))
      assert_match(/spec\.version\s*=\s*"2\.3\.4"/, rake)
      assert_match(/spec\.license\s*=\s*"MIT"/, rake)
    end
  end

  # version, like license, must be rendered via #inspect, not raw
  # interpolation -- mrbgem.rake is literal Ruby source that picoruby's own
  # Rake build loads and executes. A version string containing a `"` must
  # not be able to break out of the string literal and splice extra Ruby.
  def test_mrbgem_rake_escapes_version_safely
    Dir.mktmpdir do |root|
      lib = File.join(root, "spinel_lib")
      FileUtils.mkdir_p(File.join(lib, "regexp"))
      Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
      File.write(File.join(lib, "sp_runtime.h"), "/* rt */")
      out = File.join(root, "picoruby-addlib")

      malicious = %(1.0"; system("touch #{root}/pwned"); spec.summary = ")
      Suppify::Emitter::PicoRubyGem.emit(
        lib_name: "addlib", c_source: "", header: "", exports: [],
        spinel_lib: lib, out_dir: out,
        discover_symbols: ->(_lib) { [] }, version: malicious, license: "MIT",
      )
      rake = File.read(File.join(out, "mrbgem.rake"))
      assert_match(/spec\.version\s*=\s*#{Regexp.escape(malicious.inspect)}/, rake)
      assert_no_match(/spec\.version\s*=\s*"#{Regexp.escape(malicious)}"/, rake)
    end
  end

  # Unlike the cruby gemspec, picoruby's MRuby::Gem::Specification#setup
  # hard-fails the build if license/author are unset -- omitting is not an
  # option here, so the default is the ecosystem's common permissive choice.
  def test_mrbgem_rake_defaults_to_mit_license
    Dir.mktmpdir do |root|
      out = emit(root)
      rake = File.read(File.join(out, "mrbgem.rake"))
      assert_match(/spec\.version\s*=\s*"0\.1\.0"/, rake)
      assert_match(/spec\.license\s*=\s*"MIT"/, rake)
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

  # binding.c must adapt to whichever VM the consumer's own picoruby build
  # selects (PICORB_VM_MRUBYC is PicoRuby's actual default on microcontroller
  # targets; the previous mruby-only binding registered against an inert
  # compiler-side mrb_state that the running mrubyc VM never sees, so calls
  # from Ruby raised NoMethodError on real hardware -- see HANDOFF).
  def test_binding_has_mrubyc_branch_dispatched_by_picorb_vm_mrubyc
    Dir.mktmpdir do |root|
      out = emit(root)
      binding = File.read(File.join(out, "src", "binding.c"))
      assert_match(/#if defined\(PICORB_VM_MRUBYC\)/, binding)
      assert_match(/#include <mrubyc\.h>/, binding)
      assert_match(/mrbc_define_method\(0, 0, "add", c_suppi_add\)/, binding)
      assert_match(/#else/, binding)
    end
  end
end
