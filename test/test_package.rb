# test/test_package.rb — the エミッタ layer (lib/suppify/package.rb):
# RuntimeSources, SymbolPrefix, and the per-target emitters
# (Emitter::CArchive / Emitter::CRubyGem / Emitter::PicoRubyGem).
require "test_helper"
require "fileutils"
require "tmpdir"

class TestRuntimeSources < Test::Unit::TestCase
  def test_sources_list_covers_runtime_and_regexp
    s = Suppify::RuntimeSources::SOURCES
    assert_includes s, "sp_gc.c"
    assert_includes s, "sp_str.c"
    assert_includes s, "regexp/re_compile.c"
    assert_equal 32, s.length
  end

  # copy_flat flattens every runtime .c and every header into one dir (so a
  # consumer's flat compile — mkmf top-level globbing, mrbgem src/ glob —
  # picks them all up). Quoted same-dir includes keep resolving after flatten.
  def test_copy_flat_copies_sources_and_headers_by_basename
    Dir.mktmpdir do |root|
      lib = File.join(root, "lib")
      FileUtils.mkdir_p(File.join(lib, "regexp"))
      Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
      File.write(File.join(lib, "spinel_rt.h"), "/* h */")
      File.write(File.join(lib, "regexp", "re_internal.h"), "/* h */")

      dest = File.join(root, "out")
      FileUtils.mkdir_p(dest)
      result = Suppify::RuntimeSources.copy_flat(lib, dest)

      assert_includes result[:sources], "sp_gc.c"
      assert_includes result[:sources], "re_compile.c" # flattened, no regexp/ prefix
      assert File.exist?(File.join(dest, "sp_gc.c"))
      assert File.exist?(File.join(dest, "re_compile.c"))
      assert File.exist?(File.join(dest, "spinel_rt.h"))
    end
  end

  def test_copy_flat_raises_when_a_declared_source_is_missing
    Dir.mktmpdir do |root|
      lib = File.join(root, "lib")
      FileUtils.mkdir_p(lib)
      # intentionally create nothing
      assert_raise(Suppify::Error) { Suppify::RuntimeSources.copy_flat(lib, root) }
    end
  end
end

