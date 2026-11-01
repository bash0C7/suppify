require "test_helper"

class TestGlue < Test::Unit::TestCase
  def lib = Fixtures.library([Fixtures.entry("add", "sp_int", "sp_int", "sp_int"),
                              Fixtures.entry("greet", "const char *", "sp_String *"),
                              Fixtures.entry("even?", "sp_bool", "sp_int", cname: "sp_Calc_s_even_p"),
                              Fixtures.entry("go", "void")])

  def test_the_header_states_the_contract_in_plain_c
    h = Suppify::Glue.header(lib)
    assert_include h, "#define SUPPIFY_MALFORMED (-1)"
    assert_include h, "} suppify_kernel_t;"
    assert_include h, "void calc_init(void);"
    assert_include h, "int calc_Calc_add(intptr_t a0, intptr_t a1, intptr_t *ret);"
    assert_include h, "int calc_Calc_greet(const char *s0, size_t n0, const char **ret, size_t *ret_len);"
    assert_include h, "int calc_Calc_even_p(intptr_t a0, bool *ret);"
    assert_include h, "int calc_Calc_go(void);"
    assert_include h, "int32_t calc_Calc_add_call(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t out_cap);"
    assert_include h, "extern const suppify_kernel_t calc_kernels[];"
    assert_not_include h, "sp_"
  end

  def test_the_source_calls_each_entry_inside_the_try_frame
    c = Suppify::Glue.source(lib)
    assert_include c, %(#include "calc_spinel.h")
    assert_include c, "if (!calc_spinel_try(body, ctx, &cls, &msg)) return 0;"
    assert_include c, "sp_String * a0 = SP_STR_HDL(sp_str_from_bytes(c->s0, c->n0)); SP_GC_ROOT(a0);"
    assert_include c, "c->ret_len = c->ret ? sp_str_byte_len(c->ret) : 0;"
    assert_include c, "c->ret = sp_Calc_s_even_p(c->a0);"
    assert_include c, %({ "even?", calc_Calc_even_p_call, calc_Calc_even_p_signature, calc_init, calc_error_message },)
    assert_include c, %(return "(Integer) -> bool";)
  end

  def test_a_type_outside_the_contract_names_the_entry
    error = assert_raise(Suppify::Error) { Suppify::Glue.source(Fixtures.library([Fixtures.entry("sum", "sp_int", "sp_IntArray *")])) }
    assert_equal "Calc.sum has sp_IntArray *, which crosses no contract suppify writes", error.message
  end

  def test_the_kernel_table_names_each_method_once
    twice = [Fixtures.entry("run", "void"), Fixtures.entry("run", "void", mod: "Other")]
    error = assert_raise(Suppify::Error) { Suppify::Glue.source(Fixtures.library(twice)) }
    assert_equal "entries share a method name across modules: run", error.message
  end
end
