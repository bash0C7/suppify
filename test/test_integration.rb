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
              addlib_init();
              printf("%ld\\n", (long)add(2, 3));
              printf("%.1f\\n", half(5.0));
              printf("%s\\n", greet("world"));
              printf("%d\\n", even(4));
              printf("%d\\n", even(3));
              /* strlen(nully()) would report 1 (truncated at the embedded
                 NUL); the str_len bridge recovers the real byte length. */
              printf("%zu\\n", addlib_str_len(nully()));
              /* A String argument is read up to its first NUL unless its byte length
                 was published for this call; the published length is consumed by it. */
              printf("%ld\\n", (long)blen("a\\0b"));
              addlib_set_arg_len(0, 3);
              printf("%ld\\n", (long)blen("a\\0b"));
              printf("%ld\\n", (long)blen("a\\0b"));
              addlib_set_arg_len(0, 3);
              addlib_set_arg_len(1, 2);
              printf("%zu\\n", addlib_str_len(cat("a\\0b", "\\0c")));
              boom();
              printf("%d\\n", addlib_error());
              return 0;
          }
        C
        # Self-contained: lib<name>.a bundles a per-library-namespaced copy of
        # the spinel runtime, so no separate -lspinel_rt is needed.
        ok = system("cc harness.c -I. -L. -laddlib #{SYS_LIBS} -o harness")
        assert ok, "harness failed to compile/link"
        out = `./harness`.strip.split("\n")
        assert_equal "5", out[0]
        assert_equal "2.5", out[1]
        assert_equal "hi, world", out[2]
        assert_equal "1", out[3]
        assert_equal "0", out[4]
        assert_equal "3", out[5]
        assert_equal "1", out[6]
        assert_equal "3", out[7]
        assert_equal "1", out[8]
        assert_equal "5", out[9]
        assert_equal "1", out[10]
      end
    end
  end
end
