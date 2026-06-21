# lib/suppify/header.rb
require "suppify/neutral_type"

module Suppify
  module Header
    module_function

    def render(lib_name, exports)
      guard = "#{lib_name.upcase}_H"
      out = +"#ifndef #{guard}\n#define #{guard}\n\n#include <stdint.h>\n\n"
      out << "void sp_lib_init(void);\n"
      out << "int suppi_error(void);\n"
      out << "const char *suppi_error_message(void);\n\n"
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
