# lib/suppify/trampoline.rb
require "suppify/neutral_type"

module Suppify
  # Renders the C block appended to the generated translation unit:
  # extern trampolines (with a per-call setjmp exception barrier), the error
  # query API, and <lib_name>_init.
  module Trampoline
    module_function

    # lib_name namespaces the handful of symbols this file exports with
    # external linkage (init/error/error_message) so two suppify libraries
    # linked into the same binary don't collide -- spinel's runtime state
    # (armed by sp_lib_init) is otherwise a set of process-wide globals meant
    # for exactly one generated program per binary. Internal statics
    # (g_suppi_err et al.) already have file-local linkage and need no
    # namespacing.
    def render(exports, lib_name)
      out = +"\n/* === suppify appended trampolines === */\n"
      out << "static int g_suppi_err = 0;\n"
      out << "static const char *g_suppi_msg = 0;\n"
      out << "static char g_suppi_msgbuf[256];\n"
      out << capture
      exports.each { |e| out << one(e) << "\n" }
      out << "int #{lib_name}_error(void) { return g_suppi_err; }\n"
      out << "const char *#{lib_name}_error_message(void) { return g_suppi_msg; }\n"
      # rb_str_new_cstr/mrb_str_new_cstr are strlen-based, silently truncating
      # a String return at its first embedded NUL. sp_str_byte_len recovers
      # spinel's own tracked byte length (from the string header, not
      # strlen), bridged here so a binding can size the Ruby string correctly.
      out << "size_t #{lib_name}_str_len(const char *s) { return sp_str_byte_len(s); }\n\n"
      out << lib_init(lib_name)
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

    def one(e)
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

    def lib_init(lib_name)
      <<~C
        void #{lib_name}_init(void) {
            static int done = 0; if (done) return; done = 1;
            char *av[] = { (char *)"lib", 0 };
            sp__main(1, av);
        }
      C
    end
  end
end
