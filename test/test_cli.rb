# test/test_cli.rb
require "test_helper"
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

  # lib_name is spliced verbatim into #define replacement text by
  # SymbolPrefix.prelude ("#define sym lib_name_sym"); a non-identifier
  # character there breaks the C preprocessor's tokenization of every
  # renamed runtime symbol (a hyphen splits the replacement into three
  # tokens: an unrelated subtraction expression, not one valid name).
  # Confirmed by an adversarial review: `-o my-lib` breaks the build with
  # 20+ compile errors. Validated once at parse time instead of leaving
  # every consumer to discover this via a wall of unrelated-looking errors.
  def test_lib_name_must_be_a_valid_c_identifier
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["app.rb", "-o", "my-lib"]) }
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["my-app.rb"]) } # default derived from the filename
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["app.rb", "-o", "1lib"]) } # leading digit
    assert_equal "my_lib", Suppify::CLI.parse(["app.rb", "-o", "my_lib"])[:lib_name]
  end

  # A lib_name equal to one of spinel's own runtime source basenames (e.g.
  # sp_gc) makes the "c" target's archive gain two members both literally
  # named sp_gc.o (the user's generated <lib_name>.c and spinel's own
  # sp_gc.c), which some ar/toolchains mis-handle when unpacking by name.
  def test_lib_name_must_not_collide_with_a_reserved_runtime_source_basename
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["app.rb", "-o", "sp_gc"]) }
  end

  # A flag with a missing or flag-shaped value must raise a clear error
  # naming the actual problem, not silently swallow the next flag (or the
  # positional filename) as if it were the value. Confirmed by an
  # adversarial review: `parse(["--license", "-o", "mylib", "app.rb"])`
  # previously set license to "-o" and dropped "mylib" without any error.
  def test_flag_with_missing_or_flag_shaped_value_raises
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["--license", "-o", "mylib", "app.rb"]) }
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["app.rb", "--license"]) }
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["app.rb", "-o"]) }
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

  # opts[:license] || "MIT" treats an explicit empty string as present (only
  # nil/false are falsy in Ruby), silently writing spec.license = "" instead
  # of falling back -- picoruby's own hard-fail check (!licenses) also
  # doesn't catch an empty-but-present string, so this produces a silently
  # wrong mrbgem.rake rather than a build error. An empty --license is
  # exactly as "unset" as an absent one for this purpose.
  def test_emit_gem_treats_empty_license_as_unset_for_picoruby
    omit("SPINEL_LIB unset") if ENV["SPINEL_LIB"].to_s.empty?

    Dir.mktmpdir do |root|
      opts = { out_dir: root, lib_name: "addlib", gem_version: "0.1.0", license: "" }
      result = { c_source: "", header: "", exports: [] }

      Suppify::CLI.emit_gem(:picoruby, opts, result)

      rake = File.read(File.join(root, "picoruby-addlib", "mrbgem.rake"))
      assert_match(/spec\.license\s*=\s*"MIT"/, rake)
    end
  end
end

# How the CLI feeds spinel's --rbs seeding. A .rbs sidecar is no longer
# required: the method types can be written inline above each def, and
# suppify renders those into a seed file of their own (spinel reads every
# .rbs in the directory it is pointed at).
class TestCLISeeding < Test::Unit::TestCase
  INLINE = "#: (Integer) -> Integer\ndef f(a) = a\n"

  def seed(dir, ruby, sidecar: nil)
    rb = File.join(dir, "k.rb")
    File.write(rb, ruby)
    File.write(File.join(dir, "k.rbs"), sidecar) if sidecar
    source = Suppify::CLI.build_source(rb, ruby)
    [source, *Suppify::CLI.root_and_seed(source, rb, ruby, File.join(dir, "tmp", "k.c"))]
  end

  def test_inline_only_source_needs_no_sidecar
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      _source, rooted, rbs_dir = seed(dir, INLINE)
      assert_match(/if false\n  f\(0\)\n/, File.read(rooted))
      assert_match(/def f: \(Integer\) -> Integer/,
                   File.read(File.join(rbs_dir, "_suppify_inline.rbs")))
    end
  end

  # With a sidecar and no inline annotations, the seed directory is the
  # input's own -- unchanged, so anything else the user keeps there
  # (declarations for their own classes) still reaches spinel.
  def test_sidecar_only_source_seeds_from_the_inputs_own_directory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      sidecar = "class Object\n  def f: (Integer) -> Integer\nend\n"
      _source, _rooted, rbs_dir = seed(dir, "def f(a) = a\n", sidecar: sidecar)
      assert_equal File.expand_path(dir), rbs_dir
    end
  end

  # A mixed source seeds both: the sidecar is copied next to the rendered
  # inline declarations, and spinel merges the two `class Object` blocks.
  def test_mixed_source_seeds_both_forms
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      sidecar = "class Object\n  def g: (String) -> String\nend\n"
      _source, _rooted, rbs_dir = seed(dir, INLINE + "def g(s) = s\n", sidecar: sidecar)
      seeded = Dir[File.join(rbs_dir, "*.rbs")].map { |f| File.read(f) }.join
      assert_match(/def f: \(Integer\) -> Integer/, seeded)
      assert_match(/def g: \(String\) -> String/, seeded)
    end
  end

  def test_public_method_with_no_signature_anywhere_raises
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      e = assert_raise(Suppify::Error) { seed(dir, "def lonely(a) = a\n") }
      assert_match(/lonely/, e.message)
    end
  end
end
