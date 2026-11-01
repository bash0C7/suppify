require "test_helper"

class TestBinding < Test::Unit::TestCase
  def lib = Fixtures.library([Fixtures.entry("add", "sp_int", "sp_int", "sp_int"),
                              Fixtures.entry("greet", "const char *", "sp_String *"),
                              Fixtures.entry("go", "void", mod: "Run")])

  def render = Suppify::Binding.render(lib)

  def test_the_vm_is_chosen_by_the_picoruby_build
    c = render
    assert_include c, %(#include "calc.h")
    assert_match(/#if defined\(PICORB_VM_MRUBYC\)\n#include <mrubyc.h>.*#else\n#include <mruby.h>/m, c)
    assert_not_include c, "spinel"
  end

  def test_mruby_registers_module_methods_through_the_plain_c_entries
    c = render
    assert_include c, %(mrb_get_args(mrb, "ii", &v0, &v1);)
    assert_include c, "if (calc_Calc_add(a0, a1, &r)) return sx_raise(mrb);"
    assert_include c, "r ? mrb_str_new(mrb, r, (mrb_int)rn) : mrb_nil_value()"
    assert_include c, %(struct RClass *m0 = mrb_define_module(mrb, "Calc");)
    assert_include c, %(mrb_define_class_method(mrb, m0, "add", sx_Calc_add, MRB_ARGS_REQ(2));)
    assert_include c, %(struct RClass *m1 = mrb_define_module(mrb, "Run");)
    assert_include c, "void mrb_picoruby_calc_gem_init(mrb_state *mrb) {"
  end

  def test_mrubyc_checks_argument_types_before_the_call
    c = render
    assert_include c, %(if (!(v[1].tt == MRBC_TT_INTEGER && v[2].tt == MRBC_TT_INTEGER)) { mrbc_raise(vm, MRBC_CLASS(TypeError), "wrong argument type"); return; })
    assert_include c, "if (calc_Calc_greet(s0, n0, &r, &rn)) { sx_raise(vm); return; }"
    assert_include c, %(mrbc_define_method(vm, m0, "add", sx_Calc_add);)
    assert_include c, "void mrbc_calc_init(mrbc_vm *vm) {"
  end
end
