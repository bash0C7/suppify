# lib/suppify.rb
module Suppify
  class Error < StandardError; end
  class NonNeutralType < Error; end
end
require "suppify/neutral_type"
require "suppify/signature"
require "suppify/json_parser"
require "suppify/symbol_map"
require "suppify/visibility"
require "suppify/trampoline"
require "suppify/main_renamer"
require "suppify/header"
require "suppify/pipeline"
require "suppify/spinel_runner"
require "suppify/builder"
require "suppify/cli"
