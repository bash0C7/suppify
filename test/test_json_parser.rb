# test/test_json_parser.rb
require "test_helper"
require "suppify/json_parser"

class TestJSONParser < Test::Unit::TestCase
  def parse(s) = Suppify::JSONParser.parse(s)

  def test_object_array_of_objects
    json = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"}]}'
    result = parse(json)
    assert_equal "sp_add", result["symbols"][0]["c"]
    assert_equal "add",    result["symbols"][0]["ruby"]
  end

  def test_scalars_and_nesting
    assert_equal({"a" => 1, "b" => [true, false, nil], "c" => "x\"y"},
                 parse('{"a":1,"b":[true,false,null],"c":"x\"y"}'))
  end

  def test_empty_containers
    assert_equal({"a" => [], "b" => {}}, parse('{"a":[],"b":{}}'))
  end
end
