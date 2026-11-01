require "test_helper"

class TestPicoRubyIntegration < Test::Unit::TestCase
  ROOT = ENV.fetch("PICORUBY_ROOT", "")

  PROGRAM = <<~RUBY
    print Calc.add(2, 3), " ", Calc.half(5.0), " ", Calc.half(3), " ", Calc.greet("world"), " "
    print Calc.even?(4), " ", Calc.even?(3), " ", Calc.nully.bytesize, " ", Calc.blen("a\\0bc"), " "
    print Calc.ignore(1).inspect, " "
    begin; Calc.check(-1); rescue ArgumentError => e; print "ArgumentError:", e.message, " "; end
    begin; Calc.add("2", 3); rescue TypeError; print "TypeError "; end
    puts Calc.check(7)
  RUBY

  EXPECTED = "5 2.5 1.5 hi, world true false 3 4 nil ArgumentError:negative TypeError 7\n"

  VMS = {
    mruby: ["picoruby", <<~RB, ""],
      conf.cc.defines << "MRB_INT64"
      conf.cc.defines << "MRB_NO_BOXING"
      conf.cc.defines << "MRB_UTF8_STRING"
      conf.picoruby(alloc_estalloc: false)
      conf.gembox "minimum"
      conf.gem core: "picoruby-bin-picoruby"
    RB
    mrubyc: ["femtoruby", <<~RB, %(require "calc"\n)],
      conf.cc.defines << "PICORB_INT64"
      conf.cc.defines << "MRBC_TICK_UNIT=4"
      conf.cc.defines << "MRBC_TIMESLICE_TICK_COUNT=3"
      conf.cc.defines << "MRBC_USE_STRING_UTF8"
      conf.femtoruby
      conf.gembox "minimum"
      conf.gem core: "picoruby-require"
    RB
  }.freeze

  VMS.each do |vm, (bin, config, prelude)|
    define_method("test_the_gem_builds_into_#{vm}_and_runs") do
      omit("spinel and PICORUBY_ROOT are required") if Fixtures.spinel.empty? || !File.exist?(File.join(ROOT, "Rakefile"))
      Dir.mktmpdir do |dir|
        capture_output { Fixtures.calc_gem(dir) }
        File.write("#{dir}/build.rb", <<~RB)
          MRuby::Build.new do |conf|
            conf.toolchain
            conf.cc.defines << "PICORB_PLATFORM_POSIX"
          #{config.gsub(/^/, '  ')}  conf.gem gemdir: #{File.join(dir, 'picoruby-calc').inspect}
          end
        RB
        out, status = Open3.capture2e({ "MRUBY_CONFIG" => "#{dir}/build.rb", "MRUBY_BUILD_DIR" => "#{dir}/build" },
                                      RbConfig.ruby, Gem.bin_path("rake", "rake"), "-j8", chdir: ROOT)
        assert status.success?, out.lines.last(30).join
        File.write("#{dir}/prog.rb", prelude + PROGRAM)
        out, = Open3.capture2e("#{dir}/build/host/bin/#{bin}", "#{dir}/prog.rb")
        assert_equal EXPECTED, out
      end
    end
  end
end
