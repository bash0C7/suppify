# test/test_spinel_pin.rb
require "test/unit"
require_relative "../rakelib/spinel_pin"

class TestSpinelPin < Test::Unit::TestCase
  def test_rt_members_parses_makefile_snippet
    text = "RT_MEMBERS = sp_core sp_gc sp_io\n"
    assert_equal(["sp_core", "sp_gc", "sp_io"], SpinelPin.rt_members(text))
  end

  def test_diff_sources_returns_empty_when_matching
    text = "RT_MEMBERS = sp_core sp_gc sp_io\n"
    known = %w[sp_core.c sp_gc.c sp_io.c]
    assert_equal({ added: [], removed: [] }, SpinelPin.diff_sources(text, known))
  end

  def test_diff_sources_reports_added_upstream_member
    text = "RT_MEMBERS = sp_core sp_gc sp_io sp_new_module\n"
    known = %w[sp_core.c sp_gc.c sp_io.c]
    assert_equal({ added: ["sp_new_module"], removed: [] }, SpinelPin.diff_sources(text, known))
  end

  def test_diff_sources_reports_removed_known_member
    text = "RT_MEMBERS = sp_core sp_gc\n"
    known = %w[sp_core.c sp_gc.c sp_io.c]
    assert_equal({ added: [], removed: ["sp_io"] }, SpinelPin.diff_sources(text, known))
  end

  def test_diff_sources_ignores_non_top_level_known_sources
    text = "RT_MEMBERS = sp_core\n"
    known = %w[sp_core.c regexp/re_compile.c]
    assert_equal({ added: [], removed: [] }, SpinelPin.diff_sources(text, known))
  end
end
