# lib/suppify.rb — namespace, shared errors, and the four layer files:
# core (Ruby+.rbs → neutral C), bindings (per-VM wrappers), package
# (per-target artifact assembly), cli.
module Suppify
  class Error < StandardError; end
  class NonNeutralType < Error; end

  # The name given to spinel's --ext-init: the kernel's init function is
  # <name>() and its exception frame <name>_try. Derived from the library
  # name, so two libraries in one binary never share it.
  def self.kernel_init_name(lib_name) = "#{lib_name}_spinel"
end
require "suppify/core"
require "suppify/bindings"
require "suppify/package"
require "suppify/cli"
