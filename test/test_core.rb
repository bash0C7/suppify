# test/test_core.rb — the コア layer (lib/suppify/core.rb): NeutralType,
# RbsType, Signature/SignatureExtractor, Source, SpinelRunner, FlatCall,
# Pipeline.
require "test_helper"

class TestRbsType < Test::Unit::TestCase
  def parse(t) = Suppify::RbsType.parse(t)

  def test_parses_simple_names
    t = parse("Integer")
    assert_equal :simple, t.kind
    assert_equal "Integer", t.name
  end

  def test_parses_containers_and_round_trips_canonical_text
    ["Array[Integer]", "Hash[Symbol, Float]", "Array[Array[String]]",
     "Hash[String, Array[Float]]", "[Integer, String]", "Integer?",
     "Array[Hash[Integer, Integer]]"].each do |text|
      assert_equal text, parse(text).to_s
    end
  end

  def test_parses_nested_structure_not_just_text
    t = parse("Hash[Symbol, Array[Float]]")
    assert_equal :hash, t.kind
    assert_equal "Symbol", t.args[0].name
    assert_equal :array, t.args[1].kind
    assert_equal "Float", t.args[1].args[0].name
  end

  def test_tolerates_spacing
    assert_equal "Hash[Symbol, Float]", parse("Hash[ Symbol ,Float ]").to_s
    assert_equal "[Integer, String]", parse("[Integer , String]").to_s
  end

  def test_empty_tuple_and_optional_container
    assert_equal "[]", parse("[]").to_s
    assert_equal "Array[Integer]?", parse("Array[Integer]?").to_s
  end

  # A union has no single C representation, and spinel's --rbs seeding
  # silently collapses one to whatever the synthesized root call passes --
  # so it is rejected where the user can still be told why.
  def test_union_is_rejected
    assert_raise(Suppify::Error) { parse("Integer | String") }
  end

  def test_unknown_generic_is_rejected
    assert_raise(Suppify::Error) { parse("Set[Integer]") }
    assert_raise(Suppify::Error) { parse("Hash[Integer]") } # wrong arity
  end

  def test_garbage_is_rejected
    assert_raise(Suppify::Error) { parse("Array[Integer") }
    assert_raise(Suppify::Error) { parse("") }
  end

  # The method-type grammar both the sidecar and the inline annotation use.
  def test_method_type_splits_on_top_level_commas_only
    sig = Suppify::RbsType.parse_method_type("(Hash[Symbol, Float], Integer) -> Array[Float]")
    assert_equal ["Hash[Symbol, Float]", "Integer"], sig[:params].map(&:to_s)
    assert_equal "Array[Float]", sig[:ret].to_s
  end

  def test_method_type_with_no_parameters
    sig = Suppify::RbsType.parse_method_type("() -> void")
    assert_equal [], sig[:params]
    assert_equal "void", sig[:ret].to_s
  end

  def test_unparsable_method_type_raises
    assert_raise(Suppify::Error) { Suppify::RbsType.parse_method_type("Integer -> Integer") }
  end
end

class TestNeutralType < Test::Unit::TestCase
  def map(t) = Suppify::NeutralType.map(t)

  def test_sp_int_to_intptr
    assert_equal "intptr_t", map("sp_int")
  end

  def test_double_passthrough
    assert_equal "double", map("double")
  end

  def test_sp_float_to_double
    assert_equal "double", map("sp_float")
  end

  def test_const_char_ptr_passthrough
    assert_equal "const char *", map("const char *")
  end

  def test_bool_to_int
    assert_equal "int", map("bool")
    assert_equal "int", map("_Bool")
    assert_equal "int", map("sp_bool")
  end

  def test_void_passthrough
    assert_equal "void", map("void")
  end

  def test_non_neutral_raises
    assert_raise(Suppify::NonNeutralType) { map("sp_RbVal") }
    assert_raise(Suppify::NonNeutralType) { map("sp_Proc *") }
  end

  # kind classifies a (spinel or neutral) C type into a language-agnostic
  # marshalling category the per-target bindings switch on.
  def test_kind_classifies_scalars
    assert_equal :int,    Suppify::NeutralType.kind("sp_int")
    assert_equal :int,    Suppify::NeutralType.kind("intptr_t")
    assert_equal :float,  Suppify::NeutralType.kind("sp_float")
    assert_equal :float,  Suppify::NeutralType.kind("double")
    assert_equal :string, Suppify::NeutralType.kind("const char *")
    assert_equal :bool,   Suppify::NeutralType.kind("sp_bool")
    assert_equal :bool,   Suppify::NeutralType.kind("bool")
    assert_equal :void,   Suppify::NeutralType.kind("void")
  end

  def test_kind_raises_on_non_neutral
    assert_raise(Suppify::NonNeutralType) { Suppify::NeutralType.kind("sp_RbVal") }
  end
end

