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
    @c = Suppify::Trampoline.render(@exports)
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

  def test_includes_exception_barrier_and_error_api
    assert_match(/setjmp/, @c)
    assert_match(/sp_exc_arm/, @c)
    assert_match(/int suppi_error\(void\)/, @c)
    assert_match(/const char \*suppi_error_message\(void\)/, @c)
  end

  def test_includes_sp_lib_init
    assert_match(/void sp_lib_init\(void\)/, @c)
    assert_match(/sp__main\(1, av\);/, @c)
  end

  # On a caught exception the trampoline captures spinel's message (held in
  # sp_exc_msg at the armed stack level) into a static buffer so
  # suppi_error_message() returns the real text instead of NULL.
  def test_captures_exception_message
    assert_match(/static char g_suppi_msgbuf\[/, @c)
    assert_match(/sp_exc_msg\[sp_exc_top - 1\]/, @c)
    assert_match(/g_suppi_msg = g_suppi_msgbuf;/, @c)
    # error path routes through the capture helper, which disarms + flags
    assert_match(/if \(setjmp\(jb\)\) \{ suppi__capture\(\); return( 0)?; \}/, @c)
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
end
