# test/test_rbs_seed.rb
require "test_helper"
require "suppify/rbs_seed"

class TestRbsSeed < Test::Unit::TestCase
  def test_parses_object_class_method_signatures
    rbs = <<~RBS
      class Object
        def add: (Integer, Integer) -> Integer
        def boom: () -> void
      end
    RBS
    sigs = Suppify::RbsSeed.parse(rbs)
    assert_equal ["Integer", "Integer"], sigs["add"][:params]
    assert_equal "Integer", sigs["add"][:ret]
    assert_equal [], sigs["boom"][:params]
    assert_equal "void", sigs["boom"][:ret]
  end

  def test_root_call_for_builds_literal_call_line
    add_sig = { params: ["Integer", "Integer"], ret: "Integer" }
    boom_sig = { params: [], ret: "void" }
    assert_equal "add(0, 0)", Suppify::RbsSeed.root_call_for("add", add_sig)
    assert_equal "boom()", Suppify::RbsSeed.root_call_for("boom", boom_sig)
  end

  def test_unsupported_param_type_raises
    sig = { params: ["Array[Integer]"], ret: "void" }
    assert_raise(Suppify::Error) { Suppify::RbsSeed.root_call_for("f", sig) }
  end
end
