require "test_helper"
require "suppify/cli"
require "fileutils"
require "tmpdir"
require "rbconfig"

# Swift/PicoRuby/ESP32 integration is out of scope for now (design doc §2
# non-goals); a Ruby native extension is a stand-in that exercises the same
# plain-C-ABI contract suppify promises (§7) via a real, independent build
# toolchain (mkmf) instead of a hand-rolled C harness.
class TestRubyExtIntegration < Test::Unit::TestCase
  def spinel_available?
    !`which spinel`.strip.empty?
  rescue StandardError
    false
  end

  def test_callable_from_ruby_native_extension
    omit("spinel not on PATH") unless spinel_available?

    Dir.mktmpdir do |dir|
      rb = File.join(dir, "add.rb")
      FileUtils.cp(File.expand_path("fixtures/add.rb", __dir__), rb)
      FileUtils.cp(File.expand_path("fixtures/add.rbs", __dir__), File.join(dir, "add.rbs"))

      Dir.chdir(dir) do
        assert_equal 0, Suppify::CLI.run([rb, "-o", "addlib"])

        # Deliberately does not include any spinel header: addlib.h is the
        # neutral header (§7), so a consumer only ever sees plain C types.
        File.write("ext_suppify.c", <<~C)
          #include "ruby.h"
          #include "addlib.h"

          static VALUE rb_add(VALUE self, VALUE a, VALUE b) {
              return LONG2NUM(add(NUM2LONG(a), NUM2LONG(b)));
          }
          static VALUE rb_half(VALUE self, VALUE x) {
              return DBL2NUM(half(NUM2DBL(x)));
          }
          static VALUE rb_greet(VALUE self, VALUE name) {
              return rb_str_new_cstr(greet(StringValueCStr(name)));
          }
          static VALUE rb_even(VALUE self, VALUE n) {
              return even(NUM2LONG(n)) ? Qtrue : Qfalse;
          }
          static VALUE rb_boom_error(VALUE self) {
              boom();
              return INT2NUM(suppi_error());
          }

          void Init_ext_suppify(void) {
              sp_lib_init();
              VALUE mod = rb_define_module("ExtSuppify");
              rb_define_module_function(mod, "add", rb_add, 2);
              rb_define_module_function(mod, "half", rb_half, 1);
              rb_define_module_function(mod, "greet", rb_greet, 1);
              rb_define_module_function(mod, "even", rb_even, 1);
              rb_define_module_function(mod, "boom_error", rb_boom_error, 0);
          }
        C

        File.write("extconf.rb", <<~RUBY)
          require "mkmf"
          $LDFLAGS << " -L."
          $LIBS << " -laddlib -lspinel_rt -lm"
          create_makefile("ext_suppify")
        RUBY

        assert system(RbConfig.ruby, "extconf.rb", out: File::NULL), "extconf.rb failed"
        assert system("make", out: File::NULL), "make failed"

        ext_path = Dir.glob("ext_suppify.{so,bundle}").first
        assert ext_path, "extension binary not built"
        require File.expand_path(ext_path)

        assert_equal 5, ExtSuppify.add(2, 3)
        assert_equal 2.5, ExtSuppify.half(5.0)
        assert_equal "hi, world", ExtSuppify.greet("world")
        assert_equal true, ExtSuppify.even(4)
        assert_equal false, ExtSuppify.even(3)
        assert_equal 1, ExtSuppify.boom_error
      end
    end
  end
end
