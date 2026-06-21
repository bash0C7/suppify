# test/test_visibility.rb
require "test_helper"
require "suppify/visibility"

class TestVisibility < Test::Unit::TestCase
  def pub(src) = Suppify::Visibility.public_methods(src).sort

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
end
