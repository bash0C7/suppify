# test/test_binding_cruby.rb
require "test_helper"
require "suppify/binding/cruby"
require "suppify/signature"

class TestBindingCRuby < Test::Unit::TestCase
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
