# lib/suppify/core.rb — the コア layer: everything from the user's Ruby +
# its RBS (inline `#:` annotations and/or a .rbs sidecar) to a neutral C
# library surface (exports, library C source, neutral header). One class per
# pipeline stage, in pipeline order:
#
#   RbsType      — the parsed RBS type tree both boundaries are driven by
#   Source       — analyze the user's Ruby/RBS; synthesize the rooted source
#   SpinelRunner — run the external spinel compiler on the rooted source
#   FlatCall     — the MessagePack flat-message entry generator
#   Pipeline     — transform spinel's C + symbol map into the neutral library
#
# plus the shared type vocabulary (NeutralType) and C-signature extraction
# (Signature / SignatureExtractor) both this layer and the bindings use.
require "json"
require "open3"
require "prism"
require "strscan"

module Suppify
  # Maps spinel C types to neutral C types usable across a plain-C boundary.
  # Anything not in the table is non-neutral and raises.
  module NeutralType
    TABLE = {
      "sp_int"        => "intptr_t",
      "double"        => "double",
      "sp_float"      => "double",
      "const char *"  => "const char *",
      "bool"          => "int",
      "_Bool"         => "int",
      "sp_bool"       => "int",
      "void"          => "void",
    }.freeze

    module_function

    def map(c_type)
      key = c_type.strip.gsub(/\s+/, " ")
      TABLE[key] or raise NonNeutralType, "non-neutral C type: #{c_type.inspect}"
    end

    # Classifies a C type into a marshalling category the language bindings
    # switch on. Raises (via map) on non-neutral types.
    KIND = {
      "intptr_t"     => :int,
      "double"       => :float,
      "const char *" => :string,
      "int"          => :bool,
      "void"         => :void,
    }.freeze

    def kind(c_type)
      key = c_type.strip.gsub(/\s+/, " ")
      neutral = TABLE[key] || key # spinel type -> neutral, or already neutral
      KIND.fetch(neutral) { raise NonNeutralType, "non-neutral C type: #{c_type.inspect}" }
    end
  end

  # A parsed RBS type, as a tree. Every boundary suppify generates -- the
  # synthetic root call, the C type it expects spinel to emit, the
  # MessagePack decoder -- is driven by this tree rather than by a
  # hard-coded list of supported type names.
  #
  #   :simple   a bare name (Integer, Float, String, Symbol, bool, untyped, ...)
  #   :array    Array[T]           args = [T]
  #   :hash     Hash[K, V]         args = [K, V]
  #   :tuple    [T1, T2, ...]      args = [T1, T2, ...]
  #   :optional T?                 args = [T]
  class RbsType
    attr_reader :kind, :name, :args

    def initialize(kind, name: nil, args: [])
      @kind = kind
      @name = name
      @args = args
    end

    def to_s
      case @kind
      when :simple   then @name
      when :array    then "Array[#{@args[0]}]"
      when :hash     then "Hash[#{@args[0]}, #{@args[1]}]"
      when :tuple    then "[#{@args.join(', ')}]"
      when :optional then "#{@args[0]}?"
      end
    end

    def simple?(*names) = @kind == :simple && names.include?(@name)

    # Every node of the tree, parents before children.
    def each_node(&block)
      block.call(self)
      @args.each { |a| a.each_node(&block) }
      self
    end

    def self.parse(text)
      s = StringScanner.new(text.to_s.strip)
      t = parse_type(s)
      s.skip(/\s*/)
      raise Error, "unparsable RBS type: #{text.inspect}" unless s.eos?
      t
    end

    # A union has no single C representation at the boundary, and spinel's
    # --rbs seeding collapses one to whatever the call site passes rather
    # than rejecting it -- so suppify rejects it here, where the user can
    # still be told why.
    def self.parse_type(s)
      base = parse_base(s)
      s.skip(/\s*/)
      base = new(:optional, args: [base]) if s.scan(/\?/)
      s.skip(/\s*/)
      if s.check(/\|/)
        raise Error, "RBS union types are not supported at the suppify boundary " \
                     "(a union has no single C representation; spinel's --rbs seeding " \
                     "silently collapses one to the type of the synthesized root call)"
      end
      base
    end

    def self.parse_base(s)
      s.skip(/\s*/)
      if s.scan(/\[/) # tuple
        elems = []
        s.skip(/\s*/)
        unless s.scan(/\]/)
          loop do
            elems << parse_type(s)
            s.skip(/\s*/)
            break unless s.scan(/,/)
          end
          s.scan(/\s*\]/) or raise Error, "unterminated tuple type in RBS"
        end
        return new(:tuple, args: elems)
      end

      name = s.scan(/[A-Za-z_][A-Za-z0-9_:]*/)
      raise Error, "unparsable RBS type at #{s.rest.inspect}" unless name

      unless s.check(/\s*\[/)
        return new(:simple, name: name)
      end
      s.skip(/\s*\[/)
      args = []
      loop do
        args << parse_type(s)
        s.skip(/\s*/)
        break unless s.scan(/,/)
      end
      s.scan(/\s*\]/) or raise Error, "unterminated generic type #{name} in RBS"

      case [name, args.length]
      when ["Array", 1] then new(:array, args: args)
      when ["Hash", 2]  then new(:hash, args: args)
      else
        raise Error, "generic RBS type #{name}[...] with #{args.length} argument(s) is not " \
                     "supported at the suppify boundary (only Array[T], Hash[K, V] and tuples " \
                     "have a spinel container type)"
      end
    end

    # "(A, B) -> R" -> { params: [RbsType, ...], ret: RbsType }. The one
    # method-type grammar both the sidecar .rbs and the inline `#:`
    # annotation are read through.
    def self.parse_method_type(text)
      m = /\A\s*\(([^)]*)\)\s*->\s*(.+?)\s*\z/m.match(text.to_s)
      raise Error, "unparsable RBS method type: #{text.inspect}" unless m
      { params: split_top_level(m[1]).map { |t| parse(t) }, ret: parse(m[2]) }
    end

    # Splits "Integer, Hash[Symbol, Float]" on its top-level commas only --
    # a plain String#split would cut Hash[K, V] and tuples in half.
    def self.split_top_level(text)
      parts = []
      depth = 0
      current = +""
      text.each_char do |ch|
        case ch
        when "[" then depth += 1; current << ch
        when "]" then depth -= 1; current << ch
        when ","
          if depth.zero?
            parts << current
            current = +""
          else
            current << ch
          end
        else current << ch
        end
      end
      parts << current
      parts.map(&:strip).reject(&:empty?)
    end
  end

  Signature = Struct.new(:return_type, :params) # params: [[c_type, name], ...]

  # Extracts a function's C signature by its cname from spinel's --ext-init
  # header, where every entry is declared `<ret> <cname>(<params>);` (a
  # definition line `... {` in generated C is accepted too).
  module SignatureExtractor
    module_function

    def extract(c_source, cname)
      # Match the definition line: capture return type (everything before the
      # cname) and the parenthesized parameter list.
      re = /(?<ret>[A-Za-z_][\w \*]*?)\s*\b#{Regexp.escape(cname)}\s*\((?<params>[^)]*)\)\s*[{;]/
      m = c_source.match(re)
      raise Error, "definition not found for #{cname}" unless m
      # Drop the storage/inline specifiers spinel puts in front of the type
      # (`static`, `static inline`, ... -- which of them a given function
      # gets is spinel's own codegen decision, so all are stripped).
      ret = m[:ret].strip
      ret = ret.sub(/\A(?:static|inline|extern)\s+/, "") while ret =~ /\A(?:static|inline|extern)\s+/
      Signature.new(ret.strip, parse_params(m[:params]))
    end

    def parse_params(text)
      text = text.strip
      return [] if text.empty? || text == "void"
      text.split(",").map do |p|
        p = p.strip
        # split trailing identifier (the param name) from its type
        md = p.match(/\A(?<type>.*?)(?<name>[A-Za-z_]\w*)\z/)
        type = md[:type].strip
        # re-attach pointer star to type if the name grabbed it (e.g. "char *x")
        [type, md[:name]]
      end
    end
  end

  # The user's input, analyzed: which top-level methods are public (via
  # prism's static AST), what the RBS sidecar declares for them, and the
  # "rooted" source spinel actually compiles.
  #
  # Rooting exists because spinel's whole-program reachability analysis DCEs
  # any top-level method with no call site, regardless of visibility --
  # fatal for suppify's premise (public methods are exported precisely
  # because nothing in the program calls them). #rooted_source appends a
  # wrapper module (see Source.wrapper_module) whose --ext-entry exports delegate
  # to each public method, which roots it and gives spinel its signature.
  #
  # The RBS subset parsed here is what suppify needs to type spinel's
  # top-level exports: `class Object ... def name: (T1, T2) -> R ... end`
  # (the same `class Object` convention spinel's own `--rbs` extractor uses
  # to target Ruby's top-level methods, which are Object instance methods
  # under the hood).
  #
  # The same method type can instead be written inline, rbs-inline style, in
  # the comment block immediately above the `def` -- either as a `#:` method
  # type or as per-parameter `# @rbs` lines -- so a one-file `foo.rb` needs
  # no sidecar at all. A method declared in both places is an error, never a
  # silent precedence.
  class Source
    LITERALS = {
      "Integer" => "0",
      "Float" => "0.0",
      "String" => '""',
      "Symbol" => ":s",
      "bool" => "true",
      "TrueClass" => "true",
      "FalseClass" => "true",
      "NilClass" => "nil",
      "nil" => "nil",
      "untyped" => "0",
    }.freeze

    DEF_RE = /\A\s*def\s+([A-Za-z_]\w*[?!]?)\s*:\s*(\(.*)\s*\z/

    # `#: (Integer, Integer) -> Integer` -- rbs-inline's method-type comment.
    INLINE_METHOD_TYPE_RE = /\A#:\s*(\(.*)\z/
    # `# @rbs a: Integer` / `# @rbs return: Integer` -- rbs-inline's
    # per-parameter form. Only this trivial subset (one name, one type) is
    # read; anything else in an `@rbs` comment is left alone.
    INLINE_RBS_TAG_RE = /\A#\s*@rbs\s+([A-Za-z_]\w*[?!]?)\s*:\s*(.+?)\s*\z/

    def initialize(ruby_source, rbs_source: nil, lib_name: nil)
      @ruby_source = ruby_source
      @rbs_source = rbs_source
      @lib_name = lib_name
    end

    # Public top-level method names, in definition order. Handles: bare
    # `private`/`public` (flips subsequent defs), `private def foo`, and
    # `private :foo` / `public :foo`.
    def public_methods
      @public_methods ||= begin
        program = Prism.parse(@ruby_source).value
        body = program.statements.body
        mode = :public          # current default visibility
        vis  = {}               # name(String) => :public/:private (explicit wins)
        order = []

        body.each do |node|
          case node
          when Prism::DefNode
            name = node.name.to_s
            order << name unless vis.key?(name) || order.include?(name)
            vis[name] ||= mode
          when Prism::CallNode
            handle_call(node, mode_setter: ->(m) { mode = m }, vis: vis, order: order)
          end
        end

        order.select { |n| (vis[n] || :public) == :public }
      end
    end

    # The method types suppify knows for this source: the sidecar .rbs and
    # the inline annotations merged, keyed by method name. A method declared
    # in both raises rather than one winning silently.
    def signatures
      @signatures ||= begin
        sidecar = sidecar_signatures
        inline  = inline_signatures
        both = (sidecar.keys & inline.keys).sort
        unless both.empty?
          raise Error, "method(s) #{both.join(', ')} declared both inline (`#:` / `# @rbs`) " \
                       "and in the .rbs sidecar -- remove one of the two declarations"
        end
        sidecar.merge(inline)
      end
    end

    # The signatures of the exported (public) methods only, in export order.
    def export_signatures
      require_signatures!
      public_methods.each_with_object({}) { |m, h| h[m] = signatures[m] }
    end

    # The inline annotations rendered as a `class Object` RBS block -- what
    # suppify feeds spinel's --rbs seeding for them, so an inline-annotated
    # source seeds spinel exactly as a sidecar would. nil when the source has
    # no inline annotations (then the sidecar alone is the seed, unchanged).
    def inline_rbs_text
      sigs = inline_signatures
      return nil if sigs.empty?
      lines = sigs.map { |name, sig| "  def #{name}: (#{sig[:params].join(', ')}) -> #{sig[:ret]}" }
      "class Object\n#{lines.join("\n")}\nend\n"
    end

    # The module spinel's --ext-entry exports from: one `def self.suppi_<m>`
    # per public top-level method, delegating to it. spinel's --ext-entry
    # accepts only `Module.method` names (verified against 4a28d45: a
    # top-level name is refused), so suppify wraps rather than rewrites --
    # the user's file is untouched and still runs unmodified under CRuby.
    # The wrapper is also what roots each method: spinel DCEs a top-level
    # method nothing calls, but an --ext-entry export is a root. The RBS seed
    # alone does not type every parameter (a Hash[Integer, Integer] parameter
    # stays sp_RbVal), so a dead, literal-typed call to each wrapper entry
    # stays, as before, to give spinel a call-site type.
    WRAPPER_PREFIX = "suppi_"

    # Per-library, because spinel emits each entry as the external symbol
    # sp_<Module>_s_<method>: a shared module name would collide when two
    # suppify libraries are linked into one binary.
    def self.wrapper_module(lib_name)
      lib_name ? "SuppiExport_#{lib_name}" : "SuppiExport"
    end

    def wrapper_module = self.class.wrapper_module(@lib_name)

    # The Ruby source spinel compiles: unchanged when nothing is exported,
    # otherwise the original plus the wrapper module and its dead root calls.
    def rooted_source
      return @ruby_source if public_methods.empty?

      require_signatures!
      defs = public_methods.map do |m|
        ps = (0...signatures[m][:params].length).map { |i| "p#{i}" }.join(", ")
        "  def self.#{WRAPPER_PREFIX}#{m}(#{ps})\n    #{m}(#{ps})\n  end"
      end
      calls = public_methods.map { |m| root_call(m, signatures[m]) }
      "#{@ruby_source}\nmodule #{wrapper_module}\n#{defs.join("\n")}\nend\n" \
        "if false\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n"
    end

    # `Module.method` names for spinel's --ext-entry, in export order.
    def ext_entries
      public_methods.map { |m| "#{wrapper_module}.#{WRAPPER_PREFIX}#{m}" }
    end

    # The RBS the wrapper module needs: spinel types an exported method's
    # parameters from the seed, and the wrapper's own signature is what the
    # emitted header states. Empty when nothing is exported.
    def wrapper_rbs_text
      return nil if public_methods.empty?
      require_signatures!
      lines = public_methods.map do |m|
        sig = signatures[m]
        "  def self.#{WRAPPER_PREFIX}#{m}: (#{sig[:params].join(', ')}) -> #{sig[:ret]}"
      end
      "module #{wrapper_module}\n#{lines.join("\n")}\nend\n"
    end

    private

    def require_signatures!
      missing = public_methods - signatures.keys
      return if missing.empty?
      raise Error, "no RBS signature for public method(s): #{missing.join(', ')} " \
                   "(add an inline `#: (...) -> ...` comment above the def, or declare it " \
                   "under `class Object` in the sidecar .rbs)"
    end

    def root_call(name, sig)
      args = sig[:params].map { |t| literal_for(t) }
      "#{wrapper_module}.#{WRAPPER_PREFIX}#{name}(#{args.join(", ")})"
    end

    # A literal of the declared type for the synthetic root call. Containers
    # are built recursively; an Array literal is empty because the element
    # type comes from the --rbs seed, and a non-empty literal whose element
    # type is narrower than the declared one (e.g. [0] for Array[untyped])
    # makes spinel reject the call as contradicting the seed.
    def literal_for(type)
      case type.kind
      when :simple
        LITERALS.fetch(type.name) do
          raise Error, "RBS type not supported for root-call synthesis: #{type} " \
                       "(spinel has no value of this type to seed the export with)"
        end
      when :array    then "[]"
      when :tuple    then "[#{type.args.map { |t| literal_for(t) }.join(', ')}]"
      when :hash     then "{ #{literal_for(type.args[0])} => #{literal_for(type.args[1])} }"
      when :optional then literal_for(type.args[0])
      end
    end

    def handle_call(node, mode_setter:, vis:, order:)
      mname = node.name
      return unless mname == :private || mname == :public
      args = node.arguments&.arguments || []

      if args.empty?
        mode_setter.call(mname)                 # bare `private` / `public`
        return
      end

      args.each do |arg|
        case arg
        when Prism::DefNode                      # `private def foo`
          n = arg.name.to_s
          order << n unless order.include?(n)
          vis[n] = mname
        when Prism::SymbolNode                   # `private :foo`
          n = arg.unescaped
          order << n unless order.include?(n)
          vis[n] = mname
        end
      end
    end

    def sidecar_signatures
      sigs = {}
      in_object = false
      @rbs_source.to_s.each_line do |line|
        if line =~ /\A\s*class\s+Object\b/
          in_object = true
        elsif in_object && line =~ /\A\s*end\s*\z/
          in_object = false
        elsif in_object && (m = DEF_RE.match(line))
          sigs[m[1]] = RbsType.parse_method_type(m[2])
        end
      end
      sigs
    end

    # The inline annotations: for every top-level def, the contiguous comment
    # block immediately above it. `#:` carries a whole method type; `# @rbs`
    # carries one type per parameter plus `return:`. Mixing the two forms on
    # one def is an error rather than a guess about which wins.
    def inline_signatures
      @inline_signatures ||= def_sites.each_with_object({}) do |site, sigs|
        comments = comment_block_above(site[:line])
        method_type = comments.filter_map { |c| INLINE_METHOD_TYPE_RE.match(c)&.[](1) }
        tags = comments.filter_map { |c| INLINE_RBS_TAG_RE.match(c) }
                       .each_with_object({}) { |m, h| h[m[1]] = m[2] }
        next if method_type.empty? && tags.empty?
        if !method_type.empty? && !tags.empty?
          raise Error, "method #{site[:name]} has both a `#:` method type and `# @rbs` " \
                       "annotations -- use one form"
        end
        if method_type.length > 1
          raise Error, "method #{site[:name]} has #{method_type.length} `#:` method types " \
                       "above it -- keep one"
        end
        sigs[site[:name]] = method_type.empty? ? tag_signature(site, tags)
                                               : RbsType.parse_method_type(method_type[0])
      end
    end

    def tag_signature(site, tags)
      ret = tags["return"] or
        raise Error, "method #{site[:name]}: `# @rbs` annotations are missing `# @rbs return: <type>`"
      params = site[:params].map do |p|
        t = tags[p] or
          raise Error, "method #{site[:name]}: `# @rbs` annotations are missing parameter #{p} " \
                       "(every parameter needs one, or use a single `#: (...) -> ...` line)"
        RbsType.parse(t)
      end
      { params: params, ret: RbsType.parse(ret) }
    end

    # Top-level def sites, as [{name:, line:, params:}]. `line` is the line
    # of the whole statement (so `private def foo` finds the comment block
    # above the `private`, not above the `def`), and `params` are the
    # positional parameter names the `# @rbs` form is matched against.
    def def_sites
      @def_sites ||= begin
        program = Prism.parse(@ruby_source).value
        program.statements.body.flat_map do |node|
          defs = case node
                 when Prism::DefNode then [node]
                 when Prism::CallNode then (node.arguments&.arguments || []).grep(Prism::DefNode)
                 else []
                 end
          defs.map do |d|
            { name: d.name.to_s, line: node.location.start_line,
              params: (d.parameters&.requireds || []).map { |p| p.name.to_s } }
          end
        end
      end
    end

    def comment_block_above(line)
      lines = @ruby_source.lines
      block = []
      i = line - 2 # 0-based index of the line above the def
      while i >= 0 && lines[i].to_s.strip.start_with?("#")
        block.unshift(lines[i].strip)
        i -= 1
      end
      block
    end

  end

  class SpinelRunner
    # runner: callable(argv_array) -> [stdout_string, exit_status_int]
    # rbs_dir: directory of *.rbs sidecars fed to spinel's --rbs (advisory
    # type seeding; see Source#rooted_source for why suppify needs this).
    def initialize(spinel_bin: ENV["SPINEL"] || "spinel", runner: method(:shell), rbs_dir: nil,
                   ext_init: nil, ext_entries: [])
      @spinel_bin = spinel_bin
      @runner = runner
      @rbs_dir = rbs_dir
      @ext_init = ext_init
      @ext_entries = ext_entries
    end

    # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
    # emit modes (the symbol-map path short-circuits before the C-output
    # branch), so the two artifacts require separate invocations.
    def emit(rb_path, c_path)
      symbols_path = c_path.sub(/\.c\z/, "") + ".symbols.json"
      rbs_args = @rbs_dir ? ["--rbs", @rbs_dir] : []
      # --ext-init emits a main-less library TU plus its header (<out>.h)
      # stating init, the try-frame wrapper and each entry's C signature.
      ext_args = []
      ext_args += ["--ext-init", @ext_init] if @ext_init
      ext_args += ["--ext-entry", @ext_entries.join(",")] unless @ext_entries.empty?
      run!([@spinel_bin, rb_path, *rbs_args, *ext_args, "-c", "-o", c_path])
      run!([@spinel_bin, rb_path, "--emit-symbol-map", "-o", symbols_path])
      { c_path: c_path, symbols_path: symbols_path, header_path: c_path.sub(/\.c\z/, ".h") }
    end

    # Default runner: array-form argv, no shell involved.
    def shell(argv)
      out, status = Open3.capture2e(*argv)
      [out, status.exitstatus]
    end

    private

    def run!(argv)
      out, status = @runner.call(argv)
      raise Error, "spinel failed (#{status}): #{out}" unless status == 0
    end
  end

  # Generates the flat-message entry (`<lib>_<m>_call`) every exported
  # method gets in addition to its scalar C entry: one MessagePack message
  # in, one MessagePack message out, so a caller needs no spinel type, no
  # Ruby VM, and no knowledge of the method's RBS -- just bytes.
  #
  # The C representation of a parameter/return is spinel's choice, not
  # suppify's: #c_type mirrors the mapping observed from spinel's own
  # codegen (Array[Integer] -> sp_IntArray *, Array[Array[Integer]] ->
  # sp_PolyArray *, Hash[Symbol, V] -> sp_SymPolyHash *, ...), and Pipeline
  # checks every prediction against the signature spinel actually emitted --
  # a disagreement is reported, never compiled into a type-punned call.
  #
  # Decoders are generated per RBS type node, recursively, so any nesting
  # spinel can represent is marshalled without a per-shape special case.
  # Encoding needs no generated code at all: the return value is boxed into
  # spinel's own sp_RbVal and written by one generic encoder, which is also
  # what makes the bytes match what the kernel actually returned (an
  # Integer-valued slot of a Hash[Symbol, Float] is written as an int,
  # exactly as CRuby would answer it).
  class FlatCall
    # RBS simple type name -> the C type spinel gives it.
    SCALARS = {
      "Integer"    => "sp_int",
      "Float"      => "sp_float",
      "String"     => "const char *",
      "Symbol"     => "sp_sym",
      "bool"       => "sp_bool",
      "TrueClass"  => "sp_bool",
      "FalseClass" => "sp_bool",
      "untyped"    => "sp_RbVal",
      "void"       => "void",
    }.freeze

    # C container type -> the SP_BUILTIN_* class id spinel boxes it with.
    BUILTIN_ID = {
      "sp_IntArray *"     => "SP_BUILTIN_INT_ARRAY",
      "sp_FloatArray *"   => "SP_BUILTIN_FLT_ARRAY",
      "sp_StrArray *"     => "SP_BUILTIN_STR_ARRAY",
      "sp_PolyArray *"    => "SP_BUILTIN_POLY_ARRAY",
      "sp_IntIntHash *"   => "SP_BUILTIN_INT_INT_HASH",
      "sp_IntStrHash *"   => "SP_BUILTIN_INT_STR_HASH",
      "sp_StrIntHash *"   => "SP_BUILTIN_STR_INT_HASH",
      "sp_StrStrHash *"   => "SP_BUILTIN_STR_STR_HASH",
      "sp_StrPolyHash *"  => "SP_BUILTIN_STR_POLY_HASH",
      "sp_SymPolyHash *"  => "SP_BUILTIN_SYM_POLY_HASH",
      "sp_PolyPolyHash *" => "SP_BUILTIN_POLY_POLY_HASH",
    }.freeze

    # The (new, set) runtime API of each hash container, with the C type of
    # its key and value slots.
    HASH_API = {
      "sp_IntIntHash *"   => { new: "sp_IntIntHash_new",   set: "sp_IntIntHash_set",   key: "sp_int",        val: "sp_int" },
      "sp_IntStrHash *"   => { new: "sp_IntStrHash_new",   set: "sp_IntStrHash_set",   key: "sp_int",        val: "const char *" },
      "sp_StrIntHash *"   => { new: "sp_StrIntHash_new",   set: "sp_StrIntHash_set",   key: "const char *",  val: "sp_int" },
      "sp_StrStrHash *"   => { new: "sp_StrStrHash_new",   set: "sp_StrStrHash_set",   key: "const char *",  val: "const char *" },
      "sp_StrPolyHash *"  => { new: "sp_StrPolyHash_new",  set: "sp_StrPolyHash_set",  key: "const char *",  val: "sp_RbVal" },
      "sp_SymPolyHash *"  => { new: "sp_SymPolyHash_new",  set: "sp_SymPolyHash_set",  key: "sp_sym",        val: "sp_RbVal" },
      "sp_PolyPolyHash *" => { new: "sp_PolyPolyHash_new", set: "sp_PolyPolyHash_set", key: "sp_RbVal",      val: "sp_RbVal" },
    }.freeze

    ARRAY_API = {
      "sp_IntArray *"   => { new: "sp_IntArray_new",   push: "sp_IntArray_push",   elem: "sp_int" },
      "sp_FloatArray *" => { new: "sp_FloatArray_new", push: "sp_FloatArray_push", elem: "sp_float" },
      "sp_StrArray *"   => { new: "sp_StrArray_new",   push: "sp_StrArray_push",   elem: "const char *" },
      "sp_PolyArray *"  => { new: "sp_PolyArray_new",  push: "sp_PolyArray_push",  elem: "sp_RbVal" },
    }.freeze

    # The C types that hold a GC-managed reference and so must be rooted
    # between the moment they are built and the moment their owner holds
    # them (spinel collects inside the very next allocation).
    def self.gc_root_stmt(c_type, var)
      return "SP_GC_ROOT_RBVAL(#{var});" if c_type == "sp_RbVal"
      return "SP_GC_ROOT(#{var});" if c_type == "const char *" || c_type.end_with?("*")
      nil
    end

    # The C type spinel gives a value of this RBS type.
    def self.c_type(type)
      case type.kind
      when :simple
        SCALARS.fetch(type.name) do
          raise Error, "RBS type #{type} has no spinel representation at the suppify boundary " \
                       "(spinel types a top-level method's parameters and return from this " \
                       "fixed set: #{SCALARS.keys.join(', ')}, Array[...], Hash[...], tuples)"
        end
      when :array
        case type.args[0].name
        when "Integer" then "sp_IntArray *"
        when "Float"   then "sp_FloatArray *"
        when "String"  then "sp_StrArray *"
        else
          c_type(type.args[0]) # reject an element type spinel cannot hold at all
          "sp_PolyArray *"
        end
      when :tuple
        type.args.each { |t| c_type(t) }
        "sp_PolyArray *"
      when :hash
        k, v = type.args
        c_type(k)
        c_type(v)
        case k.name
        when "Symbol" then "sp_SymPolyHash *"
        when "String" then { "Integer" => "sp_StrIntHash *", "String" => "sp_StrStrHash *" }
                             .fetch(v.name.to_s, "sp_StrPolyHash *")
        when "Integer" then { "Integer" => "sp_IntIntHash *", "String" => "sp_IntStrHash *" }
                              .fetch(v.name.to_s, "sp_PolyPolyHash *")
        else "sp_PolyPolyHash *"
        end
      when :optional
        inner = c_type(type.args[0])
        # int?/float?/String?/container? keep the unqualified C type and
        # carry nil in-band (SP_INT_NIL / a reserved NaN / NULL); Symbol?
        # and bool? have no such spare inhabitant, so spinel boxes them.
        %w[sp_sym sp_bool].include?(inner) ? "sp_RbVal" : inner
      end
    end

    # The expression that boxes a returned C value into sp_RbVal for the
    # generic encoder. Driven by the C type spinel actually emitted (which
    # for a return value is inferred from the method body, not from the RBS:
    # `h.values` on a Hash[Symbol, Float] is an sp_PolyArray even though the
    # RBS says Array[Float]), with the RBS consulted only for the in-band
    # nil of an optional scalar.
    def self.return_box_expr(ct, rbs_type)
      if rbs_type && rbs_type.kind == :optional && c_type(rbs_type) == ct
        inner = c_type(rbs_type.args[0])
        return "sp_box_int_or_nil(rv)" if inner == "sp_int"
        return "sp_box_float_or_nil(rv)" if inner == "sp_float"
      end
      box_expr_for(ct, "rv")
    end

    # The expression that boxes a C value of this RBS type into sp_RbVal.
    def self.box_expr(type, var)
      ct = c_type(type)
      if type.kind == :optional
        inner = c_type(type.args[0])
        return "sp_box_int_or_nil(#{var})" if inner == "sp_int"
        return "sp_box_float_or_nil(#{var})" if inner == "sp_float"
      end
      box_expr_for(ct, var)
    end

    def self.box_expr_for(ct, var)
      case ct
      when "sp_int"        then "sp_box_int(#{var})"
      when "sp_float"      then "sp_box_float(#{var})"
      when "const char *"  then "sp_box_str(#{var})"
      when "sp_sym"        then "sp_box_sym(#{var})"
      when "sp_bool"       then "sp_box_bool(#{var})"
      when "sp_RbVal"      then var
      else
        id = BUILTIN_ID[ct] or
          raise Error, "no MessagePack encoding for the C type #{ct} spinel emitted " \
                       "(suppify marshals scalars, spinel's typed arrays and its hashes)"
        "sp_box_nullable_obj((void *)(#{var}), #{id})"
      end
    end

    # entries: [{ "public" =>, "cname" =>, "params" => [RbsType], "ret" => RbsType }]
    def initialize(lib_name:, entries:)
      @lib_name = lib_name
      @entries = entries
      @ids = {}
      @types = {}
      @entries.each { |e| e["params"].each { |t| register(t) } }
    end

    def c_source
      return "" if @entries.empty?
      out = +"\n/* === suppify appended flat-message entries (MessagePack) === */\n"
      out << RUNTIME
      out << generic_encoder
      out << "\n"
      @ids.each { |type_s, id| out << "static int suppi_dec_#{id}(suppi_rd *r, #{decl(c_type_of(type_s), 'out*')});\n" }
      @ids.each { |_t, id| out << "static int suppi_decb_#{id}(suppi_rd *r, sp_RbVal *out);\n" }
      out << "\n"
      @ids.each { |type_s, id| out << decoder(@types[type_s], id) }
      @entries.each { |e| out << entry(e) }
      out
    end

    def header
      return "" if @entries.empty?
      guard = @lib_name.upcase
      out = +"\n/* Flat-message entries: one MessagePack message in, one out.\n" \
             "   <m>_call returns the number of bytes written, or: */\n"
      out << "#define #{guard}_E_MALFORMED (-1) /* truncated, or not the declared RBS type */\n"
      out << "#define #{guard}_E_NOSPACE   (-2) /* out_cap too small for the reply */\n"
      out << "#define #{guard}_E_RAISED    (-3) /* the kernel raised; see #{@lib_name}_error_message() */\n"
      out << "#define #{guard}_E_RANGE     (-4) /* an Integer does not fit this target's sp_int */\n"
      @entries.each do |e|
        out << "int32_t #{@lib_name}_#{e['public']}_call(const uint8_t *in, int32_t in_len, " \
               "uint8_t *out, int32_t out_cap);\n"
        out << "const char *#{@lib_name}_#{e['public']}_signature(void);\n"
      end
      out
    end

    private

    # Registers a type and every type nested in it, parents first, so the
    # generated decoders can be emitted in one pass.
    def register(type)
      type.each_node do |node|
        key = node.to_s
        next if @ids.key?(key)
        @ids[key] = @ids.size
        @types[key] = node
      end
    end

    def c_type_of(type_s) = FlatCall.c_type(@types.fetch(type_s))

    # "sp_IntArray *" + "out*" -> "sp_IntArray **out" (and "sp_int *out").
    def decl(c_type, name)
      star = name.end_with?("*")
      base = name.sub(/\*\z/, "")
      sep = c_type.end_with?("*") ? "" : " "
      "#{c_type}#{sep}#{star ? '*' : ''}#{base}"
    end

    def dec_fn(type, slot)
      ct = FlatCall.c_type(type)
      id = @ids.fetch(type.to_s)
      return "suppi_dec_#{id}" if ct == slot
      return "suppi_decb_#{id}" if slot == "sp_RbVal"
      raise Error, "internal: cannot put #{type} (#{ct}) into a #{slot} slot"
    end

    def decoder(type, id)
      ct = FlatCall.c_type(type)
      body = +"static int suppi_dec_#{id}(suppi_rd *r, #{decl(ct, 'out*')}) {\n"
      body << case type.kind
              when :simple   then simple_decoder(type)
              when :optional then optional_decoder(type, ct)
              when :array    then array_decoder(type, ct)
              when :tuple    then tuple_decoder(type)
              when :hash     then hash_decoder(type, ct)
              end
      body << "}\n"
      body << boxed_decoder(type, id, ct)
      body
    end

    def boxed_decoder(type, id, ct)
      b = +"static int suppi_decb_#{id}(suppi_rd *r, sp_RbVal *out) {\n"
      if ct == "sp_RbVal"
        b << "    return suppi_dec_#{id}(r, out);\n"
      else
        b << "    #{decl(ct, 'v')}; int st = suppi_dec_#{id}(r, &v);\n"
        b << "    if (st < 0) return st;\n"
        b << "    *out = #{FlatCall.box_expr(type, 'v')};\n    return 0;\n"
      end
      b << "}\n"
      b
    end

    def simple_decoder(type)
      case FlatCall.c_type(type)
      when "sp_int"   then "    return suppi_rd_int(r, out);\n"
      when "sp_float" then "    return suppi_rd_f64(r, out);\n"
      when "sp_bool"  then "    return suppi_rd_bool(r, out);\n"
      when "sp_RbVal" then "    return suppi_rd_any(r, out);\n"
      when "const char *"
        "    const char *s; uint32_t n; int st = suppi_rd_str(r, &s, &n);\n" \
        "    if (st < 0) return st;\n    *out = sp_str_from_bytes(s, (size_t)n);\n    return 0;\n"
      when "sp_sym"
        "    const char *s; uint32_t n; int st = suppi_rd_str(r, &s, &n);\n" \
        "    if (st < 0) return st;\n" \
        "    const char *z = sp_str_from_bytes(s, (size_t)n); SP_GC_ROOT(z);\n" \
        "    *out = sp_sym_intern(z);\n    return 0;\n"
      end
    end

    # nil arrives as MessagePack nil and leaves as the in-band nil spinel
    # reserves for that slot; anything else is the inner type.
    def optional_decoder(type, ct)
      inner = type.args[0]
      nil_expr = case ct
                 when "sp_int"       then "SP_INT_NIL"
                 when "sp_float"     then "sp_float_nil()"
                 when "sp_RbVal"     then "sp_box_nil()"
                 when "const char *" then "NULL"
                 else "NULL"
                 end
      "    if (suppi_rd_nil_opt(r)) { *out = #{nil_expr}; return 0; }\n" \
      "    return #{dec_fn(inner, ct)}(r, out);\n"
    end

    def array_decoder(type, ct)
      api = ARRAY_API.fetch(ct)
      elem = type.args[0]
      root = FlatCall.gc_root_stmt(api[:elem], "e")
      b = +"    uint32_t n, i; int st;\n"
      b << "    if ((st = suppi_rd_arr(r, &n)) < 0) return st;\n"
      b << "    #{decl(ct, 'a')} = #{api[:new]}(); SP_GC_ROOT(a);\n"
      b << "    for (i = 0; i < n; i++) {\n"
      b << "        #{decl(api[:elem], 'e')};\n"
      b << "        if ((st = #{dec_fn(elem, api[:elem])}(r, &e)) < 0) return st;\n"
      b << "        #{root}\n" if root
      b << "        #{api[:push]}(a, e);\n    }\n"
      b << "    *out = a;\n    return 0;\n"
      b
    end

    def tuple_decoder(type)
      b = +"    uint32_t n; int st;\n"
      b << "    if ((st = suppi_rd_arr(r, &n)) < 0) return st;\n"
      b << "    if (n != #{type.args.length}) return SUPPI_EBAD;\n"
      b << "    sp_PolyArray *a = sp_PolyArray_new(); SP_GC_ROOT(a);\n"
      type.args.each do |t|
        b << "    {\n        sp_RbVal e;\n"
        b << "        if ((st = #{dec_fn(t, 'sp_RbVal')}(r, &e)) < 0) return st;\n"
        b << "        SP_GC_ROOT_RBVAL(e);\n        sp_PolyArray_push(a, e);\n    }\n"
      end
      b << "    *out = a;\n    return 0;\n"
      b
    end

    def hash_decoder(type, ct)
      api = HASH_API.fetch(ct)
      k, v = type.args
      kroot = FlatCall.gc_root_stmt(api[:key], "k")
      vroot = FlatCall.gc_root_stmt(api[:val], "v")
      b = +"    uint32_t n, i; int st;\n"
      b << "    if ((st = suppi_rd_map(r, &n)) < 0) return st;\n"
      b << "    #{decl(ct, 'h')} = #{api[:new]}(); SP_GC_ROOT(h);\n"
      b << "    for (i = 0; i < n; i++) {\n"
      b << "        #{decl(api[:key], 'k')}; #{decl(api[:val], 'v')};\n"
      b << "        if ((st = #{dec_fn(k, api[:key])}(r, &k)) < 0) return st;\n"
      b << "        #{kroot}\n" if kroot
      b << "        if ((st = #{dec_fn(v, api[:val])}(r, &v)) < 0) return st;\n"
      b << "        #{vroot}\n" if vroot
      b << "        #{api[:set]}(h, k, v);\n    }\n"
      b << "    *out = h;\n    return 0;\n"
      b
    end

    def entry(e)
      name = e["public"]
      ret = e["ret"]
      ret_c = e["ret_c"] # the C type spinel emitted, not the one the RBS predicts
      b = +"\nstatic int32_t suppi_body_#{name}(suppi_rd *r, suppi_wr *w) {\n"
      b << "    uint32_t argc; int st;\n"
      b << "    if ((st = suppi_rd_arr(r, &argc)) < 0) return (int32_t)st;\n"
      b << "    if (argc != #{e['params'].length}) return SUPPI_EBAD;\n"
      args = e["params"].each_with_index.map do |t, i|
        ct = FlatCall.c_type(t)
        b << "    #{decl(ct, "a#{i}")};\n"
        b << "    if ((st = #{dec_fn(t, ct)}(r, &a#{i})) < 0) return (int32_t)st;\n"
        root = FlatCall.gc_root_stmt(ct, "a#{i}")
        b << "    #{root}\n" if root
        "a#{i}"
      end
      if ret_c == "void"
        b << "    #{e['cname']}(#{args.join(', ')});\n"
        b << "    suppi_wr_nil(w);\n"
      else
        b << "    #{decl(ret_c, 'rv')} = #{e['cname']}(#{args.join(', ')});\n"
        b << "    if ((st = suppi_enc_poly(w, #{FlatCall.return_box_expr(ret_c, ret)})) < 0) " \
             "return (int32_t)st;\n"
      end
      b << "    if (w->ovf) return SUPPI_ESPACE;\n"
      b << "    return (int32_t)(w->p - w->b);\n}\n"
      b << call_wrapper(name)
      b << "const char *#{@lib_name}_#{name}_signature(void) { return \"#{e['sig_text']}\"; }\n"
      b
    end

    # The per-call exception barrier is spinel's own <kernel>_try frame (the
    # emitted --ext-init contract): the thunk runs the body, the wrapper
    # turns a caught raise into SUPPI_ERAISE via suppi__capture.
    def call_wrapper(name)
      try = "#{Suppify.kernel_init_name(@lib_name)}_try"
      <<~C

        static void suppi_thunk_#{name}(void *p) {
            suppi_call_ctx *c = (suppi_call_ctx *)p; suppi_rd r; suppi_wr w;
            r.p = c->in; r.e = c->in + c->in_len;
            w.b = c->out; w.p = c->out; w.e = c->out ? c->out + c->out_cap : c->out; w.ovf = 0;
            c->rc = suppi_body_#{name}(&r, &w);
        }
        int32_t #{@lib_name}_#{name}_call(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t out_cap) {
            suppi_call_ctx c; const char *cls, *msg;
            g_suppi_err = 0;
            if (!in || in_len < 0 || out_cap < 0 || (!out && out_cap > 0)) return SUPPI_EBAD;
            c.in = in; c.in_len = in_len; c.out = out; c.out_cap = out_cap; c.rc = 0;
            if (#{try}(suppi_thunk_#{name}, &c, &cls, &msg)) { suppi__capture(msg); return SUPPI_ERAISE; }
            return c.rc;
        }
      C
    end

    # The generic sp_RbVal -> MessagePack encoder. Written once per library;
    # it dispatches on spinel's own tag/class id, so what goes on the wire is
    # what the kernel actually returned.
    def generic_encoder
      len = "#{@lib_name}_str_len"
      hash_arms = [
        ["SP_BUILTIN_INT_INT_HASH",   "sp_IntIntHash",   "sp_box_int_array",  "sp_box_int_array"],
        ["SP_BUILTIN_INT_STR_HASH",   "sp_IntStrHash",   "sp_box_int_array",  "sp_box_str_array"],
        ["SP_BUILTIN_STR_INT_HASH",   "sp_StrIntHash",   "sp_box_str_array",  "sp_box_int_array"],
        ["SP_BUILTIN_STR_STR_HASH",   "sp_StrStrHash",   "sp_box_str_array",  "sp_box_str_array"],
        ["SP_BUILTIN_STR_POLY_HASH",  "sp_StrPolyHash",  "sp_box_str_array",  "sp_box_poly_array"],
        ["SP_BUILTIN_SYM_POLY_HASH",  "sp_SymPolyHash",  "suppi_box_sym_array", "sp_box_poly_array"],
        ["SP_BUILTIN_POLY_POLY_HASH", "sp_PolyPolyHash", "sp_box_poly_array", "sp_box_poly_array"],
      ].map do |id, type, kbox, vbox|
        "    case #{id}: {\n" \
        "        #{type} *h = (#{type} *)v.v.p;\n" \
        "        void *ks = #{type}_keys(h); SP_GC_ROOT(ks);\n" \
        "        void *vs = #{type}_values(h); SP_GC_ROOT(vs);\n" \
        "        return suppi_enc_map2(w, #{kbox}(ks), #{vbox}(vs));\n    }\n"
      end.join

      <<~C
        static sp_RbVal suppi_box_sym_array(void *p) { return sp_box_obj(p, SP_BUILTIN_SYM_ARRAY); }

        static sp_int suppi_poly_len(sp_RbVal a) {
            if (a.tag != SP_TAG_OBJ || !a.v.p) return 0;
            switch (a.cls_id) {
            case SP_BUILTIN_INT_ARRAY: case SP_BUILTIN_SYM_ARRAY: return ((sp_IntArray *)a.v.p)->len;
            case SP_BUILTIN_FLT_ARRAY: return ((sp_FloatArray *)a.v.p)->len;
            case SP_BUILTIN_STR_ARRAY: return ((sp_StrArray *)a.v.p)->len;
            case SP_BUILTIN_POLY_ARRAY: return ((sp_PolyArray *)a.v.p)->len;
            default: return 0;
            }
        }

        static sp_RbVal suppi_poly_elem(sp_RbVal a, sp_int i) {
            switch (a.cls_id) {
            case SP_BUILTIN_INT_ARRAY: return sp_box_int(sp_IntArray_get((sp_IntArray *)a.v.p, i));
            case SP_BUILTIN_SYM_ARRAY: return sp_box_sym((sp_sym)sp_IntArray_get((sp_IntArray *)a.v.p, i));
            case SP_BUILTIN_FLT_ARRAY: return sp_box_float(sp_FloatArray_get((sp_FloatArray *)a.v.p, i));
            case SP_BUILTIN_STR_ARRAY: return sp_box_str(sp_StrArray_get((sp_StrArray *)a.v.p, i));
            case SP_BUILTIN_POLY_ARRAY: return sp_PolyArray_get((sp_PolyArray *)a.v.p, i);
            default: return sp_box_nil();
            }
        }

        static int suppi_enc_poly(suppi_wr *w, sp_RbVal v);

        static int suppi_enc_seq(suppi_wr *w, sp_RbVal a) {
            sp_int n = suppi_poly_len(a), i;
            int st;
            suppi_wr_arr(w, (uint32_t)n);
            for (i = 0; i < n; i++) {
                sp_RbVal e = suppi_poly_elem(a, i);
                if ((st = suppi_enc_poly(w, e)) < 0) return st;
            }
            return 0;
        }

        static int suppi_enc_map2(suppi_wr *w, sp_RbVal ks, sp_RbVal vs) {
            sp_int n = suppi_poly_len(ks), i;
            int st;
            SP_GC_ROOT_RBVAL(ks); SP_GC_ROOT_RBVAL(vs);
            suppi_wr_map(w, (uint32_t)n);
            for (i = 0; i < n; i++) {
                if ((st = suppi_enc_poly(w, suppi_poly_elem(ks, i))) < 0) return st;
                if ((st = suppi_enc_poly(w, suppi_poly_elem(vs, i))) < 0) return st;
            }
            return 0;
        }

        static int suppi_enc_poly(suppi_wr *w, sp_RbVal v) {
            switch (v.tag) {
            case SP_TAG_NIL:  suppi_wr_nil(w); return 0;
            case SP_TAG_BOOL: suppi_wr_bool(w, v.v.b ? 1 : 0); return 0;
            case SP_TAG_INT:  suppi_wr_int(w, (int64_t)v.v.i); return 0;
            case SP_TAG_FLT:  suppi_wr_f64(w, (double)v.v.f); return 0;
            case SP_TAG_STR:  suppi_wr_str(w, v.v.s, (uint32_t)#{len}(v.v.s)); return 0;
            case SP_TAG_SYM: {
                const char *s = sp_sym_to_s((sp_sym)v.v.i);
                suppi_wr_str(w, s, (uint32_t)#{len}(s));
                return 0;
            }
            case SP_TAG_OBJ: break;
            default: return SUPPI_EBAD; /* Bigint/Time/Range/user object: no MessagePack type */
            }
            if (!v.v.p) { suppi_wr_nil(w); return 0; }
            switch (v.cls_id) {
            case SP_BUILTIN_INT_ARRAY: case SP_BUILTIN_SYM_ARRAY: case SP_BUILTIN_FLT_ARRAY:
            case SP_BUILTIN_STR_ARRAY: case SP_BUILTIN_POLY_ARRAY:
                return suppi_enc_seq(w, v);
        #{hash_arms}    default: return SUPPI_EBAD;
            }
        }
      C
    end

    # The fixed part: the MessagePack reader/writer and the generic
    # "any value" decoder (what an `untyped` slot is decoded through).
    # Integers are range-checked against this target's sp_int -- 4 bytes on
    # a 32-bit MCU, 8 on a host -- so an out-of-range value is a status, not
    # a silent truncation.
    RUNTIME = <<~C
      #define SUPPI_EBAD   (-1)
      #define SUPPI_ESPACE (-2)
      #define SUPPI_ERAISE (-3)
      #define SUPPI_ERANGE (-4)

      typedef struct { const uint8_t *p; const uint8_t *e; } suppi_rd;
      typedef struct { uint8_t *b; uint8_t *p; uint8_t *e; int ovf; } suppi_wr;

      static int suppi_rd_tag(suppi_rd *r, uint8_t *o) {
          if (r->p >= r->e) return SUPPI_EBAD;
          *o = *r->p++; return 0;
      }
      static int suppi_rd_be(suppi_rd *r, int n, uint64_t *o) {
          uint64_t v = 0; int i;
          if (r->e - r->p < n) return SUPPI_EBAD;
          for (i = 0; i < n; i++) v = (v << 8) | (uint64_t)*r->p++;
          *o = v; return 0;
      }
      static int suppi_rd_i64(suppi_rd *r, int64_t *o) {
          uint8_t t; uint64_t u; int st;
          if ((st = suppi_rd_tag(r, &t)) < 0) return st;
          if (t <= 0x7f) { *o = (int64_t)t; return 0; }
          if (t >= 0xe0) { *o = (int64_t)(int8_t)t; return 0; }
          switch (t) {
          case 0xcc: if ((st = suppi_rd_be(r, 1, &u)) < 0) return st; *o = (int64_t)u; return 0;
          case 0xcd: if ((st = suppi_rd_be(r, 2, &u)) < 0) return st; *o = (int64_t)u; return 0;
          case 0xce: if ((st = suppi_rd_be(r, 4, &u)) < 0) return st; *o = (int64_t)u; return 0;
          case 0xcf: if ((st = suppi_rd_be(r, 8, &u)) < 0) return st;
                     if (u > (uint64_t)INT64_MAX) return SUPPI_ERANGE;
                     *o = (int64_t)u; return 0;
          case 0xd0: if ((st = suppi_rd_be(r, 1, &u)) < 0) return st; *o = (int64_t)(int8_t)u; return 0;
          case 0xd1: if ((st = suppi_rd_be(r, 2, &u)) < 0) return st; *o = (int64_t)(int16_t)u; return 0;
          case 0xd2: if ((st = suppi_rd_be(r, 4, &u)) < 0) return st; *o = (int64_t)(int32_t)u; return 0;
          case 0xd3: if ((st = suppi_rd_be(r, 8, &u)) < 0) return st; *o = (int64_t)u; return 0;
          default: return SUPPI_EBAD;
          }
      }
      static int suppi_rd_int(suppi_rd *r, sp_int *o) {
          int64_t v; int st = suppi_rd_i64(r, &v);
          if (st < 0) return st;
          if (v < (int64_t)INTPTR_MIN || v > (int64_t)INTPTR_MAX) return SUPPI_ERANGE;
          *o = (sp_int)v; return 0;
      }
      static int suppi_rd_f64(suppi_rd *r, sp_float *o) {
          uint8_t t; uint64_t u; int st;
          union { uint32_t u; float f; } f32;
          union { uint64_t u; double d; } f64;
          if ((st = suppi_rd_tag(r, &t)) < 0) return st;
          if (t == 0xca) { if ((st = suppi_rd_be(r, 4, &u)) < 0) return st; f32.u = (uint32_t)u; *o = (sp_float)f32.f; return 0; }
          if (t == 0xcb) { if ((st = suppi_rd_be(r, 8, &u)) < 0) return st; f64.u = u; *o = (sp_float)f64.d; return 0; }
          return SUPPI_EBAD;
      }
      static int suppi_rd_bool(suppi_rd *r, sp_bool *o) {
          uint8_t t; int st;
          if ((st = suppi_rd_tag(r, &t)) < 0) return st;
          if (t == 0xc2) { *o = 0; return 0; }
          if (t == 0xc3) { *o = 1; return 0; }
          return SUPPI_EBAD;
      }
      /* Consumes a nil if that is what comes next; leaves the reader alone
         otherwise (how a T? slot tells nil from a value). */
      static int suppi_rd_nil_opt(suppi_rd *r) {
          if (r->p < r->e && *r->p == 0xc0) { r->p++; return 1; }
          return 0;
      }
      static int suppi_rd_str(suppi_rd *r, const char **s, uint32_t *n) {
          uint8_t t; uint64_t u; int st;
          if ((st = suppi_rd_tag(r, &t)) < 0) return st;
          if ((t & 0xe0) == 0xa0) u = (uint64_t)(t & 0x1f);
          else if (t == 0xd9) { if ((st = suppi_rd_be(r, 1, &u)) < 0) return st; }
          else if (t == 0xda) { if ((st = suppi_rd_be(r, 2, &u)) < 0) return st; }
          else if (t == 0xdb) { if ((st = suppi_rd_be(r, 4, &u)) < 0) return st; }
          else return SUPPI_EBAD;
          if ((uint64_t)(r->e - r->p) < u) return SUPPI_EBAD;
          *s = (const char *)r->p; *n = (uint32_t)u; r->p += u;
          return 0;
      }
      static int suppi_rd_arr(suppi_rd *r, uint32_t *n) {
          uint8_t t; uint64_t u; int st;
          if ((st = suppi_rd_tag(r, &t)) < 0) return st;
          if ((t & 0xf0) == 0x90) u = (uint64_t)(t & 0x0f);
          else if (t == 0xdc) { if ((st = suppi_rd_be(r, 2, &u)) < 0) return st; }
          else if (t == 0xdd) { if ((st = suppi_rd_be(r, 4, &u)) < 0) return st; }
          else return SUPPI_EBAD;
          *n = (uint32_t)u; return 0;
      }
      static int suppi_rd_map(suppi_rd *r, uint32_t *n) {
          uint8_t t; uint64_t u; int st;
          if ((st = suppi_rd_tag(r, &t)) < 0) return st;
          if ((t & 0xf0) == 0x80) u = (uint64_t)(t & 0x0f);
          else if (t == 0xde) { if ((st = suppi_rd_be(r, 2, &u)) < 0) return st; }
          else if (t == 0xdf) { if ((st = suppi_rd_be(r, 4, &u)) < 0) return st; }
          else return SUPPI_EBAD;
          *n = (uint32_t)u; return 0;
      }

      static void suppi_wr_put(suppi_wr *w, const uint8_t *b, int32_t n) {
          if (w->ovf) return;
          if (n > (int32_t)(w->e - w->p)) { w->ovf = 1; return; }
          if (n > 0) memcpy(w->p, b, (size_t)n);
          w->p += n;
      }
      static void suppi_wr_u8(suppi_wr *w, uint8_t b) { suppi_wr_put(w, &b, 1); }
      static void suppi_wr_be(suppi_wr *w, uint64_t v, int n) {
          uint8_t b[8]; int i;
          for (i = 0; i < n; i++) b[i] = (uint8_t)(v >> (8 * (n - 1 - i)));
          suppi_wr_put(w, b, (int32_t)n);
      }
      static void suppi_wr_nil(suppi_wr *w) { suppi_wr_u8(w, 0xc0); }
      static void suppi_wr_bool(suppi_wr *w, int b) { suppi_wr_u8(w, b ? 0xc3 : 0xc2); }
      static void suppi_wr_int(suppi_wr *w, int64_t v) {
          if (v >= 0) {
              if (v <= 0x7f) suppi_wr_u8(w, (uint8_t)v);
              else if (v <= 0xff) { suppi_wr_u8(w, 0xcc); suppi_wr_be(w, (uint64_t)v, 1); }
              else if (v <= 0xffff) { suppi_wr_u8(w, 0xcd); suppi_wr_be(w, (uint64_t)v, 2); }
              else if (v <= 0xffffffffLL) { suppi_wr_u8(w, 0xce); suppi_wr_be(w, (uint64_t)v, 4); }
              else { suppi_wr_u8(w, 0xcf); suppi_wr_be(w, (uint64_t)v, 8); }
          } else {
              if (v >= -32) suppi_wr_u8(w, (uint8_t)(int8_t)v);
              else if (v >= -128) { suppi_wr_u8(w, 0xd0); suppi_wr_be(w, (uint64_t)(uint8_t)(int8_t)v, 1); }
              else if (v >= -32768) { suppi_wr_u8(w, 0xd1); suppi_wr_be(w, (uint64_t)(uint16_t)(int16_t)v, 2); }
              else if (v >= -2147483647LL - 1) { suppi_wr_u8(w, 0xd2); suppi_wr_be(w, (uint64_t)(uint32_t)(int32_t)v, 4); }
              else { suppi_wr_u8(w, 0xd3); suppi_wr_be(w, (uint64_t)v, 8); }
          }
      }
      static void suppi_wr_f64(suppi_wr *w, double d) {
          union { double d; uint64_t u; } c; c.d = d;
          suppi_wr_u8(w, 0xcb); suppi_wr_be(w, c.u, 8);
      }
      static void suppi_wr_str(suppi_wr *w, const char *s, uint32_t n) {
          if (n < 32) suppi_wr_u8(w, (uint8_t)(0xa0 | n));
          else if (n < 256) { suppi_wr_u8(w, 0xd9); suppi_wr_be(w, n, 1); }
          else if (n < 65536) { suppi_wr_u8(w, 0xda); suppi_wr_be(w, n, 2); }
          else { suppi_wr_u8(w, 0xdb); suppi_wr_be(w, n, 4); }
          suppi_wr_put(w, (const uint8_t *)s, (int32_t)n);
      }
      static void suppi_wr_arr(suppi_wr *w, uint32_t n) {
          if (n < 16) suppi_wr_u8(w, (uint8_t)(0x90 | n));
          else if (n < 65536) { suppi_wr_u8(w, 0xdc); suppi_wr_be(w, n, 2); }
          else { suppi_wr_u8(w, 0xdd); suppi_wr_be(w, n, 4); }
      }
      static void suppi_wr_map(suppi_wr *w, uint32_t n) {
          if (n < 16) suppi_wr_u8(w, (uint8_t)(0x80 | n));
          else if (n < 65536) { suppi_wr_u8(w, 0xde); suppi_wr_be(w, n, 2); }
          else { suppi_wr_u8(w, 0xdf); suppi_wr_be(w, n, 4); }
      }

      /* An `untyped` slot: the message's own type decides the Ruby value.
         Arrays become Array (poly), maps become Hash (poly/poly); a str
         becomes a String, since nothing here says Symbol. */
      static int suppi_rd_any(suppi_rd *r, sp_RbVal *out) {
          uint8_t t; int st; uint32_t n, i;
          if (r->p >= r->e) return SUPPI_EBAD;
          t = *r->p;
          if (t == 0xc0) { r->p++; *out = sp_box_nil(); return 0; }
          if (t == 0xc2 || t == 0xc3) { r->p++; *out = sp_box_bool(t == 0xc3); return 0; }
          if (t == 0xca || t == 0xcb) {
              sp_float d; if ((st = suppi_rd_f64(r, &d)) < 0) return st;
              *out = sp_box_float(d); return 0;
          }
          if (t <= 0x7f || t >= 0xe0 || (t >= 0xcc && t <= 0xd3)) {
              sp_int v; if ((st = suppi_rd_int(r, &v)) < 0) return st;
              *out = sp_box_int(v); return 0;
          }
          if ((t & 0xe0) == 0xa0 || t == 0xd9 || t == 0xda || t == 0xdb) {
              const char *s; uint32_t sn;
              if ((st = suppi_rd_str(r, &s, &sn)) < 0) return st;
              *out = sp_box_str(sp_str_from_bytes(s, (size_t)sn)); return 0;
          }
          if ((t & 0xf0) == 0x90 || t == 0xdc || t == 0xdd) {
              sp_PolyArray *a;
              if ((st = suppi_rd_arr(r, &n)) < 0) return st;
              a = sp_PolyArray_new(); SP_GC_ROOT(a);
              for (i = 0; i < n; i++) {
                  sp_RbVal e;
                  if ((st = suppi_rd_any(r, &e)) < 0) return st;
                  SP_GC_ROOT_RBVAL(e);
                  sp_PolyArray_push(a, e);
              }
              *out = sp_box_poly_array(a); return 0;
          }
          if ((t & 0xf0) == 0x80 || t == 0xde || t == 0xdf) {
              sp_PolyPolyHash *h;
              if ((st = suppi_rd_map(r, &n)) < 0) return st;
              h = sp_PolyPolyHash_new(); SP_GC_ROOT(h);
              for (i = 0; i < n; i++) {
                  sp_RbVal k, v;
                  if ((st = suppi_rd_any(r, &k)) < 0) return st;
                  SP_GC_ROOT_RBVAL(k);
                  if ((st = suppi_rd_any(r, &v)) < 0) return st;
                  SP_GC_ROOT_RBVAL(v);
                  sp_PolyPolyHash_set(h, k, v);
              }
              *out = sp_box_obj(h, SP_BUILTIN_POLY_POLY_HASH); return 0;
          }
          return SUPPI_EBAD;
      }
    C
  end

  # Transforms spinel's output (generated C + symbol map) plus the original
  # Ruby into the neutral library: the export list, the library C source
  # (renamed main + appended trampolines/error API/init), and the neutral
  # header consumers include.
  class Pipeline
    def initialize(ruby_source:, c_source:, header_text:, symbols_json:, lib_name:, rbs_signatures: {})
      @ruby_source     = ruby_source
      @c_source        = c_source
      @header_text     = header_text
      @cnames          = parse_symbols(symbols_json)
      @lib_name        = lib_name
      @rbs_signatures  = rbs_signatures
    end

    def run
      exports = build_exports
      flat = FlatCall.new(lib_name: @lib_name, entries: exports.select { |e| e["flat"] })
      c = @c_source + trampolines(exports.select { |e| e["neutral"] })
      c = c + flat.c_source
      { exports: exports, c_source: c, header: header(exports, flat) }
    end

    # Each export carries: the C signature spinel emitted ("sig"), whether
    # that signature is expressible in neutral C scalars ("neutral" -- it
    # gets the plain `<m>(...)` entry and a VM binding), and, when its RBS
    # method type is known, the type tree the flat-message entry is
    # generated from ("flat").
    def build_exports
      Source.new(@ruby_source).public_methods.map do |ruby_name|
        cname = @cnames["#{Source.wrapper_module(@lib_name)}.#{Source::WRAPPER_PREFIX}#{ruby_name}"]
        next nil unless cname # public method spinel did not emit (e.g. unused) — skip
        sig = SignatureExtractor.extract(@header_text, cname)
        rbs = @rbs_signatures[ruby_name]
        e = { "public" => ruby_name, "cname" => cname, "sig" => sig, "neutral" => neutral?(sig) }
        if rbs
          check_predicted_types!(ruby_name, sig, rbs)
          e["params"] = rbs[:params]
          e["ret"] = rbs[:ret]
          e["ret_c"] = norm(sig.return_type)
          e["sig_text"] = "(#{rbs[:params].join(', ')}) -> #{rbs[:ret]}"
          e["flat"] = true
        elsif !e["neutral"]
          raise NonNeutralType, "no neutral C entry and no RBS method type for #{ruby_name}: " \
                                "spinel gave it the signature #{sig.return_type} " \
                                "(#{sig.params.map(&:first).join(', ')})"
        end
        e
      end.compact
    end

    private

    def neutral?(sig)
      NeutralType.map(sig.return_type)
      sig.params.each { |t, _| NeutralType.map(t) }
      true
    rescue NonNeutralType
      false
    end

    # A parameter's C type is decided by the RBS seed, so suppify can predict
    # it (FlatCall.c_type) and generate a decoder that builds exactly that --
    # but the prediction is checked against what spinel emitted, so a
    # divergence is a clear error rather than a type-punned call.
    #
    # A RETURN type is not checked: spinel infers it from the method body,
    # not from the RBS (`h.values` on a Hash[Symbol, Float] is an
    # sp_PolyArray, not an sp_FloatArray), and the encoder needs no
    # prediction anyway -- it boxes whatever C type came back and writes it
    # by spinel's own runtime tag. FlatCall.c_type is still called on the
    # declared return type, so an unrepresentable one is still rejected.
    def check_predicted_types!(name, sig, rbs)
      if sig.params.length != rbs[:params].length
        raise Error, "#{name}: the RBS method type declares #{rbs[:params].length} parameter(s) " \
                     "but spinel emitted #{sig.params.length}"
      end
      FlatCall.c_type(rbs[:ret])
      rbs[:params].each_with_index do |rbs_type, i|
        c_type = sig.params[i][0]
        want = FlatCall.c_type(rbs_type)
        next if norm(want) == norm(c_type)
        raise Error, "#{name}: parameter #{i + 1} is declared #{rbs_type} (suppify expects the " \
                     "C type #{want}) but spinel emitted #{c_type} -- suppify cannot marshal " \
                     "this parameter"
      end
    end

    def norm(c_type) = c_type.to_s.gsub(/\s+/, " ").strip

    def parse_symbols(json)
      data = JSON.parse(json)
      (data["symbols"] || []).each_with_object({}) { |e, h| h[e["ruby"]] = e["c"] }
    end

    # ---- the C block appended to the generated translation unit: extern
    # trampolines (with a per-call setjmp exception barrier), the error
    # query API, and <lib_name>_init.
    #
    # lib_name namespaces the handful of symbols this block exports with
    # external linkage (init/error/error_message) so two suppify libraries
    # linked into the same binary don't collide -- spinel's runtime state
    # (armed by lib_init) is otherwise a set of process-wide globals meant
    # for exactly one generated program per binary. Internal statics
    # (g_suppi_err et al.) already have file-local linkage and need no
    # namespacing.
    def trampolines(exports)
      out = +"\n/* === suppify appended trampolines === */\n"
      out << "static int g_suppi_err = 0;\n"
      out << "static const char *g_suppi_msg = 0;\n"
      out << "static char g_suppi_msgbuf[256];\n"
      out << capture
      out << call_ctx
      exports.each { |e| out << trampoline(e) << "\n" }
      out << "int #{@lib_name}_error(void) { return g_suppi_err; }\n"
      out << "const char *#{@lib_name}_error_message(void) { return g_suppi_msg; }\n"
      out << str_len_bridge
      out << lib_init
      out
    end

    # Runs when a <kernel>_try frame reports a raise: copies spinel's message
    # (only valid until the next call) into this library's own buffer so
    # <lib>_error_message() stays valid, and sets the error flag.
    def capture
      <<~C

        static void suppi__capture(const char *m) {
            if (!m || !*m) m = "uncaught exception";
            strncpy(g_suppi_msgbuf, m, sizeof g_suppi_msgbuf - 1);
            g_suppi_msgbuf[sizeof g_suppi_msgbuf - 1] = 0;
            g_suppi_msg = g_suppi_msgbuf;
            g_suppi_err = 1;
        }
      C
    end

    # What a flat entry's thunk receives through <kernel>_try's void *ctx.
    def call_ctx
      <<~C

        typedef struct { const uint8_t *in; int32_t in_len; uint8_t *out; int32_t out_cap; int32_t rc; } suppi_call_ctx;
      C
    end

    # The scalar entry: arguments travel to a thunk through <kernel>_try's
    # ctx struct, so the call (string dup included) runs inside spinel's
    # try frame, which also restores the GC root count on a caught raise.
    def trampoline(e)
      sig  = e["sig"]
      ret  = NeutralType.map(sig.return_type)
      name = e["public"]
      try  = "#{Suppify.kernel_init_name(@lib_name)}_try"
      fields = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n};" }
      fields << "#{ret} r;" unless ret == "void"
      fields << "int unused;" if fields.empty?
      ps = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n}" }
      plist = ps.empty? ? "void" : ps.join(", ")

      body = +"typedef struct { #{fields.join(' ')} } suppi_sc_#{name};\n"
      body << "static void suppi_sc_thunk_#{name}(void *p) {\n"
      body << "    suppi_sc_#{name} *c = (suppi_sc_#{name} *)p;\n"
      args = sig.params.map { |t, n| string_arg(body, t, n, "c->#{n}") }.join(", ")
      body << "    #{ret == 'void' ? '' : 'c->r = '}#{e['cname']}(#{args});\n}\n"
      body << "#{ret} #{name}(#{plist}) {\n"
      body << "    suppi_sc_#{name} c; const char *cls, *msg;\n"
      body << "    g_suppi_err = 0;\n"
      sig.params.each { |_, n| body << "    c.#{n} = #{n};\n" }
      body << "    if (#{try}(suppi_sc_thunk_#{name}, &c, &cls, &msg)) { suppi__capture(msg); return#{ret == 'void' ? '' : ' 0'}; }\n"
      body << "    return#{ret == 'void' ? '' : ' c.r'};\n}\n"
      body
    end

    # Raw host-language string pointers lack spinel's sp_str_hdr / marker
    # byte at ptr[-1]; passing one straight into a spinel-generated function
    # is an out-of-bounds read. sp_str_dup_external mirrors what spinel
    # itself does for foreign strings (argv/getenv).
    #
    # A duped string is just a bare C temporary until it reaches the callee
    # -- with two or more string arguments, the NEXT dup's allocation can
    # trigger a collection that sweeps an earlier, still-unrooted one before
    # the call happens (confirmed empirically: sp_str_alloc collects BEFORE
    # allocating, and a fresh string starts unmarked). SP_GC_ROOT is the same
    # discipline spinel's own codegen uses for its local variables, so each
    # duped string is declared as a named local and rooted immediately.
    def string_arg(body, t, n, expr)
      return expr unless NeutralType.kind(t) == :string
      dup = "sp_dup_#{n}"
      body << "    const char *#{dup} = sp_str_dup_external(#{expr}); SP_GC_ROOT(#{dup});\n"
      dup
    end

    # rb_str_new_cstr/mrb_str_new_cstr are strlen-based, silently truncating
    # a String return at its first embedded NUL. sp_str_byte_len recovers
    # spinel's own tracked byte length from the string header instead of
    # strlen -- except it only recognizes the 0xfe/0xfc/0xfd marker bytes,
    # not 0xf1 (a heap string frozen via .freeze, including every literal
    # in a `# frozen_string_literal: true` file -- see spinel's own
    # sp_str_freeze_val), silently falling back to strlen for a frozen
    # string and reintroducing the exact truncation this bridge exists to
    # avoid. sp_str_freeze_val only flips the marker byte in place on an
    # already sp_str_alloc'd buffer, so the header behind a 0xf1-marked
    # string is still valid; read it directly for this one marker spinel's
    # own helper misses.
    def str_len_bridge
      <<~C

        size_t #{@lib_name}_str_len(const char *s) {
            if (!s) return 0;
            if (((const unsigned char *)s)[-1] == 0xf1) {
                return (((const sp_str_hdr *)(s - 1)) - 1)->len;
            }
            return sp_str_byte_len(s);
        }
      C
    end

    # <lib>_init stays idempotent (bindings call it from each VM's load hook);
    # the initialization itself is spinel's --ext-init function.
    def lib_init
      <<~C
        void #{@lib_name}_init(void) {
            static int done = 0; if (done) return; done = 1;
            #{Suppify.kernel_init_name(@lib_name)}();
        }
      C
    end

    def header(exports, flat = nil)
      guard = "#{@lib_name.upcase}_H"
      out = +"#ifndef #{guard}\n#define #{guard}\n\n#include <stdint.h>\n#include <stddef.h>\n\n"
      out << "void #{@lib_name}_init(void);\n"
      out << "int #{@lib_name}_error(void);\n"
      out << "const char *#{@lib_name}_error_message(void);\n"
      out << "size_t #{@lib_name}_str_len(const char *s);\n\n"
      exports.select { |e| e["neutral"] }.each do |e|
        sig = e["sig"]
        ret = NeutralType.map(sig.return_type)
        ps  = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n}" }
        plist = ps.empty? ? "void" : ps.join(", ")
        out << "#{ret} #{e['public']}(#{plist});\n"
      end
      out << flat.header if flat
      out << "\n#endif\n"
      out
    end
  end
end
