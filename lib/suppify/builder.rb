# lib/suppify/builder.rb
require "open3"
require "fileutils"
require "suppify/runtime_sources"
require "suppify/symbol_prefix"

module Suppify
  # Builds the "c" target: compiles the generated translation unit AND a
  # bundled (recompiled, not prebuilt-copied) copy of the spinel runtime into
  # one self-contained lib<name>.a. The runtime is recompiled per library
  # (rather than reusing spinel's own prebuilt libspinel_rt.a) so its ~600
  # global symbols can be namespaced by SymbolPrefix -- otherwise two
  # suppify-built libraries linked into the same binary would collide on
  # spinel's shared runtime state.
  class Builder
    def initialize(spinel_lib: ENV["SPINEL_LIB"].to_s,
                   runner: method(:shell),
                   discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
                   copy_runtime: RuntimeSources.method(:copy_flat))
      @spinel_lib = spinel_lib
      @runner = runner
      @discover_symbols = discover_symbols
      @copy_runtime = copy_runtime
    end

    def build(c_path:, lib_name:, out_dir:)
      build_dir = File.dirname(c_path)
      runtime_dir = File.join(build_dir, "#{lib_name}_runtime")
      copied = @copy_runtime.call(@spinel_lib, runtime_dir)

      prelude_path = File.join(build_dir, "#{lib_name}_prelude.h")
      symbols = @discover_symbols.call(@spinel_lib)
      File.write(prelude_path, SymbolPrefix.prelude(lib_name, symbols))

      sources = [c_path] + copied[:sources].map { |base| File.join(runtime_dir, base) }
      objs = sources.map { |src| compile(src, runtime_dir, prelude_path) }

      archive = File.join(out_dir, "lib#{lib_name}.a")
      run! ["ar", "rcs", archive, *objs]
      { archive: archive }
    end

    def compile(src, runtime_dir, prelude_path)
      o_path = src.sub(/\.c\z/, ".o")
      run! ["cc", "-c", src, "-I#{runtime_dir}", "-include", prelude_path, "-o", o_path]
      o_path
    end

    def run!(argv)
      out, status = @runner.call(argv)
      raise Error, "command failed (#{status}): #{argv.join(' ')}\n#{out}" unless status == 0
    end

    # Default runner: array-form argv, no shell involved.
    def shell(argv)
      out, status = Open3.capture2e(*argv)
      [out, status.exitstatus]
    end
  end
end
