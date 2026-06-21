# test/test_spinel_runner.rb
require "test_helper"
require "suppify/spinel_runner"

class TestSpinelRunner < Test::Unit::TestCase
  def test_builds_command_and_returns_paths
    captured = nil
    fake = ->(cmd) { captured = cmd; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "/opt/spinel", runner: fake)
    out = r.emit("/work/app.rb", "/tmp/app.c")
    assert_match(%r{/opt/spinel /work/app.rb -c -o /tmp/app.c --emit-symbol-map}, captured)
    assert_equal "/tmp/app.c", out[:c_path]
    assert_equal "/tmp/app.symbols.json", out[:symbols_path]
  end

  def test_nonzero_status_raises
    fake = ->(_cmd) { ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end
end