class TestSignature < Test::Unit::TestCase
  C = <<~C
    static sp_int sp_add(sp_int a, sp_int b) {
      return a + b;
    }
    static const char *sp_greet(const char *name) {
      return name;
    }
    static void sp_noop(void) { }
  C



  def test_extract_reads_an_ext_init_header_declaration
    h = "void K(void);\nconst char * sp_M_s_f(const char * lv_s, sp_int lv_n);\n"
    sig = Suppify::SignatureExtractor.extract(h, "sp_M_s_f")
    assert_equal "const char *", sig.return_type
    assert_equal [["const char *", "lv_s"], ["sp_int", "lv_n"]], sig.params
  end

  def test_extract_scalar_two_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_add")
    assert_equal "sp_int", sig.return_type
    assert_equal [["sp_int", "a"], ["sp_int", "b"]], sig.params
  end

  def test_extract_pointer_return_and_arg
    sig = Suppify::SignatureExtractor.extract(C, "sp_greet")
    assert_equal "const char *", sig.return_type
    assert_equal [["const char *", "name"]], sig.params
  end

  def test_extract_void_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_noop")
    assert_equal "void", sig.return_type
    assert_equal [], sig.params
  end

  def test_missing_definition_raises
    assert_raise(Suppify::Error) { Suppify::SignatureExtractor.extract(C, "sp_absent") }
  end
end

class TestSource < Test::Unit::TestCase
  def pub(src) = Suppify::Source.new(src).public_methods.sort

  def test_toplevel_defs_are_public
    assert_equal ["add", "greet"], pub("def add(a,b)=a+b\ndef greet(n)=\"hi\#{n}\"\n")
  end

  def test_private_keyword_marks_following_defs
    src = <<~RUBY
      def a; end
      private
      def b; end
    RUBY
    assert_equal ["a"], pub(src)
  end

  def test_private_def_marks_single
    src = <<~RUBY
      def a; end
      private def b; end
      def c; end
    RUBY
    assert_equal ["a", "c"], pub(src)
  end

  def test_private_symbol_marks_named
    src = <<~RUBY
      def a; end
      def b; end
      private :b
    RUBY
    assert_equal ["a"], pub(src)
  end

  # rooted_source appends one synthetic, RBS-typed call per public method in
  # an `if false` block: spinel registers call names syntactically regardless
  # of control flow, so the methods stay reachable-for-typing but the calls
  # never execute (lib_init runs the renamed main once at load time).
  def test_rooted_source_appends_synthetic_calls_for_each_public_method
    src = "def add(a, b) = a + b\ndef boom = raise \"x\"\n"
    rbs = <<~RBS
      class Object
        def add: (Integer, Integer) -> Integer
        def boom: () -> void
      end
    RBS
    out = Suppify::Source.new(src, rbs_source: rbs).rooted_source
    assert_match(/\Adef add.*\n\z/m, out)
    assert_match(/if false\n/, out)
    assert_match(/SuppiExport\.suppi_add\(0, 0\)\n/, out)
    assert_match(/SuppiExport\.suppi_boom\(\)\n/, out)
  end

  # spinel's --ext-entry takes only Module.method, so each public top-level
  # method gets a delegating entry in a per-library wrapper module; the
  # user's own source is left as it is.
  def test_rooted_source_wraps_each_public_method_in_a_per_library_module
    src = "def add(a, b) = a + b\n"
    rbs = "class Object\n  def add: (Integer, Integer) -> Integer\nend\n"
    s = Suppify::Source.new(src, rbs_source: rbs, lib_name: "klib")
    out = s.rooted_source
    assert out.start_with?(src)
    assert_match(/module SuppiExport_klib\n  def self\.suppi_add\(p0, p1\)\n    add\(p0, p1\)\n  end\nend\n/, out)
    assert_equal ["SuppiExport_klib.suppi_add"], s.ext_entries
    assert_equal "module SuppiExport_klib\n  def self.suppi_add: (Integer, Integer) -> Integer\nend\n", s.wrapper_rbs_text
  end

  def test_nothing_is_wrapped_when_nothing_is_public
    s = Suppify::Source.new("private\ndef helper(x) = x\n")
    assert_equal [], s.ext_entries
    assert_nil s.wrapper_rbs_text
  end

  def test_rooted_source_is_unchanged_when_nothing_is_public
    src = "private\ndef helper(x) = x\n"
    assert_equal src, Suppify::Source.new(src).rooted_source
  end

  def test_rooted_source_missing_signature_raises
    src = "def add(a, b) = a + b\n"
    assert_raise(Suppify::Error) { Suppify::Source.new(src, rbs_source: "").rooted_source }
  end

  # Each RBS param type maps to a literal argument in the synthetic call.
  def test_rooted_source_synthesizes_literals_per_rbs_type
    src = "def f(a, b, c) = a\n"
    rbs = <<~RBS
      class Object
        def f: (Float, String, bool) -> void
      end
    RBS
    out = Suppify::Source.new(src, rbs_source: rbs).rooted_source
    assert_match(/f\(0\.0, "", true\)\n/, out)
  end

  # Containers get a literal too: an Array literal is empty on purpose --
  # the element type comes from the --rbs seed, and a narrower literal
  # (e.g. [0] for Array[untyped]) makes spinel reject the call as
  # contradicting that seed.
  def test_rooted_source_synthesizes_container_literals
    src = "def f(a, b, c) = a\n"
    rbs = <<~RBS
      class Object
        def f: (Array[Integer], Hash[Symbol, Float], [Integer, String]) -> void
      end
    RBS
    out = Suppify::Source.new(src, rbs_source: rbs).rooted_source
    assert_match(/f\(\[\], \{ :s => 0\.0 \}, \[0, ""\]\)\n/, out)
  end

  def test_rooted_source_unsupported_rbs_type_raises
    src = "def f(a) = a\n"
    rbs = <<~RBS
      class Object
        def f: (Time) -> void
      end
    RBS
    assert_raise(Suppify::Error) { Suppify::Source.new(src, rbs_source: rbs).rooted_source }
  end
