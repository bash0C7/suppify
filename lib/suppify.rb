# lib/suppify.rb
module Suppify
  class Error < StandardError; end
  class NonNeutralType < Error; end
end
require "suppify/signature"
require "suppify/json_parser"
require "suppify/symbol_map"
require "suppify/visibility"
