# lib/suppify/signature.rb
module Suppify
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
end
