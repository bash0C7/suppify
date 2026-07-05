# test/test_spinel_runner.rb
require "test_helper"
require "suppify/spinel_runner"

class TestSpinelRunner < Test::Unit::TestCase
  # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
  # emit modes (src/main.c: emit_symbol_map short-circuits before the
  # c_only branch, so a combined invocation silently drops the C output).
  # SpinelRunner must therefore issue two separate invocations.
  def test_builds_two_commands_and_returns_paths
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "/opt/spinel", runner: fake)
    out = r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["/opt/spinel", "/work/app.rb", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["/opt/spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
    assert_equal "/tmp/app.c", out[:c_path]
    assert_equal "/tmp/app.symbols.json", out[:symbols_path]
  end

  def test_nonzero_status_raises_on_c_step
    fake = ->(_argv) { ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_nonzero_status_raises_on_symbol_map_step
    calls = 0
    fake = ->(_argv) { calls += 1; calls == 1 ? ["", 0] : ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_includes_rbs_flag_on_c_step_only_when_given
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake, rbs_dir: "/work/sigs")
    r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["spinel", "/work/app.rb", "--rbs", "/work/sigs", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
  end
end
