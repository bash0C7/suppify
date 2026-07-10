# lib/suppify.rb — namespace, shared errors, and the four layer files:
# core (Ruby+.rbs → neutral C), bindings (per-VM wrappers), package
# (per-target artifact assembly), cli.
module Suppify
  class Error < StandardError; end
  class NonNeutralType < Error; end
end
require "suppify/core"
require "suppify/bindings"
require "suppify/package"
require "suppify/cli"
