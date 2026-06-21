# test/test_main_renamer.rb
require "test_helper"
require "suppify/main_renamer"

class TestMainRenamer < Test::Unit::TestCase
  def test_renames_standard_main
    src = "int main(int argc, char **argv) {\n  return 0;\n}\n"
    out = Suppify::MainRenamer.rename(src)
    assert_match(/static int sp__main\(int argc, char \*\*argv\)/, out)
    assert_no_match(/\bint main\b/, out)
  end

  def test_tolerates_spacing_variants
    src = "int  main ( int argc , char** argv )\n{\nreturn 0;\n}\n"
    out = Suppify::MainRenamer.rename(src)
    assert_match(/static int sp__main\s*\(/, out)
  end

  def test_raises_when_no_main
    assert_raise(Suppify::Error) { Suppify::MainRenamer.rename("int foo(void){return 0;}") }
  end
end