end

# FEATURE: the method type can be written inline above the def, so a
# one-file foo.rb needs no sidecar.
class TestInlineRbs < Test::Unit::TestCase
  def sigs(src, rbs = nil)
    Suppify::Source.new(src, rbs_source: rbs).signatures
      .transform_values { |s| "(#{s[:params].join(', ')}) -> #{s[:ret]}" }
  end

  def test_method_type_comment_above_a_def
    src = <<~RUBY
      #: (Array[Integer], Integer) -> Integer
      def scale(xs, k) = 0
    RUBY
    assert_equal({ "scale" => "(Array[Integer], Integer) -> Integer" }, sigs(src))
  end

  def test_rbs_tag_form_uses_the_parameter_names
    src = <<~RUBY
      # @rbs a: Integer
      # @rbs b: Float
      # @rbs return: Float
      def mix(a, b) = 0.0
    RUBY
    assert_equal({ "mix" => "(Integer, Float) -> Float" }, sigs(src))
  end

  # The annotation may sit anywhere in the contiguous comment block above
  # the def, prose included -- that block is what rbs-inline reads too.
  def test_annotation_among_ordinary_comments
    src = <<~RUBY
      # Doubles every element.
      #: (Array[Float]) -> Array[Float]
      # (still the same comment block)
      def dbl(xs) = xs
    RUBY
    assert_equal({ "dbl" => "(Array[Float]) -> Array[Float]" }, sigs(src))
  end

  # A blank line ends the block: that comment belongs to nothing.
  def test_comment_separated_by_a_blank_line_is_not_an_annotation
    src = "#: (Integer) -> Integer\n\ndef f(a) = a\n"
    assert_equal({}, sigs(src))
  end

  def test_private_def_annotation_is_read_from_above_the_whole_statement
    src = <<~RUBY
      #: (Integer) -> Integer
      private def hidden(a) = a
    RUBY
    assert_equal({ "hidden" => "(Integer) -> Integer" }, sigs(src))
  end

  def test_inline_and_sidecar_signatures_merge
    src = "#: (Integer) -> Integer\ndef a(x) = x\ndef b(x) = x\n"
    rbs = "class Object\n  def b: (String) -> String\nend\n"
    assert_equal({ "b" => "(String) -> String", "a" => "(Integer) -> Integer" }, sigs(src, rbs))
  end

  # Declaring the same method twice is an error, never a silent precedence.
  def test_declaring_a_method_both_inline_and_in_the_sidecar_raises
    src = "#: (Integer) -> Integer\ndef a(x) = x\n"
    rbs = "class Object\n  def a: (String) -> String\nend\n"
    e = assert_raise(Suppify::Error) { sigs(src, rbs) }
    assert_match(/\ba\b/, e.message)
  end

  def test_mixing_the_two_inline_forms_on_one_def_raises
    src = <<~RUBY
      #: (Integer) -> Integer
      # @rbs a: Integer
      def f(a) = a
    RUBY
    assert_raise(Suppify::Error) { sigs(src) }
  end

  def test_two_method_type_comments_on_one_def_raises
    src = "#: (Integer) -> Integer\n#: (Float) -> Float\ndef f(a) = a\n"
    assert_raise(Suppify::Error) { sigs(src) }
  end

  def test_rbs_tags_missing_a_parameter_raises
    src = "# @rbs a: Integer\n# @rbs return: Integer\ndef f(a, b) = a\n"
    e = assert_raise(Suppify::Error) { sigs(src) }
    assert_match(/\bb\b/, e.message)
  end

  def test_rbs_tags_missing_the_return_raises
    src = "# @rbs a: Integer\ndef f(a) = a\n"
    assert_raise(Suppify::Error) { sigs(src) }
  end

  def test_missing_signature_names_the_method_and_both_ways_to_declare_it
    src = "#: (Integer) -> Integer\ndef a(x) = x\ndef b(x) = x\n"
    e = assert_raise(Suppify::Error) { Suppify::Source.new(src).rooted_source }
    assert_match(/\bb\b/, e.message)
    assert_match(/inline/, e.message)
    assert_match(/sidecar/, e.message)
  end

  # Inline annotations have no file for spinel's --rbs seeding, so suppify
  # renders one. A source with none (sidecar only) gets nil -- its sidecar
  # keeps being the seed, untouched.
  def test_inline_rbs_text_renders_only_the_inline_declarations
    src = "#: (Integer) -> Integer\ndef a(x) = x\ndef b(x) = x\n"
    rbs = "class Object\n  def b: (String) -> String\nend\n"
    text = Suppify::Source.new(src, rbs_source: rbs).inline_rbs_text
    assert_equal "class Object\n  def a: (Integer) -> Integer\nend\n", text
  end

  def test_inline_rbs_text_is_nil_without_inline_annotations
    src = "def b(x) = x\n"
    rbs = "class Object\n  def b: (String) -> String\nend\n"
    assert_nil Suppify::Source.new(src, rbs_source: rbs).inline_rbs_text
  end
