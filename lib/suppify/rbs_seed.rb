# lib/suppify/rbs_seed.rb
module Suppify
  # Parses the small RBS subset suppify needs to type spinel's top-level
  # exports: `class Object ... def name: (T1, T2) -> R ... end` (the same
  # `class Object` convention spinel's own `--rbs` extractor uses to target
  # Ruby's top-level methods, which are Object instance methods under the
  # hood).
  module RbsSeed
    module_function

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

    def parse(source)
      sigs = {}
      in_object = false
      source.each_line do |line|
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

    def root_call_for(name, sig)
      args = sig[:params].map { |t| literal_for(t) }
      "#{name}(#{args.join(", ")})"
    end

    def literal_for(type_name)
      LITERALS.fetch(type_name) do
        raise Error, "RBS type not supported for root-call synthesis: #{type_name}"
      end
    end
  end
end
