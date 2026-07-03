# lib/suppify/neutral_type.rb
module Suppify
  # Maps spinel C types to neutral C types usable across a plain-C boundary.
  # Anything not in the table is non-neutral and raises.
  module NeutralType
    TABLE = {
      "mrb_int"       => "intptr_t",
      "double"        => "double",
      "mrb_float"     => "double",
      "const char *"  => "const char *",
      "char *"        => "char *",
      "bool"          => "int",
      "_Bool"         => "int",
      "mrb_bool"      => "int",
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

    # Classifies a C type into a marshalling category the language bindings
    # switch on. Raises (via map) on non-neutral types.
    KIND = {
      "intptr_t"     => :int,
      "double"       => :float,
      "const char *" => :string,
      "char *"       => :string,
      "int"          => :bool,
      "void"         => :void,
    }.freeze

    def kind(c_type)
      key = c_type.strip.gsub(/\s+/, " ")
      neutral = TABLE[key] || key # spinel type -> neutral, or already neutral
      KIND.fetch(neutral) { raise NonNeutralType, "non-neutral C type: #{c_type.inspect}" }
    end
  end
end
