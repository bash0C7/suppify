# lib/suppify.rb
module Suppify
  class Error < StandardError; end
  class NonNeutralType < Error; end
end
require "suppify/json_parser"
