# test/test_core.rb — the コア layer (lib/suppify/core.rb): NeutralType,
# Signature/SignatureExtractor, Source, SpinelRunner, Pipeline.
require "test_helper"

class TestNeutralType < Test::Unit::TestCase
  def map(t) = Suppify::NeutralType.map(t)

  def test_mrb_int_to_intptr
    assert_equal "intptr_t", map("mrb_int")
  end

  def test_double_passthrough
    assert_equal "double", map("double")
  end

  def test_mrb_float_to_double
    assert_equal "double", map("mrb_float")
  end

  def test_const_char_ptr_passthrough
    assert_equal "const char *", map("const char *")
  end

  def test_bool_to_int
    assert_equal "int", map("bool")
    assert_equal "int", map("_Bool")
    assert_equal "int", map("mrb_bool")
  end

  def test_void_passthrough
    assert_equal "void", map("void")
  end

  def test_non_neutral_raises
    assert_raise(Suppify::NonNeutralType) { map("sp_RbVal") }
    assert_raise(Suppify::NonNeutralType) { map("sp_Proc *") }
  end

  # kind classifies a (spinel or neutral) C type into a language-agnostic
  # marshalling category the per-target bindings switch on.
  def test_kind_classifies_scalars
    assert_equal :int,    Suppify::NeutralType.kind("mrb_int")
    assert_equal :int,    Suppify::NeutralType.kind("intptr_t")
    assert_equal :float,  Suppify::NeutralType.kind("mrb_float")
    assert_equal :float,  Suppify::NeutralType.kind("double")
    assert_equal :string, Suppify::NeutralType.kind("const char *")
    assert_equal :bool,   Suppify::NeutralType.kind("mrb_bool")
    assert_equal :bool,   Suppify::NeutralType.kind("bool")
    assert_equal :void,   Suppify::NeutralType.kind("void")
  end

  def test_kind_raises_on_non_neutral
    assert_raise(Suppify::NonNeutralType) { Suppify::NeutralType.kind("sp_RbVal") }
  end
end

class TestSignature < Test::Unit::TestCase
  C = <<~C
    static mrb_int sp_add(mrb_int a, mrb_int b) {
      return a + b;
    }
    static const char *sp_greet(const char *name) {
      return name;
    }
    static void sp_noop(void) { }
  C

  def test_extract_scalar_two_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_add")
    assert_equal "mrb_int", sig.return_type
    assert_equal [["mrb_int", "a"], ["mrb_int", "b"]], sig.params
  end

  def test_extract_pointer_return_and_arg
    sig = Suppify::SignatureExtractor.extract(C, "sp_greet")
    assert_equal "const char *", sig.return_type
    assert_equal [["const char *", "name"]], sig.params
  end

  def test_extract_void_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_noop")
    assert_equal "void", sig.return_type
    assert_equal [], sig.params
  end

  def test_missing_definition_raises
    assert_raise(Suppify::Error) { Suppify::SignatureExtractor.extract(C, "sp_absent") }
  end
end

class TestSource < Test::Unit::TestCase
  def pub(src) = Suppify::Source.new(src).public_methods.sort

  def test_toplevel_defs_are_public
    assert_equal ["add", "greet"], pub("def add(a,b)=a+b\ndef greet(n)=\"hi\#{n}\"\n")
  end

  def test_private_keyword_marks_following_defs
    src = <<~RUBY
      def a; end
      private
      def b; end
    RUBY
    assert_equal ["a"], pub(src)
  end

  def test_private_def_marks_single
    src = <<~RUBY
      def a; end
      private def b; end
      def c; end
    RUBY
    assert_equal ["a", "c"], pub(src)
  end

  def test_private_symbol_marks_named
    src = <<~RUBY
      def a; end
      def b; end
      private :b
    RUBY
    assert_equal ["a"], pub(src)
  end

  # rooted_source appends one synthetic, RBS-typed call per public method in
  # an `if false` block: spinel registers call names syntactically regardless
  # of control flow, so the methods stay reachable-for-typing but the calls
  # never execute (lib_init runs the renamed main once at load time).
  def test_rooted_source_appends_synthetic_calls_for_each_public_method
    src = "def add(a, b) = a + b\ndef boom = raise \"x\"\n"
    rbs = <<~RBS
      class Object
        def add: (Integer, Integer) -> Integer
        def boom: () -> void
      end
    RBS
    out = Suppify::Source.new(src, rbs_source: rbs).rooted_source
    assert_match(/\Adef add.*\n\z/m, out)
    assert_match(/if false\n/, out)
    assert_match(/add\(0, 0\)\n/, out)
    assert_match(/boom\(\)\n/, out)
  end

  def test_rooted_source_is_unchanged_when_nothing_is_public
    src = "private\ndef helper(x) = x\n"
    assert_equal src, Suppify::Source.new(src).rooted_source
  end

  def test_rooted_source_missing_signature_raises
    src = "def add(a, b) = a + b\n"
    assert_raise(Suppify::Error) { Suppify::Source.new(src, rbs_source: "").rooted_source }
  end

  # Each RBS param type maps to a literal argument in the synthetic call.
  def test_rooted_source_synthesizes_literals_per_rbs_type
    src = "def f(a, b, c) = a\n"
    rbs = <<~RBS
      class Object
        def f: (Float, String, bool) -> void
      end
    RBS
    out = Suppify::Source.new(src, rbs_source: rbs).rooted_source
    assert_match(/f\(0\.0, "", true\)\n/, out)
  end

  def test_rooted_source_unsupported_rbs_type_raises
    src = "def f(a) = a\n"
    rbs = <<~RBS
      class Object
        def f: (Array[Integer]) -> void
      end
    RBS
    assert_raise(Suppify::Error) { Suppify::Source.new(src, rbs_source: rbs).rooted_source }
  end
