# test/test_pipeline.rb
require "test_helper"
require "suppify/pipeline"

class TestPipeline < Test::Unit::TestCase
  RUBY = <<~RUBY
    def add(a, b) = a + b
    private
    def helper(x) = x
  RUBY

  C = <<~C
    static mrb_int sp_add(mrb_int a, mrb_int b) { return a + b; }
    static mrb_int sp_helper(mrb_int x) { return x; }
    int main(int argc, char **argv) { return 0; }
  C

  SYMS = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"},' \
         '{"c":"sp_helper","ruby":"helper","kind":"toplevel"}]}'

  def setup
    @r = Suppify::Pipeline.new(ruby_source: RUBY, c_source: C,
                               symbols_json: SYMS, lib_name: "mylib").run
  end

  def test_exports_only_public_methods
    names = @r[:exports].map { |e| e["public"] }
    assert_equal ["add"], names
  end

  def test_c_output_has_trampoline_and_renamed_main
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\)/, @r[:c_source])
    assert_match(/static int sp__main\(/, @r[:c_source])
    assert_no_match(/\bint main\b/, @r[:c_source])
  end

  def test_private_method_not_exported_but_still_static_in_c
    assert_no_match(/intptr_t helper\(/, @r[:c_source])  # not a public trampoline
    assert_match(/static mrb_int sp_helper/, @r[:c_source]) # still present + hidden
  end

  def test_header_present
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @r[:header])
  end

  def test_public_method_with_non_neutral_signature_raises
    bad_c = "static sp_RbVal sp_add(sp_RbVal a) { return a; }\nint main(int c,char**v){return 0;}\n"
    bad_syms = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"}]}'
    assert_raise(Suppify::NonNeutralType) do
      Suppify::Pipeline.new(ruby_source: "def add(a)=a", c_source: bad_c,
                            symbols_json: bad_syms, lib_name: "x").run
    end
  end
end
