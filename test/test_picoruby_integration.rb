require "test_helper"

class TestPicoRubyIntegration < Test::Unit::TestCase
  ROOT = ENV.fetch("PICORUBY_ROOT", "")
  FFI = File.expand_path("fixtures/ffi.rb", __dir__)
  HW = File.expand_path("fixtures/hw", __dir__)

  CALC_PROGRAM = <<~RUBY
    print Calc.add(2, 3), " ", Calc.half(5.0), " ", Calc.half(3), " ", Calc.greet("world"), " "
    print Calc.even?(4), " ", Calc.even?(3), " ", Calc.nully.bytesize, " ", Calc.blen("a\\0bc"), " "
    print Calc.ignore(1).inspect, " "
    begin; Calc.check(-1); rescue ArgumentError => e; print "ArgumentError:", e.message, " "; end
    begin; Calc.add("2", 3); rescue TypeError; print "TypeError "; end
    puts Calc.check(7)
  RUBY

  CALC_EXPECTED = "5 2.5 1.5 hi, world true false 3 4 nil ArgumentError:negative TypeError 7\n"

  VMS = {
    mruby: ["picoruby", <<~RB],
      conf.cc.defines << "MRB_INT64"
      conf.cc.defines << "MRB_NO_BOXING"
      conf.cc.defines << "MRB_UTF8_STRING"
      conf.picoruby(alloc_estalloc: false)
      conf.gembox "minimum"
      conf.gem core: "picoruby-bin-picoruby"
    RB
    mrubyc: ["femtoruby", <<~RB],
      conf.cc.defines << "PICORB_INT64"
      conf.cc.defines << "MRBC_TICK_UNIT=4"
      conf.cc.defines << "MRBC_TIMESLICE_TICK_COUNT=3"
      conf.cc.defines << "MRBC_USE_STRING_UTF8"
      conf.femtoruby
      conf.gembox "minimum"
      conf.gem core: "picoruby-require"
    RB
  }.freeze

  VMS.each do |vm, (bin, config)|
    define_method("test_the_gem_builds_into_#{vm}_and_runs") do
      run_gem(vm, bin, config, "calc", CALC_PROGRAM) { |dir| Fixtures.calc_gem(dir) }
    end

    define_method("test_a_kernel_s_ffi_settings_reach_the_#{vm}_build") do
      run_gem(vm, bin, config, "ffi", %(print Ffi.mag(4), " ", Ffi.mag(-2), "\\n"), expected: "43 -17\n") do |dir|
        system("cc", "-DHW_BOARD=3", "-I#{HW}", "-c", "#{HW}/hw.c", "-o", "#{dir}/hw.o", exception: true)
        system("ar", "rcs", "#{dir}/libhw.a", "#{dir}/hw.o", exception: true)
        Suppify::CLI.run([FFI, "Ffi.mag", "-d", dir], spinel: Suppify::Spinel.new(bin: Fixtures.spinel))
        File.join(dir, "picoruby-ffi")
      end
    end
  end

  # Builds PicoRuby for +vm+ with the gem the block writes into a temporary directory,
  # then runs +program+ on it (after `require "<name>"` on mruby/c).
  #: (Symbol, String, String, String, String, ?expected: String) { (String) -> String } -> void
  def run_gem(vm, bin, config, name, program, expected: CALC_EXPECTED)
    omit("spinel, cc and PICORUBY_ROOT are required") if Fixtures.spinel.empty? || Fixtures.which("cc").empty? || !File.exist?(File.join(ROOT, "Rakefile"))
    Dir.mktmpdir do |dir|
      gem = nil
      capture_output { gem = yield(dir) }
      File.write("#{dir}/build.rb", <<~RB)
        MRuby::Build.new do |conf|
          conf.toolchain
          conf.cc.defines << "PICORB_PLATFORM_POSIX"
        #{config.gsub(/^/, '  ')}  conf.linker.library_paths << #{dir.inspect}
          conf.gem gemdir: #{gem.inspect}
        end
      RB
      out, status = Open3.capture2e({ "MRUBY_CONFIG" => "#{dir}/build.rb", "MRUBY_BUILD_DIR" => "#{dir}/build" },
                                    RbConfig.ruby, Gem.bin_path("rake", "rake"), "-j8", chdir: ROOT)
      assert status.success?, out.lines.last(30).join
      File.write("#{dir}/prog.rb", (vm == :mrubyc ? %(require "#{name}"\n) : "") + program)
      out, = Open3.capture2e("#{dir}/build/host/bin/#{bin}", "#{dir}/prog.rb")
      assert_equal expected, out
    end
  end
end
