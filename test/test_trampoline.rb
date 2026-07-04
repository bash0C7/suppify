# test/test_trampoline.rb
require "test_helper"
require "suppify/trampoline"
require "suppify/signature"

class TestTrampoline < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add",   "cname" => "sp_add",
        "sig" => Suppify::Signature.new("mrb_int", [["mrb_int","a"],["mrb_int","b"]]) },
      { "public" => "boom",  "cname" => "sp_boom",
        "sig" => Suppify::Signature.new("void", []) },
      { "public" => "greet", "cname" => "sp_greet",
        "sig" => Suppify::Signature.new("const char *", [["const char *", "name"]]) },
      { "public" => "cat",   "cname" => "sp_cat",
        "sig" => Suppify::Signature.new("const char *", [["const char *", "a"], ["const char *", "b"]]) },
    ]
    @c = Suppify::Trampoline.render(@exports, "addlib")
  end

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

  # Each trampoline must clear the error flag on entry so suppi_error()
  # reflects the LAST call, not any earlier one. Without this a language
  # binding that checks suppi_error() after every call would keep raising
  # forever once any single call raised.
  def test_resets_error_flag_on_entry
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\) \{\n\s*g_suppi_err = 0;/, @c)
    assert_match(/void boom\(void\) \{\n\s*g_suppi_err = 0;/, @c)
  end

  # suppi_error/suppi_error_message/sp_lib_init are per-library names (not
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

  def test_includes_sp_lib_init
    assert_match(/void addlib_init\(void\)/, @c)
    assert_match(/sp__main\(1, av\);/, @c)
    # C string literals are `char[N]` (not const-qualified), but a strict
    # compiler still warns on assigning one to a `char *` slot; the explicit
    # cast is the standard fake-argv idiom and silences that harmless warning.
    assert_match(/char \*av\[\] = \{ \(char \*\)"lib", 0 \};/, @c)
  end

  # On a caught exception the trampoline captures spinel's message (held in
  # sp_exc_msg at the armed stack level) into a static buffer so
  # suppi_error_message() returns the real text instead of NULL.
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
  def test_exposes_str_len_bridge_to_spinels_tracked_byte_length
    assert_match(/size_t addlib_str_len\(const char \*s\) \{ return sp_str_byte_len\(s\); \}/, @c)
  end
end
