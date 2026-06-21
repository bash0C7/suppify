# test/test_header.rb
require "test_helper"
require "suppify/header"
require "suppify/signature"

class TestHeader < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add", "cname" => "sp_add",
        "sig" => Suppify::Signature.new("mrb_int", [["mrb_int","a"],["mrb_int","b"]]) },
    ]
    @h = Suppify::Header.render("mylib", @exports)
  end

  def test_include_guard
    assert_match(/#ifndef MYLIB_H/, @h)
    assert_match(/#define MYLIB_H/, @h)
    assert_match(/#endif/, @h)
  end

  def test_includes_stdint_for_intptr
    assert_match(/#include <stdint.h>/, @h)
  end

  def test_neutral_prototype_no_spinel_types
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @h)
    assert_no_match(/mrb_int/, @h)
  end

  def test_lifecycle_and_error_api
    assert_match(/void sp_lib_init\(void\);/, @h)
    assert_match(/int suppi_error\(void\);/, @h)
    assert_match(/const char \*suppi_error_message\(void\);/, @h)
  end
end