class TestSymbolPrefix < Test::Unit::TestCase
  def test_prelude_defines_each_symbol_prefixed_by_lib_name
    h = Suppify::SymbolPrefix.prelude("addlib", %w[sp_gc_alloc sp_str_heap])
    assert_match(/#define sp_gc_alloc addlib_sp_gc_alloc/, h)
    assert_match(/#define sp_str_heap addlib_sp_str_heap/, h)
  end

  # Two different libraries must never collide on their own renamed symbols
  # either -- distinct lib_name prefixes guarantee that mechanically.
  def test_prelude_is_distinct_per_lib_name
    a = Suppify::SymbolPrefix.prelude("addlib", %w[sp_gc_alloc])
    b = Suppify::SymbolPrefix.prelude("otherlib", %w[sp_gc_alloc])
    refute_equal a, b
  end

  # The vendored (unmodified) spinel runtime trips warnings under a
  # consumer's own CFLAGS/-Wall (unused static helpers not used by every
  # program, a stray "/*" in a comment, a couple of clang-specific
  # diagnostics). Silenced portably across gcc and clang so a clean build of
  # generated code isn't mistaken for a real problem in vendored code.
  def test_prelude_suppresses_known_harmless_vendored_warnings
    h = Suppify::SymbolPrefix.prelude("addlib", [])
    assert_match(/#pragma GCC diagnostic ignored "-Wunused-function"/, h)
    assert_match(/#pragma GCC diagnostic ignored "-Wunused-variable"/, h)
    assert_match(/#pragma GCC diagnostic ignored "-Wcomment"/, h)
    assert_match(/#if defined\(__clang__\)/, h)
    assert_match(/#pragma clang diagnostic ignored "-Wmacro-redefined"/, h)
    assert_match(/#pragma clang diagnostic ignored "-Wmissing-noreturn"/, h)
  end

  def test_discover_runtime_symbols_finds_globals_not_statics
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_lib_available?

    symbols = Suppify::SymbolPrefix.discover_runtime_symbols(ENV["SPINEL_LIB"])
    assert_includes symbols, "sp_gc_alloc"
    assert_includes symbols, "sp_str_heap"
    assert_includes symbols, "re_compile"
    # spinel's own per-program codegen internals (sp_add, sp__main, ...) are
    # static and never appear here -- only the shared runtime API should.
    refute_includes symbols, "sp_add"
    refute_includes symbols, "sp__main"
  end

  # spinel_rt.h -- the header the GENERATED per-program TU includes, not one
  # of the 25 lib/*.c sources -- embeds ~200 non-static function bodies
  # directly (spinel's normal build compiles it into exactly one program TU
  # per binary). Every suppify library's own generated .c also includes it,
  # so each library's compiled copy defines these identically-named symbols
  # too; missing them from discovery left them unrenamed and colliding
  # (confirmed empirically: linking two suppify libraries failed on
  # duplicate symbols like sp_raise_cls, sp_exc_arm, sp_sprintf).
  def test_discover_runtime_symbols_includes_sp_runtime_h_embedded_functions
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_lib_available?

    symbols = Suppify::SymbolPrefix.discover_runtime_symbols(ENV["SPINEL_LIB"])
    assert_includes symbols, "sp_raise_cls"
    assert_includes symbols, "sp_exc_arm"
    assert_includes symbols, "sp_sprintf"
  end

  # sp_ctx_swap (Fiber context switch) is defined via a file-scope __asm__
  # string in sp_fiber.c with its symbol name hardcoded as a C string
  # literal -- #define text substitution never reaches inside a string, so
  # renaming its call sites (plain identifiers) while the definition stays
  # literally "sp_ctx_swap" produces an undefined-symbol link error. Left
  # out of the rename set; it's the one runtime symbol that stays shared
  # (fine in practice: it's stateless, bit-identical across libraries).
  def test_discover_runtime_symbols_excludes_asm_defined_ctx_swap
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_lib_available?

    symbols = Suppify::SymbolPrefix.discover_runtime_symbols(ENV["SPINEL_LIB"])
    refute_includes symbols, "sp_ctx_swap"
  end

  # The user-defined exception class table is emitted into the GENERATED TU
  # (<lib>_gen.c), not the vendored runtime, so compiling lib/*.c only ever
  # sees it as an undefined reference and it went unprefixed -- a duplicate
  # symbol as soon as two suppify libraries met in one binary. It is added
  # to the rename set explicitly.
  def test_discover_runtime_symbols_includes_the_generated_tus_own_globals
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_lib_available?

    symbols = Suppify::SymbolPrefix.discover_runtime_symbols(ENV["SPINEL_LIB"])
    assert_includes symbols, "sp_exc_subclass_count"
    assert_includes symbols, "sp_exc_subclass_ids"
  end

  private

  def spinel_lib_available?
    !ENV["SPINEL_LIB"].to_s.empty? && !`which cc`.strip.empty?
  end
end

class TestEmitterCArchive < Test::Unit::TestCase
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

      b = Suppify::Emitter::CArchive.new(spinel_lib: "/opt/spinel/lib", runner: fake_runner,
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
    b = Suppify::Emitter::CArchive.new(spinel_lib: "/l", runner: fake, discover_symbols: discover, copy_runtime: copy_runtime)
    Dir.mktmpdir do |dir|
      c_path = File.join(dir, "a.c")
      FileUtils.touch(c_path)
      assert_raise(Suppify::Error) { b.build(c_path: c_path, lib_name: "x", out_dir: dir) }
    end
  end
end

class TestEmitterCRubyGem < Test::Unit::TestCase
  def emit(root)
    lib = File.join(root, "spinel_lib")
    FileUtils.mkdir_p(File.join(lib, "regexp"))
    Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
    File.write(File.join(lib, "spinel_rt.h"), "/* rt */")

    out = File.join(root, "gem")
    Suppify::Emitter::CRubyGem.emit(
      lib_name: "addlib",
      c_source: "#include \"spinel_rt.h\"\nstatic int sp__main(int a, char**b){return 0;}\n",
      header: "#ifndef ADDLIB_H\n#define ADDLIB_H\nintptr_t add(intptr_t, intptr_t);\n#endif\n",
      exports: [{ "public" => "add", "cname" => "sp_add",
                  "sig" => Suppify::Signature.new("sp_int", [["sp_int", "a"], ["sp_int", "b"]]) }],
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
      assert File.exist?(File.join(ext, "spinel_rt.h"))  # runtime header bundled
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
      File.write(File.join(lib, "spinel_rt.h"), "/* rt */")
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

  # version, like license, must be rendered via #inspect, not raw
  # interpolation -- the emitted gemspec is literal Ruby source that
  # `gem build`/`bundle` load and execute. A version string containing a
  # `"` (e.g. one carrying arbitrary text from a build variable) must not
  # be able to break out of the string literal and splice extra Ruby.
  def test_gemspec_escapes_version_safely
    Dir.mktmpdir do |root|
      lib = File.join(root, "spinel_lib")
      FileUtils.mkdir_p(File.join(lib, "regexp"))
      Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
      File.write(File.join(lib, "spinel_rt.h"), "/* rt */")
      out = File.join(root, "gem")

      malicious = %(1.0"; system("touch #{root}/pwned"); s.summary = ")
      Suppify::Emitter::CRubyGem.emit(
        lib_name: "addlib", c_source: "", header: "", exports: [],
        spinel_lib: lib, out_dir: out,
        discover_symbols: ->(_lib) { [] }, version: malicious, license: nil,
      )
      gemspec_path = File.join(out, "addlib.gemspec")
      assert_match(/s\.version\s*=\s*#{Regexp.escape(malicious.inspect)}/, File.read(gemspec_path))

      # Escaped as a plain string, RubyGems' own version-format validation
      # correctly rejects the nonsense content -- it never gets a chance to
      # execute as Ruby either way.
      assert_raise(ArgumentError) { load gemspec_path }
      refute File.exist?(File.join(root, "pwned")), "version string executed as Ruby code"
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

class TestEmitterPicoRubyGem < Test::Unit::TestCase
  def emit(root)
    lib = File.join(root, "spinel_lib")
    FileUtils.mkdir_p(File.join(lib, "regexp"))
    Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
    File.write(File.join(lib, "spinel_rt.h"), "/* rt */")

    out = File.join(root, "picoruby-addlib")
    Suppify::Emitter::PicoRubyGem.emit(
      lib_name: "addlib",
      c_source: "#include \"spinel_rt.h\"\nstatic int sp__main(int a, char**b){return 0;}\n",
      header: "#ifndef ADDLIB_H\n#define ADDLIB_H\nintptr_t add(intptr_t, intptr_t);\n#endif\n",
      exports: [{ "public" => "add", "cname" => "sp_add",
                  "sig" => Suppify::Signature.new("sp_int", [["sp_int", "a"], ["sp_int", "b"]]) }],
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
      assert File.exist?(File.join(out, "src", "spinel_rt.h"))
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
      File.write(File.join(lib, "spinel_rt.h"), "/* rt */")
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
      File.write(File.join(lib, "spinel_rt.h"), "/* rt */")
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
      assert_match(/void mrbc_addlib_init\(mrbc_vm \*vm\)/, binding)
      assert_match(/#else/, binding)
    end
  end

  # picoruby-require's collect_gems only puts a gem into the mrubyc
  # prebuilt_gems[] require table if the gem has mrblib/*.rb to compile into
  # the table's bytecode entry -- a gem without mrblib is silently skipped
  # and its mrbc_<lib>_init never runs (methods then NoMethodError on
  # device). The stub is load-bearing even though it defines nothing.
  def test_emits_mrblib_stub_so_picogem_table_includes_the_gem
    Dir.mktmpdir do |root|
      out = emit(root)
      stub = File.join(out, "mrblib", "addlib.rb")
      assert File.exist?(stub), "expected mrblib/addlib.rb stub"
      assert_match(/mrbc_addlib_init/, File.read(stub))
    end
  end
end
