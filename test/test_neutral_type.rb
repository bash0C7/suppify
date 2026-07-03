# test/test_neutral_type.rb
require "test_helper"
require "suppify/neutral_type"

class TestNeutralType < Test::Unit::TestCase
  def map(t) = Suppify::NeutralType.map(t)

  def test_mrb_int_to_intptr
    assert_equal "intptr_t", map("mrb_int")
  end

  def test_double_passthrough
    assert_equal "double", map("double")
  end

  def test_mrb_float_to_double
    assert_equal "double", map("mrb_float")
  end

  def test_const_char_ptr_passthrough
    assert_equal "const char *", map("const char *")
  end

  def test_bool_to_int
    assert_equal "int", map("bool")
    assert_equal "int", map("_Bool")
    assert_equal "int", map("mrb_bool")
  end

  def test_void_passthrough
    assert_equal "void", map("void")
  end

  def test_non_neutral_raises
    assert_raise(Suppify::NonNeutralType) { map("sp_RbVal") }
    assert_raise(Suppify::NonNeutralType) { map("sp_Proc *") }
  end

  # kind classifies a (spinel or neutral) C type into a language-agnostic
  # marshalling category the per-target bindings switch on.
  def test_kind_classifies_scalars
    assert_equal :int,    Suppify::NeutralType.kind("mrb_int")
    assert_equal :int,    Suppify::NeutralType.kind("intptr_t")
    assert_equal :float,  Suppify::NeutralType.kind("mrb_float")
    assert_equal :float,  Suppify::NeutralType.kind("double")
    assert_equal :string, Suppify::NeutralType.kind("const char *")
    assert_equal :string, Suppify::NeutralType.kind("char *")
    assert_equal :bool,   Suppify::NeutralType.kind("mrb_bool")
    assert_equal :bool,   Suppify::NeutralType.kind("bool")
    assert_equal :void,   Suppify::NeutralType.kind("void")
  end

  def test_kind_raises_on_non_neutral
    assert_raise(Suppify::NonNeutralType) { Suppify::NeutralType.kind("sp_RbVal") }
  end
end
