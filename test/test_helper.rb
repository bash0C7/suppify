# test/test_helper.rb
require "test/unit"
require "suppify"

# System libraries a driver links against the generated library: libm, plus
# libcrypt on Linux, where glibc keeps crypt(3) (String#crypt) outside libc.
SYS_LIBS = RbConfig::CONFIG["host_os"].include?("linux") ? "-lm -lcrypt" : "-lm"
