require "test_helper"

class TestSpinelIntegration < Test::Unit::TestCase
  def setup
    omit("spinel is not on PATH and SPINEL is unset") if Fixtures.spinel.empty?
    @spinel = Suppify::Spinel.new(bin: Fixtures.spinel)
  end

  def test_reads_each_entry_signature_from_the_library_header
    lib = @spinel.compile(Fixtures::CALC, Fixtures::CALC_ENTRIES, name: "calc")
    signatures = lib.entries.to_h { |e| ["#{e.mod}.#{e.name}", [e.func, e.ret, e.params]] }
    assert_equal({
      "Calc.add" => ["Calc_add", "sp_int", %w[sp_int sp_int]],
      "Calc.half" => ["Calc_half", "sp_float", %w[sp_float]],
      "Calc.greet" => ["Calc_greet", "const char *", ["sp_String *"]],
      "Calc.even?" => ["Calc_even_p", "sp_bool", %w[sp_int]],
      "Calc.check" => ["Calc_check", "sp_int", %w[sp_int]],
      "Calc.nully" => ["Calc_nully", "const char *", []],
      "Calc.blen" => ["Calc_blen", "sp_int", ["sp_String *"]],
      "Calc.ignore" => ["Calc_ignore", "void", %w[sp_int]],
    }, signatures)
    assert_include lib.kernel_h, "void calc_spinel(void);"
    assert_not_include lib.kernel_c, "int main("
    assert File.exist?(File.join(lib.runtime_dir, "spinel_rt.h"))
    assert_include lib.defines, "SP_ONE_STRING"
  end

  def test_carries_a_kernel_s_ffi_build_settings
    lib = @spinel.compile(File.expand_path("fixtures/ffi.rb", __dir__), %w[Ffi.mag], name: "ffi")
    assert_include lib.libs, "m"
    assert_include lib.cflags, "-DHW_BOARD=1"
    assert_include lib.kernel_c, "labs"
  end

  def test_an_entry_the_kernel_does_not_define_fails
    assert_raise(Suppify::Error) { @spinel.compile(Fixtures::CALC, %w[Calc.nope], name: "calc") }
  end

  def test_cli_writes_a_gem_with_every_entry_registered
    Dir.mktmpdir do |dir|
      out, = capture_output { Fixtures.calc_gem(dir) }
      assert_equal "wrote #{dir}/picoruby-calc (8 entries)\n", out
      binding_c = File.read(File.join(dir, "picoruby-calc/src/binding.c"))
      assert_include binding_c, %(mrb_define_class_method(mrb, m0, "even?", sx_Calc_even_p, MRB_ARGS_REQ(1));)
      assert_include binding_c, %(mrbc_define_method(vm, m0, "even?", sx_Calc_even_p);)
    end
  end
end
