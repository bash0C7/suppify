# lib/suppify/root_injector.rb
require "suppify/rbs_seed"

module Suppify
  # spinel's whole-program reachability analysis DCEs any top-level method
  # with no call site, regardless of visibility -- which is fatal for
  # suppify's premise (public methods are exported precisely because nothing
  # in the program calls them). This appends one synthetic, RBS-typed call
  # per public method so spinel's analyzer keeps it and infers a concrete
  # signature. `sp_lib_init` (Trampoline#lib_init) runs the renamed `main`
  # once at load time, so the synthetic calls must never actually execute --
  # `cr_collect_calls` (spinel's reachability walk) registers call names
  # syntactically regardless of surrounding control flow, so wrapping them in
  # `if false` keeps them reachable-for-typing but dead at runtime.
  module RootInjector
    module_function

    def inject(ruby_source, public_methods, rbs_sigs)
      missing = public_methods - rbs_sigs.keys
      unless missing.empty?
        raise Error, "no RBS signature for public method(s): #{missing.join(', ')} " \
                     "(declare under `class Object` in the sidecar .rbs)"
      end

      calls = public_methods.map { |m| RbsSeed.root_call_for(m, rbs_sigs[m]) }
      ruby_source + "\nif false\n" + calls.map { |c| "  #{c}" }.join("\n") + "\nend\n"
    end
  end
end
