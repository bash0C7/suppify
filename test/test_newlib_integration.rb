require "test_helper"

class TestNewlibIntegration < Test::Unit::TestCase
  ARCH = %w[-mcpu=cortex-a9 -marm].freeze

  def test_the_gem_runs_on_a_32_bit_newlib_board
    omit("spinel, arm-none-eabi-gcc and qemu-arm are required") if [Fixtures.spinel, Fixtures.which("arm-none-eabi-gcc"), Fixtures.which("qemu-arm")].any?(&:empty?)
    Dir.mktmpdir do |dir|
      gem = nil
      capture_output { gem = Fixtures.calc_gem(dir, "--newlib") }
      newlib = File.join(gem, "src/newlib")
      flags = [*ARCH, "-O2", "-ffunction-sections", "-fdata-sections", "-Werror=implicit-function-declaration", "-D_DEFAULT_SOURCE",
               "-include", "#{newlib}/sp_newlib_config.h", "-I#{newlib}", "-I#{gem}/include", "-I#{gem}/src",
               "-DSP_ONE_STRING", "-DSP_INT_OVERFLOW_MODE_RAISE"]
      objs = [Fixtures::CALL_HOST, *Fixtures.runtime_sources(gem), "#{newlib}/sp_newlib.c"].each_with_index.map do |src, i|
        obj = File.join(dir, "#{i}.o")
        out, status = Open3.capture2e("arm-none-eabi-gcc", "-c", *flags, src, "-o", obj)
        assert status.success?, "#{src}:\n#{out}"
        obj
      end
      out, status = Open3.capture2e("arm-none-eabi-gcc", *ARCH, "--specs=rdimon.specs", "-Wl,--gc-sections", *objs, "-lm", "-o", "#{dir}/host.elf")
      assert status.success?, out
      out, = Open3.capture2e("qemu-arm", "#{dir}/host.elf")
      assert_equal format(TestCallIntegration::EXPECTED, "-4"), out
    end
  end
end
