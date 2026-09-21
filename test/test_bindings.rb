# test/test_bindings.rb — the バインディング layer (lib/suppify/bindings.rb):
# per-VM C renderers (CRuby / Mruby / Mrubyc).
require "test_helper"

class TestBindingCRuby < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add",   "cname" => "sp_add",
        "sig" => Suppify::Signature.new("sp_int", [["sp_int", "a"], ["sp_int", "b"]]) },
      { "public" => "half",  "cname" => "sp_half",
        "sig" => Suppify::Signature.new("sp_float", [["sp_float", "x"]]) },
      { "public" => "greet", "cname" => "sp_greet",
        "sig" => Suppify::Signature.new("const char *", [["const char *", "name"]]) },
      { "public" => "even",  "cname" => "sp_even",
        "sig" => Suppify::Signature.new("sp_bool", [["sp_int", "n"]]) },
      { "public" => "truthy", "cname" => "sp_truthy",
        "sig" => Suppify::Signature.new("sp_bool", [["sp_bool", "flag"]]) },
      { "public" => "boom",  "cname" => "sp_boom",
        "sig" => Suppify::Signature.new("void", []) },
    ]
    @c = Suppify::Binding::CRuby.render("addlib", @exports)
  end

  def test_includes_ruby_and_neutral_header
    assert_match(/#include <ruby\.h>/, @c)
    assert_match(/#include "addlib\.h"/, @c)
  end

  def test_int_wrapper_marshals_both_directions
    assert_match(/VALUE\s+\w*add\w*\(VALUE self, VALUE a0, VALUE a1\)/, @c)
    assert_match(/add\(\(intptr_t\)NUM2LONG\(a0\), \(intptr_t\)NUM2LONG\(a1\)\)/, @c)
    assert_match(/return LONG2NUM\(\(long\)r\);/, @c)
  end

  def test_float_wrapper
    assert_match(/half\(NUM2DBL\(a0\)\)/, @c)
    assert_match(/return DBL2NUM\(r\);/, @c)
  end

  # rb_str_new_cstr is strlen-based, silently truncating a String return that
  # contains an embedded NUL. lib_name_str_len recovers spinel's own tracked
  # byte length, so rb_str_new (explicit length) builds the Ruby string with
  # the correct size regardless of embedded NULs.
  def test_string_wrapper
    assert_match(/greet\(StringValueCStr\(a0\)\)/, @c)
    assert_match(/return rb_str_new\(r, addlib_str_len\(r\)\);/, @c)
  end

  def test_bool_wrapper
    assert_match(/truthy\(\(RTEST\(a0\) \? 1 : 0\)\)/, @c)
    assert_match(/return r \? Qtrue : Qfalse;/, @c)
  end

  def test_void_wrapper_takes_no_args_and_returns_nil
    assert_match(/\w*boom\w*\(VALUE self\)/, @c)
    assert_match(/return Qnil;/, @c)
  end

  # Per-library error API name (not the generic "suppi_error") so two suppify
  # libraries linked into the same binary don't collide.
  def test_error_is_raised_after_each_call
    assert_match(/if \(addlib_error\(\)\) rb_raise\(rb_eRuntimeError, "%s", addlib_error_message\(\)\);/, @c)
  end

  def test_init_registers_all_as_global_functions
    assert_match(/void Init_addlib\(void\)/, @c)
    assert_match(/addlib_init\(\);/, @c)
    assert_match(/rb_define_global_function\("add", \w+, 2\);/, @c)
    assert_match(/rb_define_global_function\("half", \w+, 1\);/, @c)
    assert_match(/rb_define_global_function\("boom", \w+, 0\);/, @c)
  end
end

class TestBindingMruby < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add",   "cname" => "sp_add",
        "sig" => Suppify::Signature.new("sp_int", [["sp_int", "a"], ["sp_int", "b"]]) },
      { "public" => "half",  "cname" => "sp_half",
        "sig" => Suppify::Signature.new("sp_float", [["sp_float", "x"]]) },
      { "public" => "greet", "cname" => "sp_greet",
        "sig" => Suppify::Signature.new("const char *", [["const char *", "name"]]) },
      { "public" => "even",  "cname" => "sp_even",
        "sig" => Suppify::Signature.new("sp_bool", [["sp_int", "n"]]) },
      { "public" => "truthy", "cname" => "sp_truthy",
        "sig" => Suppify::Signature.new("sp_bool", [["sp_bool", "flag"]]) },
      { "public" => "boom",  "cname" => "sp_boom",
        "sig" => Suppify::Signature.new("void", []) },
    ]
    @c = Suppify::Binding::Mruby.render("addlib", "mrb_picoruby_addlib_gem_init", @exports)
  end

  def test_includes_mruby_headers_and_neutral_header
    assert_match(/#include <mruby\.h>/, @c)
    assert_match(/#include <mruby\/string\.h>/, @c)
    assert_match(/#include "addlib\.h"/, @c)
  end

  def test_int_wrapper_uses_get_args_and_fixnum_return
    assert_match(/mrb_int a0; mrb_int a1;/, @c)
    assert_match(/mrb_get_args\(mrb, "ii", &a0, &a1\);/, @c)
    assert_match(/add\(\(intptr_t\)a0, \(intptr_t\)a1\)/, @c)
    assert_match(/return mrb_fixnum_value\(\(mrb_int\)r\);/, @c)
  end

  def test_float_wrapper
    assert_match(/mrb_float a0;/, @c)
    assert_match(/mrb_get_args\(mrb, "f", &a0\);/, @c)
    assert_match(/return mrb_float_value\(mrb, r\);/, @c)
  end

  # mrb_str_new_cstr is strlen-based, silently truncating a String return
  # that contains an embedded NUL. lib_name_str_len recovers spinel's own
  # tracked byte length, so mrb_str_new (explicit length) builds the mruby
  # string with the correct size regardless of embedded NULs.
  def test_string_wrapper
    assert_match(/const char \*a0;/, @c)
    assert_match(/mrb_get_args\(mrb, "z", &a0\);/, @c)
    assert_match(/return mrb_str_new\(mrb, r, addlib_str_len\(r\)\);/, @c)
  end

  def test_bool_wrapper
    # even: bool return only; truthy: bool param and bool return
    assert_match(/mrb_bool a0;/, @c)
    assert_match(/mrb_get_args\(mrb, "b", &a0\);/, @c)
    assert_match(/truthy\(\(int\)a0\)/, @c)
    assert_match(/return mrb_bool_value\(r\);/, @c)
  end

  def test_void_wrapper_returns_nil_and_takes_no_args
    assert_match(/sp_boom is void.*|boom\(\);/, @c)
    assert_match(/return mrb_nil_value\(\);/, @c)
  end

  # Per-library error API name (not the generic "suppi_error") so two suppify
  # libraries linked into the same firmware image don't collide.
  def test_error_raised_after_each_call
    assert_match(/if \(addlib_error\(\)\) mrb_raise\(mrb, E_RUNTIME_ERROR, addlib_error_message\(\)\);/, @c)
  end

  def test_gem_init_defines_kernel_methods
    assert_match(/void mrb_picoruby_addlib_gem_init\(mrb_state \*mrb\)/, @c)
    assert_match(/addlib_init\(\);/, @c)
    assert_match(/mrb_define_method\(mrb, mrb->kernel_module, "add", \w+, MRB_ARGS_REQ\(2\)\);/, @c)
    assert_match(/mrb_define_method\(mrb, mrb->kernel_module, "boom", \w+, MRB_ARGS_REQ\(0\)\);/, @c)
  end

  # picoruby's generated gem_init.c references both _gem_init and _gem_final;
  # the binding must define the (empty) final too or the firmware link fails.
  def test_defines_gem_final
    assert_match(/void mrb_picoruby_addlib_gem_final\(mrb_state \*mrb\)/, @c)
  end
end

class TestBindingMrubyc < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add",   "cname" => "sp_add",
        "sig" => Suppify::Signature.new("sp_int", [["sp_int", "a"], ["sp_int", "b"]]) },
      { "public" => "half",  "cname" => "sp_half",
        "sig" => Suppify::Signature.new("sp_float", [["sp_float", "x"]]) },
      { "public" => "greet", "cname" => "sp_greet",
        "sig" => Suppify::Signature.new("const char *", [["const char *", "name"]]) },
      { "public" => "even",  "cname" => "sp_even",
        "sig" => Suppify::Signature.new("sp_bool", [["sp_int", "n"]]) },
      { "public" => "truthy", "cname" => "sp_truthy",
        "sig" => Suppify::Signature.new("sp_bool", [["sp_bool", "flag"]]) },
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

# A method whose RBS gives it an Array/Hash/Symbol parameter or return has
# no neutral scalar C entry for a VM binding to wrap -- its contract is the
# flat MessagePack entry. Each renderer skips it, so the emitted gem still
# builds (and the VM caller keeps using the interpreted method, or the flat
# entry, for that one).
class TestBindingSkipsNonNeutralExports < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add", "cname" => "sp_add", "neutral" => true,
        "sig" => Suppify::Signature.new("sp_int", [["sp_int", "a"], ["sp_int", "b"]]) },
      { "public" => "scale", "cname" => "sp_scale", "neutral" => false, "flat" => true,
        "sig" => Suppify::Signature.new("sp_int", [["sp_IntArray *", "xs"]]) },
    ]
  end

  def test_cruby_binding_wraps_only_the_neutral_export
    c = Suppify::Binding::CRuby.render("addlib", @exports)
    assert_match(/rb_define_global_function\("add"/, c)
    assert_no_match(/scale/, c)
  end

  def test_mruby_binding_wraps_only_the_neutral_export
    c = Suppify::Binding::Mruby.render("addlib", "mrb_picoruby_addlib_gem_init", @exports)
    assert_match(/mrb_define_method\(mrb, mrb->kernel_module, "add"/, c)
    assert_no_match(/scale/, c)
  end

  def test_mrubyc_binding_wraps_only_the_neutral_export
    c = Suppify::Binding::Mrubyc.render("addlib", "mrb_picoruby_addlib_gem_init", @exports)
    assert_match(/mrbc_define_method\(0, 0, "add", c_suppi_add\);/, c)
    assert_no_match(/scale/, c)
  end

  # Exports from a Pipeline that predates the "neutral" key (or a scalar-only
  # library) are wrapped as before.
  def test_exports_without_the_neutral_key_are_still_wrapped
    plain = [{ "public" => "add", "cname" => "sp_add",
               "sig" => Suppify::Signature.new("sp_int", [["sp_int", "a"], ["sp_int", "b"]]) }]
    assert_match(/rb_define_global_function\("add"/, Suppify::Binding::CRuby.render("addlib", plain))
  end
end
