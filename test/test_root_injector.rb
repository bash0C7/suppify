# test/test_root_injector.rb
require "test_helper"
require "suppify/root_injector"

class TestRootInjector < Test::Unit::TestCase
  def test_appends_synthetic_calls_for_each_public_method
    src = "def add(a, b) = a + b\ndef boom = raise \"x\"\n"
    sigs = {
      "add" => { params: ["Integer", "Integer"], ret: "Integer" },
      "boom" => { params: [], ret: "void" },
    }
    out = Suppify::RootInjector.inject(src, ["add", "boom"], sigs)
    assert_match(/\Adef add.*\n\z/m, out)
    assert_match(/add\(0, 0\)\n/, out)
    assert_match(/boom\(\)\n/, out)
  end

  def test_missing_signature_raises
    src = "def add(a, b) = a + b\n"
    assert_raise(Suppify::Error) { Suppify::RootInjector.inject(src, ["add"], {}) }
  end
end
