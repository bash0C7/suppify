# test/test_two_libraries_integration.rb -- two suppify libraries linked into
# one binary and driven from two threads at once. Each library carries its own
# copy of spinel's runtime state plus its own --ext-init kernel (init, the
# <kernel>_try exception frame, the wrapper module's entries, the symbol
# lookups); all of it must be namespaced per library for this to link and for
# a raise or a collection in one library to leave the other alone.
require "test_helper"
require "suppify/cli"
require "fileutils"
require "tmpdir"

class TestTwoLibrariesIntegration < Test::Unit::TestCase
  KA = <<~RUBY
    #: (Integer) -> Integer
    def dbl(x)
      x * 2
    end

    #: (Integer) -> Integer
    def fsum(n)
      f = Fiber.new do
        i = 1
        while i <= n
          Fiber.yield i
          i += 1
        end
        0
      end
      s = 0
      k = 0
      while k < n
        s += f.resume
        k += 1
      end
      s
    end

    #: (Integer) -> String
    def label(x)
      "ka-" + x.to_s + "-" + (:tag).to_s
    end
  RUBY

  KB = <<~RUBY
    #: (Integer) -> Integer
    def triple(x)
      raise ArgumentError, "kb rejects " + x.to_s if x < 0
      x * 3
    end

    #: (Array[Integer]) -> Integer
    def total(xs)
      xs.sum
    end
  RUBY

  DRIVER = <<~C
    #include "ka.h"
    #include "kb.h"
    #include <pthread.h>
    #include <stdio.h>
    #include <string.h>

    static int fails = 0;
    static void check(int ok, const char *what) { if (!ok) { fails++; printf("FAIL %s\\n", what); } }

    static void *run_a(void *arg) {
        uint8_t out[64]; int i;
        (void)arg;
        ka_init();
        for (i = 0; i < 2000; i++) {
            static const uint8_t in[] = { 0x91, 0x15 };            /* [21] */
            static const uint8_t four[] = { 0x91, 0x04 };          /* [4] */
            int32_t n = ka_dbl_call(in, 2, out, sizeof out);
            check(n == 1 && out[0] == 0x2a, "ka dbl");
            n = ka_label_call(in, 2, out, sizeof out);
            check(n > 0 && out[0] == 0xa9 && memcmp(out + 1, "ka-21-tag", 9) == 0, "ka label");
            n = ka_fsum_call(four, 2, out, sizeof out);
            check(n == 1 && out[0] == 10, "ka fiber");
        }
        return 0;
    }

    static void *run_b(void *arg) {
        uint8_t out[64]; int i;
        (void)arg;
        kb_init();
        for (i = 0; i < 2000; i++) {
            static const uint8_t ok[] = { 0x91, 0x07 };            /* [7] */
            static const uint8_t bad[] = { 0x91, 0xff };           /* [-1] */
            static const uint8_t arr[] = { 0x91, 0x93, 1, 2, 3 };  /* [[1,2,3]] */
            int32_t n = kb_triple_call(ok, 2, out, sizeof out);
            check(n == 1 && out[0] == 21, "kb triple");
            n = kb_triple_call(bad, 2, out, sizeof out);
            check(n == KB_E_RAISED && kb_error() == 1 &&
                  strcmp(kb_error_message(), "kb rejects -1") == 0, "kb raise");
            n = kb_triple_call(ok, 2, out, sizeof out);
            check(n == 1 && kb_error() == 0, "kb error flag cleared by the next call");
            n = kb_total_call(arr, 5, out, sizeof out);
            check(n == 1 && out[0] == 6, "kb total");
        }
        return 0;
    }

    int main(void) {
        pthread_t ta, tb;
        pthread_create(&ta, 0, run_a, 0);
        pthread_create(&tb, 0, run_b, 0);
        pthread_join(ta, 0);
        pthread_join(tb, 0);
        printf(fails ? "FAILED\\n" : "OK\\n");
        return fails != 0;
    }
  C

  def spinel_available?
    !`which spinel`.strip.empty?
  rescue StandardError
    false
  end

  def defined_globals(archive)
    IO.popen(["nm", "-g", "--defined-only", archive], err: File::NULL, &:read).lines
      .filter_map { |l| l.split[2]&.sub(/\A_/, "") }
  end

  # Nothing external is defined by both archives: every runtime and kernel
  # symbol is per library, sp_ctx_swap (an asm-string symbol) included.
  def test_two_libraries_share_no_global_symbol
    omit("spinel not on PATH") unless spinel_available?
    Dir.mktmpdir("suppify-two-") do |dir|
      build(dir)
      shared = defined_globals(File.join(dir, "libka.a")) & defined_globals(File.join(dir, "libkb.a"))
      assert_equal [], shared
      assert_includes defined_globals(File.join(dir, "libka.a")), "ka_sp_ctx_swap"
    end
  end

  # The two libraries linked into one binary and run from two threads at
  # once, with no object-file surgery; ka also switches a real Fiber.
  def test_two_libraries_link_and_run_side_by_side_in_two_threads
    omit("spinel not on PATH") unless spinel_available?
    Dir.mktmpdir("suppify-two-") do |dir|
      build(dir)
      Dir.chdir(dir) do
        assert system("cc driver.c -I. -L. -lka -lkb -lm -lpthread -o driver 2>link.log"),
               "the two libraries must link into one binary:\n#{File.read('link.log')}"
        assert_equal "OK\n", `./driver`
      end
    end
  end

  def build(dir)
    File.write(File.join(dir, "ka.rb"), KA)
    File.write(File.join(dir, "kb.rb"), KB)
    File.write(File.join(dir, "driver.c"), DRIVER)
    Dir.chdir(dir) do
      Suppify::CLI.run(["ka.rb", "-o", "ka"])
      Suppify::CLI.run(["kb.rb", "-o", "kb"])
    end
  end
end
