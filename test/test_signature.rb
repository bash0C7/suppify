# test/test_signature.rb
require "test_helper"
require "suppify/signature"

class TestSignature < Test::Unit::TestCase
  C = <<~C
    static mrb_int sp_add(mrb_int a, mrb_int b) {
      return a + b;
    }
    static const char *sp_greet(const char *name) {
      return name;
    }
    static void sp_noop(void) { }
  C

  def test_extract_scalar_two_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_add")
    assert_equal "mrb_int", sig.return_type
    assert_equal [["mrb_int", "a"], ["mrb_int", "b"]], sig.params
  end

  def test_extract_pointer_return_and_arg
    sig = Suppify::SignatureExtractor.extract(C, "sp_greet")
    assert_equal "const char *", sig.return_type
    assert_equal [["const char *", "name"]], sig.params
  end

  def test_extract_void_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_noop")
    assert_equal "void", sig.return_type
    assert_equal [], sig.params
  end

  def test_missing_definition_raises
    assert_raise(Suppify::Error) { Suppify::SignatureExtractor.extract(C, "sp_absent") }
  end
end
