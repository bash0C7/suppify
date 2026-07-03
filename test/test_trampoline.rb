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
end