end

# The spinel type inventory the flat entry is generated against: which C
# type spinel gives each RBS type. Every row here was read off spinel's own
# generated C (see README, "What crosses the boundary").
class TestFlatCallTypes < Test::Unit::TestCase
  def c_type(t) = Suppify::FlatCall.c_type(Suppify::RbsType.parse(t))

  def test_scalars
    assert_equal "sp_int", c_type("Integer")
    assert_equal "sp_float", c_type("Float")
    assert_equal "const char *", c_type("String")
    assert_equal "sp_sym", c_type("Symbol")
    assert_equal "sp_bool", c_type("bool")
    assert_equal "sp_RbVal", c_type("untyped")
  end

  def test_typed_arrays
    assert_equal "sp_IntArray *", c_type("Array[Integer]")
    assert_equal "sp_FloatArray *", c_type("Array[Float]")
    assert_equal "sp_StrArray *", c_type("Array[String]")
  end

  # Anything spinel has no typed array for is a poly array of boxed values.
  def test_poly_arrays_and_tuples
    assert_equal "sp_PolyArray *", c_type("Array[Symbol]")
    assert_equal "sp_PolyArray *", c_type("Array[Array[Integer]]")
    assert_equal "sp_PolyArray *", c_type("Array[Hash[Integer, Integer]]")
    assert_equal "sp_PolyArray *", c_type("[Integer, String]")
  end

  def test_hashes
    assert_equal "sp_IntIntHash *", c_type("Hash[Integer, Integer]")
    assert_equal "sp_IntStrHash *", c_type("Hash[Integer, String]")
    assert_equal "sp_StrIntHash *", c_type("Hash[String, Integer]")
    assert_equal "sp_StrStrHash *", c_type("Hash[String, String]")
    assert_equal "sp_StrPolyHash *", c_type("Hash[String, Float]")
    assert_equal "sp_SymPolyHash *", c_type("Hash[Symbol, Integer]")
    assert_equal "sp_SymPolyHash *", c_type("Hash[Symbol, Array[Float]]")
    assert_equal "sp_PolyPolyHash *", c_type("Hash[Integer, Float]")
    assert_equal "sp_PolyPolyHash *", c_type("Hash[Float, Integer]")
  end

  # int?/float?/String?/container? carry nil in-band (SP_INT_NIL, a reserved
  # NaN, NULL); Symbol? and bool? have no spare inhabitant, so spinel boxes
  # them.
  def test_optionals
    assert_equal "sp_int", c_type("Integer?")
    assert_equal "sp_float", c_type("Float?")
    assert_equal "const char *", c_type("String?")
    assert_equal "sp_IntArray *", c_type("Array[Integer]?")
    assert_equal "sp_RbVal", c_type("Symbol?")
    assert_equal "sp_RbVal", c_type("bool?")
  end

  def test_a_type_spinel_cannot_hold_is_rejected_by_name
    e = assert_raise(Suppify::Error) { c_type("Time") }
    assert_match(/Time/, e.message)
    assert_raise(Suppify::Error) { c_type("Array[Time]") }
    assert_raise(Suppify::Error) { c_type("Hash[Symbol, Time]") }
  end

  def test_boxing_expressions
    box = ->(t, v) { Suppify::FlatCall.box_expr(Suppify::RbsType.parse(t), v) }
    assert_equal "sp_box_int(x)", box.call("Integer", "x")
    assert_equal "sp_box_float(x)", box.call("Float", "x")
    assert_equal "sp_box_str(x)", box.call("String", "x")
    assert_equal "x", box.call("untyped", "x")
    assert_equal "sp_box_nullable_obj((void *)(x), SP_BUILTIN_INT_ARRAY)", box.call("Array[Integer]", "x")
    # an optional scalar's in-band nil must not be boxed as a plain number
    assert_equal "sp_box_int_or_nil(x)", box.call("Integer?", "x")
    assert_equal "sp_box_float_or_nil(x)", box.call("Float?", "x")
  end
end

