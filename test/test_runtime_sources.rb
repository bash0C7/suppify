# test/test_runtime_sources.rb
require "test_helper"
require "suppify/runtime_sources"
require "fileutils"
require "tmpdir"

class TestRuntimeSources < Test::Unit::TestCase
  def test_sources_list_covers_runtime_and_regexp
    s = Suppify::RuntimeSources::SOURCES
    assert_includes s, "sp_gc.c"
    assert_includes s, "sp_str.c"
    assert_includes s, "regexp/re_compile.c"
    assert_equal 25, s.length
  end

  # copy_flat flattens every runtime .c and every header into one dir (so a
  # consumer's flat compile — mkmf top-level globbing, mrbgem src/ glob —
  # picks them all up). Quoted same-dir includes keep resolving after flatten.
  def test_copy_flat_copies_sources_and_headers_by_basename
    Dir.mktmpdir do |root|
      lib = File.join(root, "lib")
      FileUtils.mkdir_p(File.join(lib, "regexp"))
      Suppify::RuntimeSources::SOURCES.each { |rel| File.write(File.join(lib, rel), "/* #{rel} */") }
      File.write(File.join(lib, "sp_runtime.h"), "/* h */")
      File.write(File.join(lib, "regexp", "re_internal.h"), "/* h */")

      dest = File.join(root, "out")
      FileUtils.mkdir_p(dest)
      result = Suppify::RuntimeSources.copy_flat(lib, dest)

      assert_includes result[:sources], "sp_gc.c"
      assert_includes result[:sources], "re_compile.c" # flattened, no regexp/ prefix
      assert_includes result[:headers], "sp_runtime.h"
      assert_includes result[:headers], "re_internal.h"
      assert File.exist?(File.join(dest, "sp_gc.c"))
      assert File.exist?(File.join(dest, "re_compile.c"))
      assert File.exist?(File.join(dest, "sp_runtime.h"))
    end
  end

  def test_copy_flat_raises_when_a_declared_source_is_missing
    Dir.mktmpdir do |root|
      lib = File.join(root, "lib")
      FileUtils.mkdir_p(lib)
      # intentionally create nothing
      assert_raise(Suppify::Error) { Suppify::RuntimeSources.copy_flat(lib, root) }
    end
  end
end
