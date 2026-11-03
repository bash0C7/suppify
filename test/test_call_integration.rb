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
    kernel slot (Integer) -> Float
    kernel count (Integer) -> Integer
    add 1: 05
    greet 10: a9 68 69 2c 20 77 6f 72 6c 64
    half 9: cb 3f f8 00 00 00 00 00 00
    check raised -3 ArgumentError: negative
    blen 1: 04
    half32 9: cb 3f f8 00 00 00 00 00 00
    ignore 1: c0
    greet16 46: d9 2c hi, 
    big %s
    malformed -1
    cleared [] []
    negative -1 -1
    nospace -2
    typed add 0 42
    typed greet 0 hi, x
    slot 9: cb 3f e0 00 00 00 00 00 00
    slot nil -3 TypeError: can't convert nil into Float
    typed count 0 7
    typed count nil 1 TypeError: no implicit conversion of nil into Integer
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