class TestSpinelRunner < Test::Unit::TestCase
  # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
  # emit modes (src/main.c: emit_symbol_map short-circuits before the
  # c_only branch, so a combined invocation silently drops the C output).
  # SpinelRunner must therefore issue two separate invocations.
  def test_builds_two_commands_and_returns_paths
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "/opt/spinel", runner: fake)
    out = r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["/opt/spinel", "/work/app.rb", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["/opt/spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
    assert_equal "/tmp/app.c", out[:c_path]
    assert_equal "/tmp/app.symbols.json", out[:symbols_path]
  end

  # --ext-init makes the -c invocation emit a main-less library TU and its
  # header; the symbol-map invocation is unchanged.
  def test_ext_init_adds_the_library_flags_to_the_c_step_only
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake, rbs_dir: "/work/sigs",
                                  ext_init: "k_spinel", ext_entries: %w[M.a M.b])
    out = r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["spinel", "/work/app.rb", "--rbs", "/work/sigs", "--ext-init", "k_spinel",
                  "--ext-entry", "M.a,M.b", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
    assert_equal "/tmp/app.h", out[:header_path]
  end

  def test_kernel_init_name_is_derived_from_the_library_name
    assert_equal "klib_spinel", Suppify.kernel_init_name("klib")
  end

  def test_nonzero_status_raises_on_c_step
    fake = ->(_argv) { ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_nonzero_status_raises_on_symbol_map_step
    calls = 0
    fake = ->(_argv) { calls += 1; calls == 1 ? ["", 0] : ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_includes_rbs_flag_on_c_step_only_when_given
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake, rbs_dir: "/work/sigs")
    r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["spinel", "/work/app.rb", "--rbs", "/work/sigs", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
  end
end

class TestPipeline < Test::Unit::TestCase
  RUBY = <<~RUBY
    def add(a, b) = a + b
    def boom = nil
    def greet(name) = name
    def cat(a, b) = a
    private
    def helper(x) = x
  RUBY

  C = <<~C
    static sp_int sp_add(sp_int a, sp_int b) { return a + b; }
    static void sp_boom(void) { }
    static const char *sp_greet(const char *name) { return name; }
    static const char *sp_cat(const char *a, const char *b) { return a; }
    static sp_int sp_helper(sp_int x) { return x; }
  C

  SYMS = '{"symbols":[{"c":"sp_add","ruby":"SuppiExport_addlib.suppi_add","kind":"toplevel"},' \
         '{"c":"sp_boom","ruby":"SuppiExport_addlib.suppi_boom","kind":"toplevel"},' \
         '{"c":"sp_greet","ruby":"SuppiExport_addlib.suppi_greet","kind":"toplevel"},' \
         '{"c":"sp_cat","ruby":"SuppiExport_addlib.suppi_cat","kind":"toplevel"},' \
         '{"c":"sp_helper","ruby":"SuppiExport_addlib.suppi_helper","kind":"toplevel"}]}'

  def setup
    @r = Suppify::Pipeline.new(ruby_source: RUBY, c_source: C, header_text: C,
                               symbols_json: SYMS, lib_name: "addlib").run
    @c = @r[:c_source]
    @h = @r[:header]
  end

  def test_exports_only_public_methods
    names = @r[:exports].map { |e| e["public"] }
    assert_equal ["add", "boom", "greet", "cat"], names
  end

  # A public method the symbol map lacks (spinel didn't emit it, e.g. DCE'd
  # despite rooting) is skipped rather than crashing the pipeline.
  def test_public_method_missing_from_symbol_map_is_skipped
    syms = '{"symbols":[{"c":"sp_add","ruby":"SuppiExport_x.suppi_add","kind":"toplevel"}]}'
    r = Suppify::Pipeline.new(ruby_source: "def add(a,b)=a+b\ndef gone(x)=x\n",
                              c_source: C, header_text: C, symbols_json: syms, lib_name: "x").run
    assert_equal ["add"], r[:exports].map { |e| e["public"] }
  end

  def test_private_method_not_exported_but_still_static_in_c
    assert_no_match(/intptr_t helper\(/, @c)   # not a public trampoline
    assert_match(/static sp_int sp_helper/, @c) # still present + hidden
  end

  def test_public_method_with_non_neutral_signature_raises
    bad_c = "static sp_RbVal sp_add(sp_RbVal a) { return a; }\n"
    bad_syms = '{"symbols":[{"c":"sp_add","ruby":"SuppiExport_x.suppi_add","kind":"toplevel"}]}'
    assert_raise(Suppify::NonNeutralType) do
      Suppify::Pipeline.new(ruby_source: "def add(a)=a", c_source: bad_c, header_text: bad_c,
                            symbols_json: bad_syms, lib_name: "x").run
    end
  end

  # ---- the kernel TU is spinel's --ext-init output: it has no main, so the
  # library takes it as is and <lib>_init drives spinel's own init function.

  def test_kernel_c_is_taken_unchanged
    assert @c.start_with?(C)
    assert_no_match(/sp__main/, @c)
  end

  def test_lib_init_is_idempotent_and_calls_the_ext_init_function
    init = @c[/void addlib_init\(void\) \{.*?\n\}/m]
    assert_not_nil init
    assert_match(/static int done = 0; if \(done\) return; done = 1;/, init)
    assert_match(/addlib_spinel\(\);/, init)
  end

  # ---- trampolines:
  # the extern, neutral-typed entry points appended to the
  # generated TU, each run inside spinel's <kernel>_try exception frame.

  def test_emits_extern_trampoline_calling_static
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\)/, @c)
    assert_match(/c->r = sp_add\(c->a, c->b\);/, @c)
    assert_match(/return c\.r;/, @c)
  end

  def test_void_trampoline_has_no_return_value
    assert_match(/void boom\(void\)/, @c)
    assert_match(/^    sp_boom\(\);/, @c)
  end

  # Each trampoline must clear the error flag on entry so <lib>_error()
  # reflects the LAST call, not any earlier one. Without this a language
  # binding that checks <lib>_error() after every call would keep raising
  # forever once any single call raised.
  def test_resets_error_flag_on_entry
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\) \{\n.*\n\s*g_suppi_err = 0;/, @c)
    assert_match(/void boom\(void\) \{\n.*\n\s*g_suppi_err = 0;/, @c)
  end

  # <lib>_error/<lib>_error_message/<lib>_init are per-library names (not
  # generic ones): spinel's runtime is a set of process-wide globals shared
  # by everything linked against it, so two suppify libraries in the same
  # binary would otherwise define identical symbols and fail to link. See
  # SymbolPrefix for the analogous fix applied to the vendored runtime.
  def test_includes_exception_barrier_and_error_api
    assert_match(/addlib_spinel_try\(suppi_sc_thunk_add, &c, &cls, &msg\)/, @c)
    assert_no_match(/setjmp|sp_exc_arm/, @c)
    assert_match(/int addlib_error\(void\)/, @c)
    assert_match(/const char \*addlib_error_message\(void\)/, @c)
  end


  # On a caught exception the message spinel's <kernel>_try hands back is
  # copied into this library's own buffer, so <lib>_error_message() stays
  # valid after the next call.
  # The class name is copied into its own buffer beside the message, and the
  # accessor sits next to <lib>_error_message() in the C and the header.
  def test_captures_exception_class_name
    assert_match(/static char g_suppi_clsbuf\[/, @c)
    assert_match(/static void suppi__capture\(const char \*c, const char \*m\)/, @c)
    assert_match(/const char \*addlib_error_class\(void\) \{ return g_suppi_err \? g_suppi_cls : ""; \}/, @c)
    assert_match(/suppi__capture\(cls, msg\); return 0; \}/, @c)
    assert_match(/const char \*addlib_error_class\(void\);/, @h)
  end

  def test_captures_exception_message
    assert_match(/static char g_suppi_msgbuf\[/, @c)
    assert_match(/static void suppi__capture\(const char \*c, const char \*m\)/, @c)
    assert_match(/strncpy\(g_suppi_msgbuf, m,/, @c)
    assert_match(/g_suppi_msg = g_suppi_msgbuf;/, @c)
    assert_match(/suppi__capture\(cls, msg\); return 0; \}/, @c)
  end

  # spinel's strings carry a header (sp_str_hdr) and a marker byte at
  # ptr[-1]; a raw host-language string buffer has neither, so passing it
  # straight into a spinel-generated function is an out-of-bounds read.
  # sp_str_dup_external mirrors what spinel itself does for argv/getenv.
  def test_wraps_string_arguments_in_sp_str_dup_external
    assert_match(/const char \*sp_dup_name = sp_str_dup_external\(c->name\);/, @c)
    assert_match(/c->r = sp_greet\(sp_dup_name\);/, @c)
    # non-string args must be passed through unwrapped
    assert_match(/c->r = sp_add\(c->a, c->b\);/, @c)
  end

  # A duped string is only a bare C temporary until it's passed to the
  # spinel-generated callee -- nothing marks it as GC-reachable. With two
  # string arguments, the SECOND sp_str_dup_external's internal allocation
  # can trigger a collection that sweeps the FIRST (still-unrooted) duped
  # string before the call happens. SP_GC_ROOT (the same discipline spinel's
  # own codegen uses for its local variables) keeps each duped string alive
  # from the moment it's created.
  def test_roots_each_duped_string_before_the_next_dup
    assert_match(/const char \*sp_dup_a = sp_str_dup_external\(c->a\); SP_GC_ROOT\(sp_dup_a\);/, @c)
    assert_match(/const char \*sp_dup_b = sp_str_dup_external\(c->b\); SP_GC_ROOT\(sp_dup_b\);/, @c)
    assert_match(/c->r = sp_cat\(sp_dup_a, sp_dup_b\);/, @c)
  end

  # SP_GC_ROOT's cleanup-attribute pop never runs across a longjmp, so a
  # raise while a duped string is rooted must not leave sp_gc_nroots
  # incremented. That restore is done by spinel's <kernel>_try frame (the
  # thunk with the dup runs inside it), not by suppify.
  def test_string_dups_run_inside_the_try_frame
    thunk = @c[/static void suppi_sc_thunk_greet\(void \*p\) \{.*?\n\}/m]
    assert_match(/sp_str_dup_external/, thunk)
    assert_match(/addlib_spinel_try\(suppi_sc_thunk_greet,/, @c)
    assert_no_match(/sp_gc_nroots/, @c)
  end

  # rb_str_new_cstr/mrb_str_new_cstr are strlen-based, so a String return
  # containing an embedded NUL gets silently truncated. sp_str_byte_len
  # recovers spinel's own tracked byte length (from the string header, not
  # strlen); this bridges it through the neutral boundary so a binding can
  # build a correctly-sized Ruby string instead of guessing via strlen.
  #
  # sp_str_byte_len itself only recognizes the 0xfe/0xfc/0xfd marker bytes,
  # not 0xf1 (a heap string frozen via .freeze -- see spinel's own
  # sp_str_freeze_val), silently falling back to strlen for a frozen
  # string and reintroducing the exact truncation this bridge exists to
  # avoid (confirmed by an adversarial review: `# frozen_string_literal:
  # true` reproduces it). sp_str_freeze_val only flips the marker byte in
  # place on an already sp_str_alloc'd buffer, so the header behind a
  # 0xf1-marked string is still valid; read it directly for this one
  # marker spinel's own helper misses.
  def test_str_len_bridge_handles_frozen_strings_too
    assert_match(/size_t addlib_str_len\(const char \*s\) \{/, @c)
    assert_match(/if \(!s\) return 0;/, @c)
    assert_match(/if \(\(\(const unsigned char \*\)s\)\[-1\] == 0xf1\) \{/, @c)
    assert_match(/return \(\(\(const sp_str_hdr \*\)\(s - 1\)\) - 1\)->len;/, @c)
    assert_match(/return sp_str_byte_len\(s\);/, @c)
  end

  # ---- the neutral header consumers include.

  def test_header_include_guard
    assert_match(/#ifndef ADDLIB_H/, @h)
    assert_match(/#define ADDLIB_H/, @h)
    assert_match(/#endif/, @h)
  end

  def test_header_includes_stdint_for_intptr
    assert_match(/#include <stdint.h>/, @h)
  end

  def test_header_includes_stddef_for_size_t
    assert_match(/#include <stddef.h>/, @h)
  end

  def test_header_prototypes_are_neutral_no_spinel_types
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @h)
    assert_no_match(/sp_int/, @h)
  end

  # Per-library names (not generic ones) so two suppify libraries linked into
  # the same binary don't collide on the lifecycle/error API.
  def test_header_lifecycle_and_error_api
    assert_match(/void addlib_init\(void\);/, @h)
    assert_match(/int addlib_error\(void\);/, @h)
    assert_match(/const char \*addlib_error_message\(void\);/, @h)
  end

  # Lets a consumer recover a String return's true byte length instead of
  # guessing via strlen, which truncates at an embedded NUL.
  def test_header_declares_str_len_bridge
    assert_match(/size_t addlib_str_len\(const char \*s\);/, @h)
  end
end

# The flat-message entry: one MessagePack message in, one out, generated
# from the RBS type tree. Exercised end to end (compiled, called, compared
# against CRuby) by test_flat_call_integration.rb; this checks what the
# Pipeline emits.
class TestPipelineFlatEntries < Test::Unit::TestCase
  RUBY = <<~RUBY
    def scale(xs, k) = 0
    def add(a, b) = a + b
  RUBY

  C = <<~C
    static sp_int sp_scale(sp_IntArray * lv_xs, sp_int lv_k) { return 0; }
    static inline sp_int sp_add(sp_int a, sp_int b) { return a + b; }
  C

  SYMS = '{"symbols":[{"c":"sp_scale","ruby":"SuppiExport_klib.suppi_scale"},{"c":"sp_add","ruby":"SuppiExport_klib.suppi_add"}]}'

  def sigs(scale: "(Array[Integer], Integer) -> Integer", add: "(Integer, Integer) -> Integer")
    { "scale" => Suppify::RbsType.parse_method_type(scale),
      "add" => Suppify::RbsType.parse_method_type(add) }
  end

  def run_pipeline(rbs_signatures)
    Suppify::Pipeline.new(ruby_source: RUBY, c_source: C, header_text: C, symbols_json: SYMS,
                          lib_name: "klib", rbs_signatures: rbs_signatures).run
  end

  def setup
    @r = run_pipeline(sigs)
    @c = @r[:c_source]
    @h = @r[:header]
  end

  def test_every_export_gets_a_call_and_a_signature_entry
    assert_match(/int32_t klib_scale_call\(const uint8_t \*in, int32_t in_len, uint8_t \*out, int32_t out_cap\)/, @c)
    assert_match(/int32_t klib_add_call\(/, @c)
    assert_match(/const char \*klib_scale_signature\(void\) \{ return "\(Array\[Integer\], Integer\) -> Integer"; \}/, @c)
  end

  def test_header_declares_the_entries_and_the_status_codes
    assert_match(/int32_t klib_scale_call\(const uint8_t \*in, int32_t in_len, uint8_t \*out, int32_t out_cap\);/, @h)
    assert_match(/const char \*klib_add_signature\(void\);/, @h)
    assert_match(/#define KLIB_E_MALFORMED \(-1\)/, @h)
    assert_match(/#define KLIB_E_NOSPACE   \(-2\)/, @h)
    assert_match(/#define KLIB_E_RAISED    \(-3\)/, @h)
    assert_match(/#define KLIB_E_RANGE     \(-4\)/, @h)
  end

  # A scalar-only signature keeps its plain C entry and its VM binding
  # unchanged; the flat entry is added beside it, not instead of it.
  def test_scalar_export_keeps_its_scalar_entry
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\)/, @c)
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @h)
  end

  # A collection signature has no neutral scalar C entry (sp_IntArray * is
  # not a neutral type), so only the flat entry is emitted for it.
  def test_collection_export_has_no_scalar_entry
    assert_no_match(/^intptr_t scale\(/, @c)
    assert_no_match(/intptr_t scale\(/, @h)
    assert_equal({ "scale" => false, "add" => true },
                 @r[:exports].to_h { |e| [e["public"], e["neutral"]] })
    assert_equal({ "scale" => true, "add" => true },
                 @r[:exports].to_h { |e| [e["public"], e["flat"]] })
  end

  # The decoder is generated per RBS type node, so the container's element
  # type decides how each element is read.
  def test_generates_a_decoder_per_type_node
    assert_match(/static int suppi_dec_\d+\(suppi_rd \*r, sp_IntArray \*\*out\)/, @c)
    assert_match(/sp_IntArray_new\(\); SP_GC_ROOT\(a\);/, @c)
    assert_match(/sp_IntArray_push\(a, e\);/, @c)
    assert_match(/static int suppi_dec_\d+\(suppi_rd \*r, sp_int \*out\)/, @c)
  end

  # Decoding allocates in the kernel's heap, so the exception barrier and
  # the GC root-count restore of the scalar trampolines apply here too.
  def test_call_entry_runs_its_body_inside_the_try_frame
    assert_match(/c->rc = suppi_body_scale\(&r, &w\);/, @c)
    assert_match(/if \(klib_spinel_try\(suppi_thunk_scale, &c, &cls, &msg\)\) \{ suppi__capture\(cls, msg\); return SUPPI_ERAISE; \}/, @c)
    assert_no_match(/setjmp|sp_exc_arm|sp_exc_disarm/, @c)
  end

  # The return value is boxed and written by the generic encoder, so what
  # goes on the wire is what the kernel actually returned.
  def test_return_value_is_encoded_generically
    assert_match(/if \(\(st = suppi_enc_poly\(w, sp_box_int\(rv\)\)\) < 0\)/, @c)
    assert_match(/static int suppi_enc_poly\(suppi_wr \*w, sp_RbVal v\)/, @c)
  end

  def test_integers_are_range_checked_against_this_targets_sp_int
    assert_match(/if \(v < \(int64_t\)INTPTR_MIN \|\| v > \(int64_t\)INTPTR_MAX\) return SUPPI_ERANGE;/, @c)
  end

  # A float is written as MessagePack float64 (0xcb) -- never narrowed to
  # float32, so NaN/Infinity/-0.0 survive bit for bit.
  def test_floats_are_written_as_binary64
    assert_match(/suppi_wr_u8\(w, 0xcb\); suppi_wr_be\(w, c\.u, 8\);/, @c)
  end

  # A scalar method with no RBS method type keeps exactly the old
  # behaviour: a scalar entry and no flat entry.
  def test_without_rbs_signatures_nothing_flat_is_emitted
    r = Suppify::Pipeline.new(ruby_source: "def add(a, b) = a + b\n", c_source: C, header_text: C,
                              symbols_json: '{"symbols":[{"c":"sp_add","ruby":"SuppiExport_klib.suppi_add"}]}',
                              lib_name: "klib").run
    assert_no_match(/_call\(const uint8_t/, r[:c_source])
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\)/, r[:c_source])
    assert_equal [nil], r[:exports].map { |e| e["flat"] }
  end

  # A method spinel gave a non-neutral C signature and whose RBS method
  # type suppify does not have can be marshalled neither way -- that is an
  # error naming the signature, not a silently dropped export.
  def test_non_neutral_export_without_an_rbs_method_type_raises
    assert_raise(Suppify::NonNeutralType) { run_pipeline("add" => sigs["add"]) }
  end

  # suppify predicts the C type of every parameter and generates a decoder
  # for it; if spinel emitted a different one the prediction is wrong and
  # marshalling it would be a type pun.
  def test_parameter_type_disagreement_with_spinel_raises
    e = assert_raise(Suppify::Error) { run_pipeline(sigs(scale: "(Array[Float], Integer) -> Integer")) }
    assert_match(/sp_FloatArray/, e.message)
    assert_match(/sp_IntArray/, e.message)
  end

  def test_parameter_count_disagreement_with_spinel_raises
    assert_raise(Suppify::Error) { run_pipeline(sigs(scale: "(Array[Integer]) -> Integer")) }
  end

  # A return type is NOT checked against spinel's: spinel infers it from the
  # method body (`h.values` on a Hash[Symbol, Float] is an sp_PolyArray, not
  # an sp_FloatArray), and the encoder boxes whatever came back.
  def test_return_type_disagreement_with_spinel_is_accepted
    r = run_pipeline(sigs(scale: "(Array[Integer], Integer) -> Array[Float]"))
    assert_match(/suppi_enc_poly\(w, sp_box_int\(rv\)\)/, r[:c_source])
  end
end
