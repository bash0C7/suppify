# test/test_binding_mruby.rb
require "test_helper"
require "suppify/binding/mruby"
require "suppify/signature"

class TestBindingMruby < Test::Unit::TestCase
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
    @c = Suppify::Binding::Mruby.render("addlib", "mrb_picoruby_addlib_gem_init", @exports)
  end

  def test_includes_mruby_headers_and_neutral_header
    assert_match(/#include <mruby\.h>/, @c)
    assert_match(/#include <mruby\/string\.h>/, @c)
    assert_match(/#include "addlib\.h"/, @c)
  end

  def test_int_wrapper_uses_get_args_and_fixnum_return
    assert_match(/mrb_int a0, a1;/, @c)
    assert_match(/mrb_get_args\(mrb, "ii", &a0, &a1\);/, @c)
    assert_match(/add\(\(intptr_t\)a0, \(intptr_t\)a1\)/, @c)
    assert_match(/return mrb_fixnum_value\(\(mrb_int\)r\);/, @c)
  end

  def test_float_wrapper
    assert_match(/mrb_float a0;/, @c)
    assert_match(/mrb_get_args\(mrb, "f", &a0\);/, @c)
    assert_match(/return mrb_float_value\(mrb, r\);/, @c)
  end

  def test_string_wrapper
    assert_match(/const char \*a0;/, @c)
    assert_match(/mrb_get_args\(mrb, "z", &a0\);/, @c)
    assert_match(/return mrb_str_new_cstr\(mrb, r\);/, @c)
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

  def test_error_raised_after_each_call
    assert_match(/if \(suppi_error\(\)\) mrb_raise\(mrb, E_RUNTIME_ERROR, suppi_error_message\(\)\);/, @c)
  end

  def test_gem_init_defines_kernel_methods
    assert_match(/void mrb_picoruby_addlib_gem_init\(mrb_state \*mrb\)/, @c)
    assert_match(/sp_lib_init\(\);/, @c)
    assert_match(/mrb_define_method\(mrb, mrb->kernel_module, "add", \w+, MRB_ARGS_REQ\(2\)\);/, @c)
    assert_match(/mrb_define_method\(mrb, mrb->kernel_module, "boom", \w+, MRB_ARGS_REQ\(0\)\);/, @c)
  end

  # picoruby's generated gem_init.c references both _gem_init and _gem_final;
  # the binding must define the (empty) final too or the firmware link fails.
  def test_defines_gem_final
    assert_match(/void mrb_picoruby_addlib_gem_final\(mrb_state \*mrb\)/, @c)
  end
end
