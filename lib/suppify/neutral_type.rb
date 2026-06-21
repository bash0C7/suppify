# lib/suppify/neutral_type.rb
module Suppify
  # Maps spinel C types to neutral C types usable across a plain-C boundary.
  # Anything not in the table is non-neutral and raises.
  module NeutralType
    TABLE = {
      "mrb_int"       => "intptr_t",
      "double"        => "double",
      "const char *"  => "const char *",
      "char *"        => "char *",
      "bool"          => "int",
      "_Bool"         => "int",
      "void"          => "void",
    }.freeze

    module_function

    def map(c_type)
      key = c_type.strip.gsub(/\s+/, " ")
      TABLE[key] or raise NonNeutralType, "non-neutral C type: #{c_type.inspect}"
    end

    def neutral?(c_type)
      map(c_type)
      true
    rescue NonNeutralType
      false
    end
  end
end
