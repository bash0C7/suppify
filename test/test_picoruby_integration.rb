require "test_helper"

class TestPicoRubyIntegration < Test::Unit::TestCase
  ROOT = ENV.fetch("PICORUBY_ROOT", "")
  NATIVE = File.expand_path("fixtures/native.rb", __dir__)
  HW = File.expand_path("fixtures/hw", __dir__)
  INSTANCES_HOST = File.expand_path("fixtures/instances_host.c", __dir__)

  CALC_PROGRAM = <<~RUBY
    print Calc.add(2, 3), " ", Calc.half(5.0), " ", Calc.half(3), " ", Calc.greet("world"), " "
    print Calc.even?(4), " ", Calc.even?(3), " ", Calc.nully.bytesize, " ", Calc.blen("a\\0bc"), " "
    print Calc.ignore(1).inspect, " "
    begin; Calc.check(-1); rescue ArgumentError => e; print "ArgumentError:", e.message, " "; end
    begin; Calc.add("2", 3); rescue TypeError; print "TypeError "; end
    begin; Calc.add(2.7, 1); rescue TypeError; print "TypeError "; end
    puts Calc.check(7)
  RUBY

  CALC_EXPECTED = "5 2.5 1.5 hi, world true false 3 4 nil ArgumentError:negative TypeError TypeError 7\n"

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

    define_method("test_a_kernel_s_c_dependencies_reach_the_#{vm}_build") do
      run_gem(vm, bin, config, "native", %(print Native.mag(4), " ", Native.mag(-2), " ", Native.b64("hi"), "\n"), expected: "43 -17 aGk=\n") do |dir|
        system("cc", "-DHW_BOARD=3", "-I#{HW}", "-c", "#{HW}/hw.c", "-o", "#{dir}/hw.o", exception: true)
        system("ar", "rcs", "#{dir}/libhw.a", "#{dir}/hw.o", exception: true)
        Suppify::CLI.run([NATIVE, "Native.mag", "Native.b64", "-d", dir], spinel: Suppify::Spinel.new(bin: Fixtures.spinel))
        File.join(dir, "picoruby-native")
      end
    end
  end

  def test_the_vm_and_a_worker_run_one_kernel_at_once
    instances = lambda do |dir|
      gem = "#{dir}/picoruby-calc"
      libs = RbConfig::CONFIG["host_os"].include?("linux") ? %w[-lm -lcrypt] : %w[-lm]
      out, status = Open3.capture2e("cc", "-O1", "-pthread", "-I#{gem}/include", INSTANCES_HOST, "#{dir}/build/host/lib/libmruby.a",
                                    *libs, "-o", "#{dir}/instances")
      assert status.success?, out
      out, = Open3.capture2e("#{dir}/instances")
      assert_equal "bad 0 0\n", out
    end
    run_gem(:mruby, *VMS[:mruby], "calc", %(print Calc.greet("vm"), "\\n"), expected: "hi, vm\n", check: instances) do |dir|
      Fixtures.calc_gem(dir, "--table", "multicore_kernels")
    end
  end

  def test_a_second_suppify_gem_stops_the_build_by_name
    omit("spinel and PICORUBY_ROOT are required") if Fixtures.spinel.empty? || !File.exist?(File.join(ROOT, "Rakefile"))
    Dir.mktmpdir do |dir|
      capture_output do
        Fixtures.calc_gem(dir)
        Suppify::CLI.run([NATIVE, "Native.mag", "Native.b64", "-d", dir], spinel: Suppify::Spinel.new(bin: Fixtures.spinel))
      end
      File.write("#{dir}/build.rb", <<~RB)
        MRuby::Build.new do |conf|
          conf.toolchain
          conf.cc.defines << "PICORB_PLATFORM_POSIX"
        #{VMS[:mruby][1].gsub(/^/, '  ')}  conf.gem gemdir: "#{dir}/picoruby-calc"
          conf.gem gemdir: "#{dir}/picoruby-native"
        end
      RB
      out, status = Open3.capture2e({ "MRUBY_CONFIG" => "#{dir}/build.rb", "MRUBY_BUILD_DIR" => "#{dir}/build" },
                                    RbConfig.ruby, Gem.bin_path("rake", "rake"), chdir: ROOT)
      assert_false status.success?
      assert_include out, "picoruby-calc and picoruby-native are both suppify gems in build host"
    end
  end

  # Builds PicoRuby for +vm+ with the gem the block writes into a temporary directory,
  # then runs +program+ on it (after `require "<name>"` on mruby/c) and hands the directory to +check+.
  #: (Symbol, String, String, String, String, ?expected: String, ?check: (^(String) -> void)?) { (String) -> String } -> void
  def run_gem(vm, bin, config, name, program, expected: CALC_EXPECTED, check: nil)
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
      check&.call(dir)
    end
  end
end
