require "test_helper"

class TestCLI < Test::Unit::TestCase
  def parse(*argv) = Suppify::CLI.parse(argv)

  def test_defaults
    assert_equal({ kernel: "k/calc.rb", entries: ["Calc.add", "Calc.even?"], name: "calc", out_dir: ".", license: "MIT", newlib: false,
                   vm: true, workers: 0, table: nil },
                 parse("k/calc.rb", "Calc.add", "Calc.even?"))
  end

  def test_callers_decide_the_instances
    assert_equal [true, 1, "multicore_kernels"], parse("calc.rb", "Calc.add", "--table", "multicore_kernels").values_at(:vm, :workers, :table)
    assert_equal [false, 1], parse("calc.rb", "Calc.add", "--no-vm").values_at(:vm, :workers)
    assert_equal [true, 2], parse("calc.rb", "Calc.add", "--workers", "2").values_at(:vm, :workers)
    assert_raise(Suppify::Error) { parse("calc.rb", "Calc.add", "--no-vm", "--workers", "0") }
    assert_raise(Suppify::Error) { parse("calc.rb", "Calc.add", "--table", "t", "--workers", "0") }
    assert_raise(Suppify::Error) { parse("calc.rb", "Calc.add", "--workers", "two") }
    assert_raise(Suppify::Error) { parse("calc.rb", "Calc.add", "--table", "multi-core") }
  end

  def test_flags
    opts = parse("calc.rb", "-o", "fast", "Calc.add", "-d", "out", "--license", "BSD-2-Clause", "--newlib")
    assert_equal ["fast", "out", "BSD-2-Clause", true], opts.values_at(:name, :out_dir, :license, :newlib)
  end

  def test_rejects_missing_entries_and_values
    assert_raise(Suppify::Error) { parse("calc.rb") }
    assert_raise(Suppify::Error) { parse("calc.rb", "Calc.add", "-o") }
  end

  def test_rejects_entries_that_are_not_module_methods
    error = assert_raise(Suppify::Error) { parse("calc.rb", "add", "Calc#add") }
    assert_equal "entries must be Module.method: add, Calc#add", error.message
  end

  def test_rejects_an_entry_listed_twice_and_an_unknown_option
    assert_equal "entries listed more than once: Calc.add", assert_raise(Suppify::Error) { parse("calc.rb", "Calc.add", "Calc.add") }.message
    assert_match(/\Aunknown option --newlb\n/, assert_raise(Suppify::Error) { parse("calc.rb", "Calc.add", "--newlb") }.message)
  end

  def test_rejects_a_name_that_is_not_a_c_identifier
    assert_raise(Suppify::Error) { parse("my-calc.rb", "Calc.add") }
  end
end
