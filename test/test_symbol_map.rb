# test/test_symbol_map.rb
require "test_helper"
require "suppify/symbol_map"

class TestSymbolMap < Test::Unit::TestCase
  def setup
    json = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"},' \
           '{"c":"sp_greet","ruby":"greet","kind":"toplevel"}]}'
    @map = Suppify::SymbolMap.from_json(json)
  end

  def test_cname_for_ruby_name
    assert_equal "sp_add", @map.cname_for("add")
    assert_equal "sp_greet", @map.cname_for("greet")
  end

  def test_unknown_returns_nil
    assert_nil @map.cname_for("missing")
  end

  def test_kind
    assert_equal "toplevel", @map.kind_for("add")
  end
end
