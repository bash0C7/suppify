# test/test_error_class_integration.rb -- <lib>_error_class() beside
# <lib>_error_message(): a kernel raising a custom exception class and one
# raising a builtin are compiled by real spinel, and the generated C (the
# text every target -- c, cruby, picoruby -- compiles) is called from a C
# driver. Both accessors are copied into the library's own buffers, valid
# until the next call, and empty when the last call did not raise.
require "test_helper"
require "suppify/cli"
require "fileutils"
require "tmpdir"

class TestErrorClassIntegration < Test::Unit::TestCase
  KERNEL = <<~RUBY
    class KernelError < StandardError
    end

    #: (Integer) -> Integer
    def custom(x)
      raise KernelError, "custom " + x.to_s if x < 0
      x
    end

    #: (Integer) -> Integer
    def builtin(x)
      raise ArgumentError, "bad thing" if x < 0
      x
    end

    #: (Integer) -> Integer
    def plain(x)
      x
    end
  RUBY

  DRIVER = <<~C
    #include "errlib.h"
    #include <stdio.h>

    static void show(const char *what, int32_t rc) {
        printf("%s rc=%d err=%d class=[%s] msg=[%s]\\n", what, rc, errlib_error(),
               errlib_error_class(),
               errlib_error_message() ? errlib_error_message() : "");
    }

    int main(void) {
        uint8_t out[64];
        static const uint8_t neg[] = { 0x91, 0xff };
        static const uint8_t pos[] = { 0x91, 0x02 };
        errlib_init();
        show("start", 0);
        show("custom", errlib_custom_call(neg, 2, out, sizeof out));
        show("builtin", errlib_builtin_call(neg, 2, out, sizeof out));
        show("scalar", (builtin(-1), 0));
        show("ok", errlib_plain_call(pos, 2, out, sizeof out));
        return 0;
    }
  C

  def spinel_available?
    !`which spinel`.strip.empty?
  rescue StandardError
    false
  end

  def test_error_class_and_message_for_custom_and_builtin_exceptions
    omit("spinel not on PATH") unless spinel_available?
    Dir.mktmpdir("suppify-errclass-") do |dir|
      File.write(File.join(dir, "errkernel.rb"), KERNEL)
      File.write(File.join(dir, "driver.c"), DRIVER)
      Dir.chdir(dir) do
        Suppify::CLI.run(["errkernel.rb", "-o", "errlib"])
        assert system("cc driver.c -I. -L. -lerrlib -lm -o driver 2>link.log"), File.read("link.log")
        lines = `./driver`.lines.map(&:chomp)
        assert_equal "start rc=0 err=0 class=[] msg=[]", lines[0]
        assert_equal "custom rc=-3 err=1 class=[KernelError] msg=[custom -1]", lines[1]
        assert_equal "builtin rc=-3 err=1 class=[ArgumentError] msg=[bad thing]", lines[2]
        assert_equal "scalar rc=0 err=1 class=[ArgumentError] msg=[bad thing]", lines[3]
        # after a clean call the class is empty; the message keeps its
        # existing behaviour (the last captured text stays readable)
        assert_equal "ok rc=1 err=0 class=[] msg=[bad thing]", lines[4]
      end
    end
  end
end
