require "test_helper"

class TestExampleIntegration < Test::Unit::TestCase
  ROOT = ENV.fetch("PICORUBY_ROOT", "")
  EXAMPLE = File.expand_path("../examples/accumulator", __dir__)
  ENTRIES = %w[Acc.add Acc.at Acc.label Acc.reset].freeze
  PROG_OUT = "slot 0: 3.0|3.0|TypeError: can't convert nil into Float|0.0\n"
  MAIN_OUT = "vm 100000.0 worker 200000.0 bad 0 0\npast the end 1 TypeError\n"
  BOARD = %w[-mcpu=cortex-a9 -marm -ffunction-sections -fdata-sections].freeze

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

  def setup
    omit("spinel, cc and PICORUBY_ROOT are required") if Fixtures.spinel.empty? || Fixtures.which("cc").empty? || !File.exist?(File.join(ROOT, "Rakefile"))
  end

  VMS.each do |vm, (bin, config)|
    define_method("test_the_example_runs_on_#{vm}") do
      Dir.mktmpdir do |dir|
        gem = generate(dir)
        build(dir, <<~RB)
          MRuby::Build.new do |conf|
            conf.toolchain
            conf.cc.defines << "PICORB_PLATFORM_POSIX"
          #{config.gsub(/^/, '  ')}  conf.gem gemdir: #{gem.inspect}
          end
        RB
        File.write("#{dir}/prog.rb", (vm == :mrubyc ? %(require "acc"\n) : "") + File.read("#{EXAMPLE}/prog.rb"))
        out, = Open3.capture2e("#{dir}/build/host/bin/#{bin}", "#{dir}/prog.rb")
        assert_equal PROG_OUT, out
        next unless vm == :mruby
        assert_sealed("nm", "#{dir}/build/host/mrbgems/picoruby-acc/instances/acc_w1.o", gem, RUBY_PLATFORM.include?("darwin") ? "_" : "")
        libs = RbConfig::CONFIG["host_os"].include?("linux") ? %w[-lm -lcrypt] : %w[-lm]
        link("cc", "-O1", "-pthread", "-DEXAMPLE_THREADS", "-I#{gem}/include", "#{EXAMPLE}/main.c", "#{dir}/build/host/lib/libmruby.a", *libs, "-o", "#{dir}/main")
        assert_runs(["#{dir}/main"])
      end
    end
  end

  def test_the_example_runs_on_a_newlib_board
    omit("arm-none-eabi-gcc is required") if Fixtures.which("arm-none-eabi-gcc").empty?
    Dir.mktmpdir do |dir|
      gem = generate(dir, "--newlib", "--cc", "arm-none-eabi-gcc")
      build(dir, <<~RB)
        MRuby::CrossBuild.new("board") do |conf|
          conf.toolchain("gcc")
          conf.cc.command = "arm-none-eabi-gcc"
          conf.linker.command = "arm-none-eabi-ld"
          conf.archiver.command = "arm-none-eabi-ar"
          conf.cc.host_command = "cc"
          conf.cc.flags.concat(#{BOARD.inspect})
          conf.cc.defines.concat(%w[MRB_INT32 MRB_WORD_BOXING MRB_32BIT MRB_UTF8_STRING])
          conf.picoruby(alloc_estalloc: false)
          conf.gem gemdir: #{gem.inspect}
        end
      RB
      assert_sealed("arm-none-eabi-nm", "#{dir}/build/board/mrbgems/picoruby-acc/instances/acc_w1.o", gem, "")
      link("arm-none-eabi-gcc", *BOARD, "-Wl,--gc-sections", "--specs=rdimon.specs", "-I#{gem}/include", "#{EXAMPLE}/main.c",
           "#{dir}/build/board/lib/libmruby.a", "-lm", "-o", "#{dir}/main.elf")
      omit("qemu-arm is required to run the board program") if Fixtures.which("qemu-arm").empty?
      assert_runs(["qemu-arm", "#{dir}/main.elf"])
    end
  end

  # Writes the example's gem, with a VM instance and one sealed worker instance, into +dir+.
  #: (String, *String) -> String
  def generate(dir, *flags)
    capture_output do
      Suppify::CLI.run(["#{EXAMPLE}/kernel.rb", *ENTRIES, "-o", "acc", "-d", dir, "--workers", "1", *flags],
                       spinel: Suppify::Spinel.new(bin: Fixtures.spinel))
    end
    File.join(dir, "picoruby-acc")
  end

  #: (String, String) -> void
  def build(dir, config)
    File.write("#{dir}/build.rb", config)
    out, status = Open3.capture2e({ "MRUBY_CONFIG" => "#{dir}/build.rb", "MRUBY_BUILD_DIR" => "#{dir}/build" },
                                  RbConfig.ruby, Gem.bin_path("rake", "rake"), "-j8", chdir: ROOT)
    assert status.success?, out.lines.last(30).join
  end

  #: (*String) -> void
  def link(*cmd)
    out, status = Open3.capture2e(*cmd)
    assert status.success?, out
  end

  # The sealed worker object defines no global beyond its exports file.
  #: (String, String, String, String) -> void
  def assert_sealed(nm, object, gem, prefix)
    out, = Open3.capture2e(nm, "-g", "--defined-only", object)
    exports = File.readlines("#{gem}/src/instances/acc_w1.exports", chomp: true)
    assert_equal exports.sort, out.lines.map { _1.split[-1].delete_prefix(prefix) }.sort
  end

  # The two instances keep their own sums; pointing the worker at the VM instance mixes them.
  #: (Array[String]) -> void
  def assert_runs(cmd)
    out, = Open3.capture2e(*cmd)
    assert_equal MAIN_OUT, out
    out, = Open3.capture2e(*cmd, "shared")
    assert_not_equal MAIN_OUT, out
  end
end
