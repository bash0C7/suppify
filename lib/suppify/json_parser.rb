# lib/suppify/json_parser.rb
module Suppify
  # Minimal recursive-descent JSON parser. No JSON.parse (unavailable under
  # spinel). Handles the subset spinel emits: objects, arrays, strings,
  # integers, floats, true/false/null.
  module JSONParser
    module_function

    def parse(str)
      @s = str
      @i = 0
      v = parse_value
      skip_ws
      raise Error, "trailing data at #{@i}" if @i < @s.length
      v
    end

    def parse_value
      skip_ws
      c = @s[@i]
      case c
      when "{" then parse_object
      when "[" then parse_array
      when '"' then parse_string
      when "t" then expect("true");  true
      when "f" then expect("false"); false
      when "n" then expect("null");  nil
      else parse_number
      end
    end

    def parse_object
      @i += 1 # {
      obj = {}
      skip_ws
      if @s[@i] == "}" then @i += 1; return obj end
      loop do
        skip_ws
        key = parse_string
        skip_ws
        raise Error, "expected ':'" unless @s[@i] == ":"
        @i += 1
        obj[key] = parse_value
        skip_ws
        ch = @s[@i]; @i += 1
        break if ch == "}"
        raise Error, "expected ',' or '}'" unless ch == ","
      end
      obj
    end

    def parse_array
      @i += 1 # [
      arr = []
      skip_ws
      if @s[@i] == "]" then @i += 1; return arr end
      loop do
        arr << parse_value
        skip_ws
        ch = @s[@i]; @i += 1
        break if ch == "]"
        raise Error, "expected ',' or ']'" unless ch == ","
      end
      arr
    end

    def parse_string
      raise Error, "expected string" unless @s[@i] == '"'
      @i += 1
      out = +""
      while (c = @s[@i])
        @i += 1
        case c
        when '"' then return out
        when "\\"
          e = @s[@i]; @i += 1
          out << case e
                 when '"' then '"'
                 when "\\" then "\\"
                 when "/" then "/"
                 when "n" then "\n"
                 when "t" then "\t"
                 when "r" then "\r"
                 when "b" then "\b"
                 when "f" then "\f"
                 else e
                 end
        else out << c
        end
      end
      raise Error, "unterminated string"
    end

    def parse_number
      start = @i
      @i += 1 while @s[@i] && "+-0123456789.eE".include?(@s[@i])
      tok = @s[start...@i]
      raise Error, "bad number at #{start}" if tok.empty?
      tok.include?(".") || tok.include?("e") || tok.include?("E") ? tok.to_f : tok.to_i
    end

    def expect(word)
      raise Error, "expected #{word}" unless @s[@i, word.length] == word
      @i += word.length
    end

    def skip_ws
      @i += 1 while @s[@i] && " \t\n\r".include?(@s[@i])
    end
  end
end
