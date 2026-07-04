# test/test_cli.rb
require "test_helper"
require "suppify/cli"
require "suppify/runtime_sources"
require "fileutils"
require "tmpdir"

class TestCLI < Test::Unit::TestCase
  def test_parses_input_and_output
    opts = Suppify::CLI.parse(["app.rb", "-o", "mylib"])
    assert_equal "app.rb", opts[:input]
    assert_equal "mylib",  opts[:lib_name]
  end

  def test_defaults_lib_name_from_input
    opts = Suppify::CLI.parse(["foo/bar.rb"])
    assert_equal "bar", opts[:lib_name]
  end

  def test_missing_input_raises
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["-o", "x"]) }
  end

  def test_target_defaults_to_c
    assert_equal "c", Suppify::CLI.parse(["app.rb"])[:target]
  end

  def test_parses_target
    assert_equal "cruby",    Suppify::CLI.parse(["app.rb", "-t", "cruby"])[:target]
    assert_equal "picoruby", Suppify::CLI.parse(["app.rb", "--target", "picoruby"])[:target]
  end

  def test_unknown_target_raises
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["app.rb", "-t", "rust"]) }
  end

  # gem/mrbgem metadata (cruby/picoruby targets) defaults to a clearly
  # placeholder version and no license, rather than presuming a license on
  # the consumer's own code's behalf.
  def test_gem_version_defaults_and_is_settable
    assert_equal "0.1.0", Suppify::CLI.parse(["app.rb"])[:gem_version]
    assert_equal "2.3.4", Suppify::CLI.parse(["app.rb", "--gem-version", "2.3.4"])[:gem_version]
  end

  def test_license_defaults_to_nil_and_is_settable
    assert_nil Suppify::CLI.parse(["app.rb"])[:license]
    assert_equal "MIT", Suppify::CLI.parse(["app.rb", "--license", "MIT"])[:license]
  end
end

class TestCLIEmitGem < Test::Unit::TestCase
  # emit_gem must forward the parsed version/license through to the
  # emitter, not silently drop them on the floor. Needs a real SPINEL_LIB
  # (symbol discovery compiles a stub against the real sp_runtime.h), not
  # something fakeable without a real spinel install.
  def test_emit_gem_forwards_version_and_license_to_cruby_emitter
    omit("SPINEL_LIB unset") if ENV["SPINEL_LIB"].to_s.empty?

    Dir.mktmpdir do |root|
      opts = { out_dir: root, lib_name: "addlib", gem_version: "2.3.4", license: "MIT" }
      result = { c_source: "", header: "", exports: [] }

      Suppify::CLI.emit_gem(:cruby, opts, result)

      gemspec = File.read(File.join(root, "addlib", "addlib.gemspec"))
      assert_match(/s\.version\s*=\s*"2\.3\.4"/, gemspec)
      assert_match(/s\.license\s*=\s*"MIT"/, gemspec)
    end
  end
end
