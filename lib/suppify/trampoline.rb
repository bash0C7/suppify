# lib/suppify/trampoline.rb
require "suppify/neutral_type"

module Suppify
  # Renders the C block appended to the generated translation unit:
  # extern trampolines (with a per-call setjmp exception barrier), the error
  # query API, and sp_lib_init.
  module Trampoline
    module_function

    def render(exports)
      out = +"\n/* === suppify appended trampolines === */\n"
      out << "static int g_suppi_err = 0;\n"
      out << "static const char *g_suppi_msg = 0;\n\n"
      exports.each { |e| out << one(e) << "\n" }
      out << "int suppi_error(void) { return g_suppi_err; }\n"
      out << "const char *suppi_error_message(void) { return g_suppi_msg; }\n\n"
      out << lib_init
      out
    end

    def one(e)
      sig  = e["sig"]
      ret  = NeutralType.map(sig.return_type)
      ps   = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n}" }
      plist = ps.empty? ? "void" : ps.join(", ")
      args  = sig.params.map { |_, n| n }.join(", ")
      body = +"#{ret} #{e['public']}(#{plist}) {\n"
      body << "    jmp_buf jb;\n"
      if ret == "void"
        body << "    if (setjmp(jb)) { sp_exc_disarm(); g_suppi_err = 1; return; }\n"
        body << "    sp_exc_arm(jb);\n"
        body << "    #{e['cname']}(#{args});\n"
        body << "    sp_exc_disarm();\n"
      else
        body << "    if (setjmp(jb)) { sp_exc_disarm(); g_suppi_err = 1; return 0; }\n"
        body << "    sp_exc_arm(jb);\n"
        body << "    return #{e['cname']}(#{args});\n"
      end
      body << "}\n"
      body
    end

    def lib_init
      <<~C
        void sp_lib_init(void) {
            static int done = 0; if (done) return; done = 1;
            char *av[] = { "lib", 0 };
            sp__main(1, av);
        }
      C
    end
  end
end
