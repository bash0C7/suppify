require "test_helper"
require "suppify/cli"
require "fileutils"
require "tmpdir"

class TestIntegration < Test::Unit::TestCase
  def spinel_available?
    !`which spinel`.strip.empty?
  rescue StandardError
    false
  end

  def test_end_to_end_build_and_call
    omit("spinel not on PATH") unless spinel_available?

    Dir.mktmpdir do |dir|
      rb = File.join(dir, "add.rb")
      FileUtils.cp(File.expand_path("fixtures/add.rb", __dir__), rb)
      FileUtils.cp(File.expand_path("fixtures/add.rbs", __dir__), File.join(dir, "add.rbs"))

      Dir.chdir(dir) do
        assert_equal 0, Suppify::CLI.run([rb, "-o", "addlib"])

        # Exercises every neutral type suppify claims to support (Integer,
        # Float, String, bool, void+exception) -- not just Integer, so this
        # is evidence of general usability rather than one lucky type.
        File.write("harness.c", <<~C)
          #include "addlib.h"
          #include <stdio.h>
          int main(void){
              sp_lib_init();
              printf("%ld\\n", (long)add(2, 3));
              printf("%.1f\\n", half(5.0));
              printf("%s\\n", greet("world"));
              printf("%d\\n", even(4));
              printf("%d\\n", even(3));
              boom();
              printf("%d\\n", suppi_error());
              return 0;
          }
        C
        spinel_lib = ENV["SPINEL_LIB"] || `dirname $(dirname $(which spinel))`.strip + "/lib"
        ok = system("cc harness.c -I. -I#{spinel_lib} -L. -laddlib -lspinel_rt -lm -o harness")
        assert ok, "harness failed to compile/link"
        out = `./harness`.strip.split("\n")
        assert_equal "5", out[0]
        assert_equal "2.5", out[1]
        assert_equal "hi, world", out[2]
        assert_equal "1", out[3]
        assert_equal "0", out[4]
        assert_equal "1", out[5]
      end
    end
  end
end
