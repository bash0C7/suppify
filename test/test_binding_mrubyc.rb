# test/test_binding_mrubyc.rb
require "test_helper"
require "suppify/binding/mrubyc"
require "suppify/signature"

class TestBindingMrubyc < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add",   "cname" => "sp_add",
        "sig" => Suppify::Signature.new("mrb_int", [["mrb_int", "a"], ["mrb_int", "b"]]) },
      { "public" => "half",  "cname" => "sp_half",
        "sig" => Suppify::Signature.new("mrb_float", [["mrb_float", "x"]]) },
      { "public" => "greet", "cname" => "sp_greet",
        "sig" => Suppify::Signature.new("const char *", [["const char *", "name"]]) },
      { "public" => "even",  "cname" => "sp_even",
        "sig" => Suppify::Signature.new("mrb_bool", [["mrb_int", "n"]]) },
      { "public" => "truthy", "cname" => "sp_truthy",
        "sig" => Suppify::Signature.new("mrb_bool", [["mrb_bool", "flag"]]) },
      { "public" => "boom",  "cname" => "sp_boom",
        "sig" => Suppify::Signature.new("void", []) },
    ]
    @c = Suppify::Binding::Mrubyc.render("addlib", "mrb_picoruby_addlib_gem_init", @exports)
  end

  def test_includes_mrubyc_header_and_neutral_header
    assert_match(/#include <mrubyc\.h>/, @c)
    assert_match(/#include "addlib\.h"/, @c)
  end

  # gem_init's signature uses mrb_state (the aggregate gem table calls
  # every gem's init with this signature regardless of VM -- see
  # HANDOFF). Pulling in the real <mruby.h> to resolve it collides with
  # <mrubyc.h>'s own legacy mrb_int/mrb_float/E_*_ERROR compat defines
  # (confirmed via standalone compile against real picoruby-ot headers),
  # so this defines mrb_state locally instead, mirroring the same
  # `#define mrb_state void` shim picoruby-mrubyc/include/mruby.h uses.
  def test_defines_mrb_state_locally_instead_of_including_mruby_header
    assert_no_match(/#include <mruby\.h>/, @c)
    assert_match(/#define mrb_state void/, @c)
  end

  def test_int_wrapper_checks_type_and_returns_via_set_int_return
    assert_match(/if \(v\[1\]\.tt != MRBC_TT_INTEGER\)/, @c)
    assert_match(/if \(v\[2\]\.tt != MRBC_TT_INTEGER\)/, @c)
    assert_match(/mrb_int a0 = v\[1\]\.i; mrb_int a1 = v\[2\]\.i;/, @c)
    assert_match(/add\(\(intptr_t\)a0, \(intptr_t\)a1\)/, @c)
    assert_match(/SET_INT_RETURN\(r\);/, @c)
  end

  def test_float_wrapper
    assert_match(/if \(v\[1\]\.tt != MRBC_TT_FLOAT\)/, @c)
    assert_match(/mrb_float a0 = v\[1\]\.d;/, @c)
    assert_match(/SET_FLOAT_RETURN\(r\);/, @c)
  end

  # mrbc_string_new takes an explicit length (unlike a strlen-based
  # constructor), so an embedded NUL in a spinel-tracked return string
  # doesn't get silently truncated -- same str_len bridge Binding::Mruby uses.
  def test_string_wrapper
    assert_match(/if \(v\[1\]\.tt != MRBC_TT_STRING\)/, @c)
    assert_match(/const char \*a0 = \(const char \*\)v\[1\]\.string->data;/, @c)
    assert_match(/SET_RETURN\(mrbc_string_new\(vm, r, addlib_str_len\(r\)\)\);/, @c)
  end

  # bool params accept any value via Ruby truthiness (nil/false vs
  # everything else) -- no v[].tt type check, mirroring mrb_get_args's "b".
  def test_bool_wrapper_has_no_type_check_but_returns_via_set_bool_return
    truthy_wrapper = @c[/static void c_suppi_truthy.*?\n\}/m]
    assert_no_match(/wrong argument type/, truthy_wrapper)
    assert_match(/int a0 = \(v\[1\]\.tt != MRBC_TT_NIL && v\[1\]\.tt != MRBC_TT_FALSE\);/, truthy_wrapper)
    assert_match(/truthy\(\(int\)a0\)/, truthy_wrapper)
    assert_match(/SET_BOOL_RETURN\(r\);/, truthy_wrapper)
  end

  def test_void_wrapper_returns_nil
    assert_match(/static void c_suppi_boom\(struct VM \*vm, mrbc_value v\[\], int argc\) \{/, @c)
    assert_match(/boom\(\);/, @c)
    assert_match(/SET_NIL_RETURN\(\);/, @c)
  end

  def test_wrapper_checks_argument_count
    assert_match(/if \(argc != 2\) \{ mrbc_raise\(vm, MRBC_CLASS\(ArgumentError\), "wrong number of arguments"\); return; \}/, @c)
    assert_match(/if \(argc != 0\) \{ mrbc_raise\(vm, MRBC_CLASS\(ArgumentError\), "wrong number of arguments"\); return; \}/, @c)
  end

  # spinel's error signal (per-library `_error`/`_error_message` globals,
  # same ones Binding::Mruby checks) is surfaced as a raised RuntimeError
  # rather than silently returning a garbage value.
  def test_checks_spinel_error_signal_after_call
    assert_match(/if \(addlib_error\(\)\) \{ mrbc_raise\(vm, MRBC_CLASS\(RuntimeError\), addlib_error_message\(\)\); return; \}/, @c)
  end

  # On mrubyc firmware the ONLY registration path that actually runs is
  # picoruby-require's prebuilt_gems[] table: `require '<lib>'` calls
  # `mrbc_<lib>_init(mrbc_vm *vm)` (name derived by picoruby-require's
  # collect_gems from the gem dir name) and then loads the gem's mrblib
  # bytecode. The mruby-style aggregate gem_init.c exists in the build tree
  # but its object is never pulled out of libmruby.a by the mrubyc firmware
  # link, so registrations living only in mrb_*_gem_init never execute.
  def test_defines_mrbc_init_as_picogem_initializer_registering_on_object
    init = @c[/void mrbc_addlib_init\(mrbc_vm \*vm\) \{.*?\n\}/m]
    assert_not_nil init, "expected mrbc_addlib_init(mrbc_vm *vm) definition"
    assert_match(/addlib_init\(\);/, init)
    assert_match(/mrbc_define_method\(0, 0, "add", c_suppi_add\);/, init)
    assert_match(/mrbc_define_method\(0, 0, "boom", c_suppi_boom\);/, init)
  end

  def test_gem_init_matches_lifecycle_hook_signature_and_delegates_to_mrbc_init
    assert_match(/void mrb_picoruby_addlib_gem_init\(mrb_state \*mrb\) \{ \(void\)mrb; mrbc_addlib_init\(0\); \}/, @c)
  end

  def test_gem_final_matches_lifecycle_hook_signature
    assert_match(/void mrb_picoruby_addlib_gem_final\(mrb_state \*mrb\) \{ \(void\)mrb; \}/, @c)
  end
end
