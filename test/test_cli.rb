# test/test_cli.rb
require "test_helper"
require "suppify/cli"

class TestCLI < Test::Unit::TestCase
  def test_parses_input_and_output
    opts = Suppify::CLI.parse(["app.rb", "-o", "mylib"])
    assert_equal "app.rb", opts[:input]
    assert_equal "mylib",  opts[:lib_name]
  end

  def test_defaults_lib_name_from_input
    opts = Suppify::CLI.parse(["foo/bar.rb"])
    assert_equal "bar", opts[:lib_name]
  end

  def test_missing_input_raises
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["-o", "x"]) }
  end

  def test_target_defaults_to_c
    assert_equal "c", Suppify::CLI.parse(["app.rb"])[:target]
  end

  def test_parses_target
    assert_equal "cruby",    Suppify::CLI.parse(["app.rb", "-t", "cruby"])[:target]
    assert_equal "picoruby", Suppify::CLI.parse(["app.rb", "--target", "picoruby"])[:target]
  end

  def test_unknown_target_raises
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["app.rb", "-t", "rust"]) }
  end
end
