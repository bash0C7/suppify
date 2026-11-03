require "base64"

module Hw
  ffi_lib "hw"
  ffi_cflags "-I" + File.expand_path("hw", __dir__)
  ffi_cflags "-DHW_BOARD=3"
  ffi_source <<~C
    #include "hw.h"
    intptr_t hw_board_scale(intptr_t n) { return hw_scale(n) + HW_BOARD; }
  C
  ffi_func :hw_board_scale, [:long], :long
end

module Native
  #: (Integer) -> Integer
  def self.mag(n) = Hw.hw_board_scale(n)

  #: (String) -> String
  def self.b64(s) = Base64.strict_encode64(s)
end
