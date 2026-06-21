# lib/suppify/pipeline.rb
require "suppify/symbol_map"
require "suppify/visibility"
require "suppify/signature"
require "suppify/trampoline"
require "suppify/main_renamer"
require "suppify/header"

module Suppify
  class Pipeline
    def initialize(ruby_source:, c_source:, symbols_json:, lib_name:)
      @ruby_source = ruby_source
      @c_source    = c_source
      @symbols     = SymbolMap.from_json(symbols_json)
      @lib_name    = lib_name
    end

    def run
      exports = build_exports
      c = MainRenamer.rename(@c_source)
      c = c + Trampoline.render(exports)
      header = Header.render(@lib_name, exports)
      { exports: exports, c_source: c, header: header }
    end

    def build_exports
      Visibility.public_methods(@ruby_source).map do |ruby_name|
        cname = @symbols.cname_for(ruby_name)
        next nil unless cname # public method spinel did not emit (e.g. unused) — skip
        sig = SignatureExtractor.extract(@c_source, cname)
        # Force neutral-type validation now so a non-neutral public method errors.
        NeutralType.map(sig.return_type)
        sig.params.each { |t, _| NeutralType.map(t) }
        { "public" => ruby_name, "cname" => cname, "sig" => sig }
      end.compact
    end
  end
end
