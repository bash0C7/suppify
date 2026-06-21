# lib/suppify/visibility.rb
require "prism"

module Suppify
  # Computes the set of public top-level method names from Ruby source via
  # prism's static AST. Handles: bare `private`/`public` (flips subsequent
  # defs), `private def foo`, and `private :foo` / `public :foo`.
  module Visibility
    module_function

    def public_methods(source)
      program = Prism.parse(source).value
      body = program.statements.body
      mode = :public          # current default visibility
      vis  = {}               # name(String) => :public/:private (explicit wins)
      order = []

      body.each do |node|
        case node
        when Prism::DefNode
          name = node.name.to_s
          order << name unless vis.key?(name) || order.include?(name)
          vis[name] ||= mode
        when Prism::CallNode
          handle_call(node, mode_setter: ->(m) { mode = m }, vis: vis, order: order)
        end
      end

      order.select { |n| (vis[n] || :public) == :public }
    end

    # @api private
    def handle_call(node, mode_setter:, vis:, order:)
      mname = node.name
      return unless mname == :private || mname == :public
      args = node.arguments&.arguments || []

      if args.empty?
        mode_setter.call(mname)                 # bare `private` / `public`
        return
      end

      args.each do |arg|
        case arg
        when Prism::DefNode                      # `private def foo`
          n = arg.name.to_s
          order << n unless order.include?(n)
          vis[n] = mname
        when Prism::SymbolNode                   # `private :foo`
          n = arg.unescaped
          order << n unless order.include?(n)
          vis[n] = mname
        end
      end
    end
  end
end
