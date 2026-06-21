# lib/suppify/symbol_map.rb
require "suppify/json_parser"

module Suppify
  class SymbolMap
    def self.from_json(str)
      data = JSONParser.parse(str)
      new(data["symbols"] || [])
    end

    def initialize(entries)
      @by_ruby = {}
      entries.each { |e| @by_ruby[e["ruby"]] = e }
    end

    def cname_for(ruby_name)
      e = @by_ruby[ruby_name]
      e && e["c"]
    end

    def kind_for(ruby_name)
      e = @by_ruby[ruby_name]
      e && e["kind"]
    end
  end
end
