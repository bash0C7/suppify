# lib/suppify/header.rb
require "suppify/neutral_type"

module Suppify
  module Header
    module_function

    def render(lib_name, exports)
      guard = "#{lib_name.upcase}_H"
      out = +"#ifndef #{guard}\n#define #{guard}\n\n#include <stdint.h>\n#include <stddef.h>\n\n"
      out << "void #{lib_name}_init(void);\n"
      out << "int #{lib_name}_error(void);\n"
      out << "const char *#{lib_name}_error_message(void);\n"
      out << "size_t #{lib_name}_str_len(const char *s);\n\n"
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
