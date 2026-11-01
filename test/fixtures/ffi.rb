module Hw
  ffi_lib "m"
  ffi_cflags "-DHW_BOARD=1"
  ffi_func :labs, [:long], :long
end

module Ffi
  #: (Integer) -> Integer
  def self.mag(n) = Hw.labs(n)
end
