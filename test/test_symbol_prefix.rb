# test/test_symbol_prefix.rb
require "test_helper"
require "suppify/symbol_prefix"
require "fileutils"
require "tmpdir"

class TestSymbolPrefix < Test::Unit::TestCase
  def test_prelude_defines_each_symbol_prefixed_by_lib_name
    h = Suppify::SymbolPrefix.prelude("addlib", %w[sp_gc_alloc sp_str_heap])
    assert_match(/#define sp_gc_alloc addlib_sp_gc_alloc/, h)
    assert_match(/#define sp_str_heap addlib_sp_str_heap/, h)
  end

  # Two different libraries must never collide on their own renamed symbols
  # either -- distinct lib_name prefixes guarantee that mechanically.
  def test_prelude_is_distinct_per_lib_name
    a = Suppify::SymbolPrefix.prelude("addlib", %w[sp_gc_alloc])
    b = Suppify::SymbolPrefix.prelude("otherlib", %w[sp_gc_alloc])
    refute_equal a, b
  end

  # The vendored (unmodified) spinel runtime trips warnings under a
  # consumer's own CFLAGS/-Wall (unused static helpers not used by every
  # program, a stray "/*" in a comment, a couple of clang-specific
  # diagnostics). Silenced portably across gcc and clang so a clean build of
  # generated code isn't mistaken for a real problem in vendored code.
  def test_prelude_suppresses_known_harmless_vendored_warnings
    h = Suppify::SymbolPrefix.prelude("addlib", [])
    assert_match(/#pragma GCC diagnostic ignored "-Wunused-function"/, h)
    assert_match(/#pragma GCC diagnostic ignored "-Wunused-variable"/, h)
    assert_match(/#pragma GCC diagnostic ignored "-Wcomment"/, h)
    assert_match(/#if defined\(__clang__\)/, h)
    assert_match(/#pragma clang diagnostic ignored "-Wmacro-redefined"/, h)
    assert_match(/#pragma clang diagnostic ignored "-Wmissing-noreturn"/, h)
  end

  def test_discover_runtime_symbols_finds_globals_not_statics
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_lib_available?

    symbols = Suppify::SymbolPrefix.discover_runtime_symbols(ENV["SPINEL_LIB"])
    assert_includes symbols, "sp_gc_alloc"
    assert_includes symbols, "sp_str_heap"
    assert_includes symbols, "re_compile"
    # spinel's own per-program codegen internals (sp_add, sp__main, ...) are
    # static and never appear here -- only the shared runtime API should.
    refute_includes symbols, "sp_add"
    refute_includes symbols, "sp__main"
  end

  # sp_runtime.h -- the header the GENERATED per-program TU includes, not one
  # of the 25 lib/*.c sources -- embeds ~200 non-static function bodies
  # directly (spinel's normal build compiles it into exactly one program TU
  # per binary). Every suppify library's own generated .c also includes it,
  # so each library's compiled copy defines these identically-named symbols
  # too; missing them from discovery left them unrenamed and colliding
  # (confirmed empirically: linking two suppify libraries failed on
  # duplicate symbols like sp_raise_cls, sp_exc_arm, sp_sprintf).
  def test_discover_runtime_symbols_includes_sp_runtime_h_embedded_functions
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_lib_available?

    symbols = Suppify::SymbolPrefix.discover_runtime_symbols(ENV["SPINEL_LIB"])
    assert_includes symbols, "sp_raise_cls"
    assert_includes symbols, "sp_exc_arm"
    assert_includes symbols, "sp_sprintf"
  end

  # sp_ctx_swap (Fiber context switch) is defined via a file-scope __asm__
  # string in sp_fiber.c with its symbol name hardcoded as a C string
  # literal -- #define text substitution never reaches inside a string, so
  # renaming its call sites (plain identifiers) while the definition stays
  # literally "sp_ctx_swap" produces an undefined-symbol link error. Left
  # out of the rename set; it's the one runtime symbol that stays shared
  # (fine in practice: it's stateless, bit-identical across libraries).
  def test_discover_runtime_symbols_excludes_asm_defined_ctx_swap
    omit("spinel not on PATH / SPINEL_LIB unset") unless spinel_lib_available?

    symbols = Suppify::SymbolPrefix.discover_runtime_symbols(ENV["SPINEL_LIB"])
    refute_includes symbols, "sp_ctx_swap"
  end

  private

  def spinel_lib_available?
    !ENV["SPINEL_LIB"].to_s.empty? && !`which cc`.strip.empty?
  end
end
