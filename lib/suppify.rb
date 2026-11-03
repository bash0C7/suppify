# Packs a spinel-compiled Ruby kernel as a PicoRuby mrbgem, for the mruby and mruby/c VMs.
module Suppify
  class Error < StandardError; end
end

require "suppify/spinel"
require "suppify/glue"
require "suppify/binding"
require "suppify/mrbgem"
require "suppify/cli"
