require "test_helper"

class TestCallIntegration < Test::Unit::TestCase
  EXPECTED = <<~OUT
    kernel add (Integer, Integer) -> Integer
    kernel half (Float) -> Float
    kernel greet (String) -> String
    kernel even? (Integer) -> bool
    kernel check (Integer) -> Integer
    kernel nully () -> String
    kernel blen (String) -> Integer
    kernel ignore (Integer) -> nil
    add 1: 05
    greet 10: a9 68 69 2c 20 77 6f 72 6c 64
    half 9: cb 3f f8 00 00 00 00 00 00
    check raised -3 ArgumentError: negative
    blen 1: 04
    big %s
    malformed -1
    cleared [] []
    negative -1 -1
    nospace -2
    typed add 0 42
    typed greet 0 hi, x
  OUT

  def test_the_entries_answer_messagepack_and_plain_c_callers
    omit("spinel and cc are required") if Fixtures.spinel.empty? || Fixtures.which("cc").empty?
    Dir.mktmpdir do |dir|
      gem = capture_output { Fixtures.calc_gem(dir) } && File.join(dir, "picoruby-calc")
      lib = RbConfig::CONFIG["host_os"].include?("linux") ? %w[-lm -lcrypt] : %w[-lm]
      out, status = Open3.capture2e("cc", "-O1", "-w", "-I#{gem}/include", "-I#{gem}/src", "-DSP_ONE_STRING", "-DSP_INT_OVERFLOW_MODE_RAISE",
                                    Fixtures::CALL_HOST, *Fixtures.runtime_sources(gem), *lib, "-o", "#{dir}/host")
      assert status.success?, out
      out, = Open3.capture2e("#{dir}/host")
      assert_equal format(EXPECTED, "-3"), out
    end
  end
end
