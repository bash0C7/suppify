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

  def test_includes_stddef_for_size_t
    assert_match(/#include <stddef.h>/, @h)
  end

  def test_neutral_prototype_no_spinel_types
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @h)
    assert_no_match(/mrb_int/, @h)
  end

  # Per-library names (not generic ones) so two suppify libraries linked into
  # the same binary don't collide on the lifecycle/error API.
  def test_lifecycle_and_error_api
    assert_match(/void mylib_init\(void\);/, @h)
    assert_match(/int mylib_error\(void\);/, @h)
    assert_match(/const char \*mylib_error_message\(void\);/, @h)
  end

  # Lets a consumer recover a String return's true byte length instead of
  # guessing via strlen, which truncates at an embedded NUL.
  def test_declares_str_len_bridge
    assert_match(/size_t mylib_str_len\(const char \*s\);/, @h)
  end
end
