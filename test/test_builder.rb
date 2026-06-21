# test/test_builder.rb
require "test_helper"
require "suppify/builder"

class TestBuilder < Test::Unit::TestCase
  def test_runs_cc_then_ar_and_copies_runtime
    cmds = []
    copies = []
    fake = ->(cmd) { cmds << cmd; ["", 0] }
    copy = ->(src, dst) { copies << [src, dst] }
    b = Suppify::Builder.new(spinel_lib: "/opt/spinel/lib", runner: fake, copier: copy)
    out = b.build(c_path: "/tmp/app.c", lib_name: "mylib", out_dir: "/out")

    assert_match(%r{cc -c /tmp/app.c -I/opt/spinel/lib -o /tmp/app.o}, cmds[0])
    assert_match(%r{ar rcs /out/libmylib.a /tmp/app.o}, cmds[1])
    assert_equal ["/opt/spinel/lib/libspinel_rt.a", "/out/libspinel_rt.a"], copies[0]
    assert_equal "/out/libmylib.a", out[:archive]
  end

  def test_cc_failure_raises
    fake = ->(_cmd) { ["err", 1] }
    b = Suppify::Builder.new(spinel_lib: "/l", runner: fake, copier: ->(_a,_b){})
    assert_raise(Suppify::Error) { b.build(c_path: "/tmp/a.c", lib_name: "x", out_dir: "/o") }
  end
end
