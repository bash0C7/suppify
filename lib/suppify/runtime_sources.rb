# lib/suppify/runtime_sources.rb
require "fileutils"

module Suppify
  # Bundles the spinel runtime's C sources + headers so a consumer's own build
  # (mkmf for a CRuby gem, rake for a PicoRuby mrbgem, ...) compiles them with
  # the consumer's own toolchain and flags. This is what makes cross-compilation
  # "just work": suppify never cross-compiles the runtime itself — it ships the
  # sources and lets the target build do it. Sources are flattened into one
  # directory; the runtime's includes are all quoted same-dir references.
  module RuntimeSources
    module_function

    # The .c files archived into libspinel_rt.a (spinel Makefile), relative to
    # spinel's lib/ dir. Kept explicit rather than globbed so an unexpected
    # extra .c in a future spinel doesn't silently get pulled in.
    SOURCES = %w[
      regexp/re_compile.c regexp/re_exec.c regexp/re_utf8.c
      sp_bigint.c sp_crypto.c sp_pack.c sp_strscan.c sp_time.c
      sp_core.c sp_net.c sp_system.c sp_gc.c sp_alloc.c sp_json.c
      sp_marshal.c sp_format.c sp_stringio.c sp_string.c sp_inspect.c
      sp_array.c sp_str.c sp_re.c sp_fiber.c sp_sched.c sp_io.c
    ].freeze

    def copy_flat(lib_dir, dest_dir)
      FileUtils.mkdir_p(dest_dir)
      sources = SOURCES.map do |rel|
        src = File.join(lib_dir, rel)
        raise Error, "spinel runtime source missing: #{src}" unless File.exist?(src)
        base = File.basename(rel)
        FileUtils.cp(src, File.join(dest_dir, base))
        base
      end
      header_paths(lib_dir).each do |src|
        FileUtils.cp(src, File.join(dest_dir, File.basename(src)))
      end
      { sources: sources }
    end

    def header_paths(lib_dir)
      Dir[File.join(lib_dir, "*.h")] + Dir[File.join(lib_dir, "regexp", "*.h")]
    end
  end
end
