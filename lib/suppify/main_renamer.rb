# lib/suppify/main_renamer.rb
module Suppify
  # Renames the generated `int main(...)` entry to `static int sp__main(...)`
  # so sp_lib_init can drive it and the library carries no `main` symbol.
  module MainRenamer
    RE = /\bint\s+main\s*\(/

    module_function

    def rename(c_source)
      raise Error, "no `int main(` found" unless c_source.match?(RE)
      c_source.sub(RE, "static int sp__main(")
    end
  end
end