end

class TestSpinelRunner < Test::Unit::TestCase
  # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
  # emit modes (src/main.c: emit_symbol_map short-circuits before the
  # c_only branch, so a combined invocation silently drops the C output).
  # SpinelRunner must therefore issue two separate invocations.
  def test_builds_two_commands_and_returns_paths
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "/opt/spinel", runner: fake)
    out = r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["/opt/spinel", "/work/app.rb", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["/opt/spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
    assert_equal "/tmp/app.c", out[:c_path]
    assert_equal "/tmp/app.symbols.json", out[:symbols_path]
  end

  def test_nonzero_status_raises_on_c_step
    fake = ->(_argv) { ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_nonzero_status_raises_on_symbol_map_step
    calls = 0
    fake = ->(_argv) { calls += 1; calls == 1 ? ["", 0] : ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_includes_rbs_flag_on_c_step_only_when_given
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake, rbs_dir: "/work/sigs")
    r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["spinel", "/work/app.rb", "--rbs", "/work/sigs", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
  end
end

class TestPipeline < Test::Unit::TestCase
  RUBY = <<~RUBY
    def add(a, b) = a + b
    def boom = nil
    def greet(name) = name
    def cat(a, b) = a
    private
    def helper(x) = x
  RUBY

  C = <<~C
    static mrb_int sp_add(mrb_int a, mrb_int b) { return a + b; }
    static void sp_boom(void) { }
    static const char *sp_greet(const char *name) { return name; }
    static const char *sp_cat(const char *a, const char *b) { return a; }
    static mrb_int sp_helper(mrb_int x) { return x; }
    int main(int argc, char **argv) { return 0; }
  C

  SYMS = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"},' \
         '{"c":"sp_boom","ruby":"boom","kind":"toplevel"},' \
         '{"c":"sp_greet","ruby":"greet","kind":"toplevel"},' \
         '{"c":"sp_cat","ruby":"cat","kind":"toplevel"},' \
         '{"c":"sp_helper","ruby":"helper","kind":"toplevel"}]}'

  def setup
    @r = Suppify::Pipeline.new(ruby_source: RUBY, c_source: C,
                               symbols_json: SYMS, lib_name: "addlib").run
    @c = @r[:c_source]
    @h = @r[:header]
  end

  def test_exports_only_public_methods
    names = @r[:exports].map { |e| e["public"] }
    assert_equal ["add", "boom", "greet", "cat"], names
  end

  # A public method the symbol map lacks (spinel didn't emit it, e.g. DCE'd
  # despite rooting) is skipped rather than crashing the pipeline.
  def test_public_method_missing_from_symbol_map_is_skipped
    syms = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"}]}'
    r = Suppify::Pipeline.new(ruby_source: "def add(a,b)=a+b\ndef gone(x)=x\n",
                              c_source: C, symbols_json: syms, lib_name: "x").run
    assert_equal ["add"], r[:exports].map { |e| e["public"] }
  end

  def test_private_method_not_exported_but_still_static_in_c
    assert_no_match(/intptr_t helper\(/, @c)   # not a public trampoline
    assert_match(/static mrb_int sp_helper/, @c) # still present + hidden
  end

  def test_public_method_with_non_neutral_signature_raises
    bad_c = "static sp_RbVal sp_add(sp_RbVal a) { return a; }\nint main(int c,char**v){return 0;}\n"
    bad_syms = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"}]}'
    assert_raise(Suppify::NonNeutralType) do
      Suppify::Pipeline.new(ruby_source: "def add(a)=a", c_source: bad_c,
                            symbols_json: bad_syms, lib_name: "x").run
    end
  end

  # ---- main renaming: the generated `int main(...)` becomes a static
  # sp__main so lib_init can drive it and the library exports no `main`.

  def test_renames_main_to_static_sp_main
    assert_match(/static int sp__main\(int argc, char \*\*argv\)/, @c)
    assert_no_match(/\bint main\b/, @c)
  end

  def test_main_rename_tolerates_spacing_variants
    c = "int  main ( int argc , char** argv )\n{\nreturn 0;\n}\n"
    r = Suppify::Pipeline.new(ruby_source: "", c_source: c,
                              symbols_json: '{"symbols":[]}', lib_name: "x").run
    assert_match(/static int sp__main\s*\(/, r[:c_source])
  end

  def test_missing_main_raises
    assert_raise(Suppify::Error) do
      Suppify::Pipeline.new(ruby_source: "", c_source: "int foo(void){return 0;}",
                            symbols_json: '{"symbols":[]}', lib_name: "x").run
    end
  end

  # ---- trampolines: the extern, neutral-typed entry points appended to the
  # generated TU, each wrapped in a per-call setjmp exception barrier.

  def test_emits_extern_trampoline_calling_static
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\)/, @c)
    assert_match(/intptr_t r = sp_add\(a, b\);/, @c)
    # success path MUST disarm the setjmp barrier before returning, otherwise
    # the local jmp_buf dangles after return (a later longjmp -> UB).
    assert_match(/sp_exc_disarm\(\);\n\s*return r;/, @c)
  end

  def test_void_trampoline_has_no_return_value
    assert_match(/void boom\(void\)/, @c)
    assert_match(/sp_boom\(\);/, @c)
  end

  # Each trampoline must clear the error flag on entry so <lib>_error()
  # reflects the LAST call, not any earlier one. Without this a language
  # binding that checks <lib>_error() after every call would keep raising
  # forever once any single call raised.
  def test_resets_error_flag_on_entry
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\) \{\n\s*g_suppi_err = 0;/, @c)
    assert_match(/void boom\(void\) \{\n\s*g_suppi_err = 0;/, @c)
  end

  # <lib>_error/<lib>_error_message/<lib>_init are per-library names (not
  # generic ones): spinel's runtime is a set of process-wide globals shared
  # by everything linked against it, so two suppify libraries in the same
  # binary would otherwise define identical symbols and fail to link. See
  # SymbolPrefix for the analogous fix applied to the vendored runtime.
  def test_includes_exception_barrier_and_error_api
    assert_match(/setjmp/, @c)
    assert_match(/sp_exc_arm/, @c)
    assert_match(/int addlib_error\(void\)/, @c)
    assert_match(/const char \*addlib_error_message\(void\)/, @c)
  end

  def test_includes_lib_init
    assert_match(/void addlib_init\(void\)/, @c)
    assert_match(/sp__main\(1, av\);/, @c)
    # C string literals are `char[N]` (not const-qualified), but a strict
    # compiler still warns on assigning one to a `char *` slot; the explicit
    # cast is the standard fake-argv idiom and silences that harmless warning.
    assert_match(/char \*av\[\] = \{ \(char \*\)"lib", 0 \};/, @c)
  end

  # On a caught exception the trampoline captures spinel's message (held in
  # sp_exc_msg at the armed stack level) into a static buffer so
  # <lib>_error_message() returns the real text instead of NULL.
  def test_captures_exception_message
    assert_match(/static char g_suppi_msgbuf\[/, @c)
    assert_match(/sp_exc_msg\[sp_exc_top - 1\]/, @c)
    assert_match(/g_suppi_msg = g_suppi_msgbuf;/, @c)
    # error path routes through the capture helper, which disarms + flags
    assert_match(/if \(setjmp\(jb\)\) \{ suppi__capture\(\); sp_gc_nroots = sp_root_base; return( 0)?; \}/, @c)
  end

  # spinel's strings carry a header (sp_str_hdr) and a marker byte at
  # ptr[-1]; a raw host-language string buffer has neither, so passing it
  # straight into a spinel-generated function is an out-of-bounds read.
  # sp_str_dup_external mirrors what spinel itself does for argv/getenv.
  def test_wraps_string_arguments_in_sp_str_dup_external
    assert_match(/const char \*sp_dup_name = sp_str_dup_external\(name\);/, @c)
    assert_match(/const char \* r = sp_greet\(sp_dup_name\);/, @c)
    # non-string args must be passed through unwrapped
    assert_match(/intptr_t r = sp_add\(a, b\);/, @c)
  end

  # A duped string is only a bare C temporary until it's passed to the
  # spinel-generated callee -- nothing marks it as GC-reachable. With two
  # string arguments, the SECOND sp_str_dup_external's internal allocation
  # can trigger a collection that sweeps the FIRST (still-unrooted) duped
  # string before the call happens. SP_GC_ROOT (the same discipline spinel's
  # own codegen uses for its local variables) keeps each duped string alive
  # from the moment it's created.
  def test_roots_each_duped_string_before_the_next_dup
    assert_match(/const char \*sp_dup_a = sp_str_dup_external\(a\); SP_GC_ROOT\(sp_dup_a\);/, @c)
    assert_match(/const char \*sp_dup_b = sp_str_dup_external\(b\); SP_GC_ROOT\(sp_dup_b\);/, @c)
    assert_match(/const char \* r = sp_cat\(sp_dup_a, sp_dup_b\);/, @c)
  end

  # SP_GC_ROOT's cleanup-attribute pop never runs across a longjmp landing
  # back at our own setjmp (cleanup only fires on normal scope exit) -- so an
  # exception raised while a duped string is rooted would otherwise leave
  # sp_gc_nroots permanently incremented. Snapshotting it at entry and
  # restoring it on the caught-exception path undoes any such leak: once
  # we've decided to abort the call, nothing rooted during it is needed.
  def test_restores_gc_root_count_on_caught_exception
    assert_match(/int sp_root_base = sp_gc_nroots;/, @c)
    assert_match(/if \(setjmp\(jb\)\) \{ suppi__capture\(\); sp_gc_nroots = sp_root_base; return( 0)?; \}/, @c)
  end

  # rb_str_new_cstr/mrb_str_new_cstr are strlen-based, so a String return
  # containing an embedded NUL gets silently truncated. sp_str_byte_len
  # recovers spinel's own tracked byte length (from the string header, not
  # strlen); this bridges it through the neutral boundary so a binding can
  # build a correctly-sized Ruby string instead of guessing via strlen.
  #
  # sp_str_byte_len itself only recognizes the 0xfe/0xfc/0xfd marker bytes,
  # not 0xf1 (a heap string frozen via .freeze -- see spinel's own
  # sp_str_freeze_val), silently falling back to strlen for a frozen
  # string and reintroducing the exact truncation this bridge exists to
  # avoid (confirmed by an adversarial review: `# frozen_string_literal:
  # true` reproduces it). sp_str_freeze_val only flips the marker byte in
  # place on an already sp_str_alloc'd buffer, so the header behind a
  # 0xf1-marked string is still valid; read it directly for this one
  # marker spinel's own helper misses.
  def test_str_len_bridge_handles_frozen_strings_too
    assert_match(/size_t addlib_str_len\(const char \*s\) \{/, @c)
    assert_match(/if \(!s\) return 0;/, @c)
    assert_match(/if \(\(\(const unsigned char \*\)s\)\[-1\] == 0xf1\) \{/, @c)
    assert_match(/return \(\(\(const sp_str_hdr \*\)\(s - 1\)\) - 1\)->len;/, @c)
    assert_match(/return sp_str_byte_len\(s\);/, @c)
  end

  # ---- the neutral header consumers include.

  def test_header_include_guard
    assert_match(/#ifndef ADDLIB_H/, @h)
    assert_match(/#define ADDLIB_H/, @h)
    assert_match(/#endif/, @h)
  end

  def test_header_includes_stdint_for_intptr
    assert_match(/#include <stdint.h>/, @h)
  end

  def test_header_includes_stddef_for_size_t
    assert_match(/#include <stddef.h>/, @h)
  end

  def test_header_prototypes_are_neutral_no_spinel_types
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @h)
    assert_no_match(/mrb_int/, @h)
  end

  # Per-library names (not generic ones) so two suppify libraries linked into
  # the same binary don't collide on the lifecycle/error API.
  def test_header_lifecycle_and_error_api
    assert_match(/void addlib_init\(void\);/, @h)
    assert_match(/int addlib_error\(void\);/, @h)
    assert_match(/const char \*addlib_error_message\(void\);/, @h)
  end

  # Lets a consumer recover a String return's true byte length instead of
  # guessing via strlen, which truncates at an embedded NUL.
  def test_header_declares_str_len_bridge
    assert_match(/size_t addlib_str_len\(const char \*s\);/, @h)
  end
end
