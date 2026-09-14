# lib/suppify/core.rb — the コア layer: everything from the user's Ruby +
# .rbs sidecar to a neutral C library surface (exports, library C source,
# neutral header). One class per pipeline stage, in pipeline order:
#
#   Source       — analyze the user's Ruby/.rbs; synthesize the rooted source
#   SpinelRunner — run the external spinel compiler on the rooted source
#   Pipeline     — transform spinel's C + symbol map into the neutral library
#
# plus the shared type vocabulary (NeutralType) and C-signature extraction
# (Signature / SignatureExtractor) both this layer and the bindings use.
require "json"
require "open3"
require "prism"

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

  Signature = Struct.new(:return_type, :params) # params: [[c_type, name], ...]

  # Extracts a function's C signature from generated C text by its cname.
  # Generated definitions are regular: `[static ]<ret> <cname>(<params>) {`.
  module SignatureExtractor
    module_function

    def extract(c_source, cname)
      # Match the definition line: capture return type (everything before the
      # cname) and the parenthesized parameter list.
      re = /(?<ret>[A-Za-z_][\w \*]*?)\s*\b#{Regexp.escape(cname)}\s*\((?<params>[^)]*)\)\s*\{/
      m = c_source.match(re)
      raise Error, "definition not found for #{cname}" unless m
      ret = m[:ret].sub(/\Astatic\s+/, "").strip
      Signature.new(ret, parse_params(m[:params]))
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
  # because nothing in the program calls them). #rooted_source appends one
  # synthetic, RBS-typed call per public method so spinel's analyzer keeps
  # it and infers a concrete signature. `sp_lib_init` (see Pipeline's
  # lib_init) runs the renamed `main` once at load time, so the synthetic
  # calls must never actually execute -- `cr_collect_calls` (spinel's
  # reachability walk) registers call names syntactically regardless of
  # surrounding control flow, so wrapping them in `if false` keeps them
  # reachable-for-typing but dead at runtime.
  #
  # The RBS subset parsed here is what suppify needs to type spinel's
  # top-level exports: `class Object ... def name: (T1, T2) -> R ... end`
  # (the same `class Object` convention spinel's own `--rbs` extractor uses
  # to target Ruby's top-level methods, which are Object instance methods
  # under the hood).
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
    }.freeze

    DEF_RE = /\A\s*def\s+([A-Za-z_]\w*[?!]?)\s*:\s*\(([^)]*)\)\s*->\s*(\S+)/

    def initialize(ruby_source, rbs_source: nil)
      @ruby_source = ruby_source
      @rbs_source = rbs_source
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

    # The Ruby source spinel compiles: unchanged when nothing is exported,
    # otherwise the original plus the dead-but-visible root-call block.
    def rooted_source
      return @ruby_source if public_methods.empty?

      sigs = rbs_signatures
      missing = public_methods - sigs.keys
      unless missing.empty?
        raise Error, "no RBS signature for public method(s): #{missing.join(', ')} " \
                     "(declare under `class Object` in the sidecar .rbs)"
      end

      calls = public_methods.map { |m| root_call(m, sigs[m]) }
      @ruby_source + "\nif false\n" + calls.map { |c| "  #{c}" }.join("\n") + "\nend\n"
    end

    private

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

    def rbs_signatures
      sigs = {}
      in_object = false
      @rbs_source.to_s.each_line do |line|
        if line =~ /\A\s*class\s+Object\b/
          in_object = true
        elsif in_object && line =~ /\A\s*end\s*\z/
          in_object = false
        elsif in_object && (m = DEF_RE.match(line))
          params = m[2].strip.empty? ? [] : m[2].split(",").map(&:strip)
          sigs[m[1]] = { params: params, ret: m[3].strip }
        end
      end
      sigs
    end

    def root_call(name, sig)
      args = sig[:params].map { |t| literal_for(t) }
      "#{name}(#{args.join(", ")})"
    end

    def literal_for(type_name)
      LITERALS.fetch(type_name) do
        raise Error, "RBS type not supported for root-call synthesis: #{type_name}"
      end
    end
  end

  class SpinelRunner
    # runner: callable(argv_array) -> [stdout_string, exit_status_int]
    # rbs_dir: directory of *.rbs sidecars fed to spinel's --rbs (advisory
    # type seeding; see Source#rooted_source for why suppify needs this).
    def initialize(spinel_bin: ENV["SPINEL"] || "spinel", runner: method(:shell), rbs_dir: nil)
      @spinel_bin = spinel_bin
      @runner = runner
      @rbs_dir = rbs_dir
    end

    # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
    # emit modes (the symbol-map path short-circuits before the C-output
    # branch), so the two artifacts require separate invocations.
    def emit(rb_path, c_path)
      symbols_path = c_path.sub(/\.c\z/, "") + ".symbols.json"
      rbs_args = @rbs_dir ? ["--rbs", @rbs_dir] : []
      run!([@spinel_bin, rb_path, *rbs_args, "-c", "-o", c_path])
      run!([@spinel_bin, rb_path, "--emit-symbol-map", "-o", symbols_path])
      { c_path: c_path, symbols_path: symbols_path }
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

  # Transforms spinel's output (generated C + symbol map) plus the original
  # Ruby into the neutral library: the export list, the library C source
  # (renamed main + appended trampolines/error API/init), and the neutral
  # header consumers include.
  class Pipeline
    MAIN_RE = /\bint\s+main\s*\(/

    def initialize(ruby_source:, c_source:, symbols_json:, lib_name:)
      @ruby_source = ruby_source
      @c_source    = c_source
      @cnames      = parse_symbols(symbols_json)
      @lib_name    = lib_name
    end

    def run
      exports = build_exports
      c = rename_main(@c_source)
      c = c + trampolines(exports)
      { exports: exports, c_source: c, header: header(exports) }
    end

    def build_exports
      Source.new(@ruby_source).public_methods.map do |ruby_name|
        cname = @cnames[ruby_name]
        next nil unless cname # public method spinel did not emit (e.g. unused) — skip
        sig = SignatureExtractor.extract(@c_source, cname)
        { "public" => ruby_name, "cname" => cname, "sig" => sig }
      end.compact
    end

    private

    def parse_symbols(json)
      data = JSON.parse(json)
      (data["symbols"] || []).each_with_object({}) { |e, h| h[e["ruby"]] = e["c"] }
    end

    # Renames the generated `int main(...)` entry to `static int sp__main(...)`
    # so lib_init can drive it and the library carries no `main` symbol.
    def rename_main(c_source)
      raise Error, "no `int main(` found" unless c_source.match?(MAIN_RE)
      c_source.sub(MAIN_RE, "static int sp__main(")
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
      exports.each { |e| out << trampoline(e) << "\n" }
      out << "int #{@lib_name}_error(void) { return g_suppi_err; }\n"
      out << "const char *#{@lib_name}_error_message(void) { return g_suppi_msg; }\n"
      out << str_len_bridge
      out << lib_init
      out
    end

    # Runs in each trampoline's setjmp handler (still at the armed stack level,
    # before disarm) to snapshot spinel's exception message — held at
    # sp_exc_msg[sp_exc_top - 1] — into a static buffer, then disarm + flag.
    # sp_exc_msg / sp_exc_top are file-static in this same TU.
    def capture
      <<~C

        static void suppi__capture(void) {
            const char *m = (sp_exc_top > 0 && sp_exc_msg[sp_exc_top - 1])
                          ? sp_exc_msg[sp_exc_top - 1] : "uncaught exception";
            strncpy(g_suppi_msgbuf, m, sizeof g_suppi_msgbuf - 1);
            g_suppi_msgbuf[sizeof g_suppi_msgbuf - 1] = 0;
            g_suppi_msg = g_suppi_msgbuf;
            sp_exc_disarm();
            g_suppi_err = 1;
        }
      C
    end

    def trampoline(e)
      sig  = e["sig"]
      ret  = NeutralType.map(sig.return_type)
      ps   = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n}" }
      plist = ps.empty? ? "void" : ps.join(", ")
      body = +"#{ret} #{e['public']}(#{plist}) {\n"
      body << "    g_suppi_err = 0;\n"
      body << "    jmp_buf jb;\n"
      # __attribute__((cleanup)) (what SP_GC_ROOT uses, see string_arg below)
      # never runs across a longjmp landing back at this setjmp -- it only
      # fires on normal scope exit. Snapshotting sp_gc_nroots here and
      # restoring it on the caught-exception path undoes any root left
      # dangling by an exception raised while a duped string was rooted;
      # once we've decided to abort the call nothing rooted during it matters.
      body << "    int sp_root_base = sp_gc_nroots;\n"
      body << (ret == "void" ? "    if (setjmp(jb)) { suppi__capture(); sp_gc_nroots = sp_root_base; return; }\n"
                              : "    if (setjmp(jb)) { suppi__capture(); sp_gc_nroots = sp_root_base; return 0; }\n")
      body << "    sp_exc_arm(jb);\n"
      args = sig.params.map { |t, n| string_arg(body, t, n) }.join(", ")
      if ret == "void"
        body << "    #{e['cname']}(#{args});\n"
        body << "    sp_exc_disarm();\n"
      else
        body << "    #{ret} r = #{e['cname']}(#{args});\n"
        body << "    sp_exc_disarm();\n"
        body << "    return r;\n"
      end
      body << "}\n"
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
    def string_arg(body, t, n)
      return n unless NeutralType.kind(t) == :string
      dup = "sp_dup_#{n}"
      body << "    const char *#{dup} = sp_str_dup_external(#{n}); SP_GC_ROOT(#{dup});\n"
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

    def lib_init
      <<~C
        void #{@lib_name}_init(void) {
            static int done = 0; if (done) return; done = 1;
            char *av[] = { (char *)"lib", 0 };
            sp__main(1, av);
        }
      C
    end

    def header(exports)
      guard = "#{@lib_name.upcase}_H"
      out = +"#ifndef #{guard}\n#define #{guard}\n\n#include <stdint.h>\n#include <stddef.h>\n\n"
      out << "void #{@lib_name}_init(void);\n"
      out << "int #{@lib_name}_error(void);\n"
      out << "const char *#{@lib_name}_error_message(void);\n"
      out << "size_t #{@lib_name}_str_len(const char *s);\n\n"
      exports.each do |e|
        sig = e["sig"]
        ret = NeutralType.map(sig.return_type)
        ps  = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n}" }
        plist = ps.empty? ? "void" : ps.join(", ")
        out << "#{ret} #{e['public']}(#{plist});\n"
      end
      out << "\n#endif\n"
      out
    end
  end
end
