# lib/suppify/emitter/picoruby_gem.rb
require "fileutils"
require "suppify/binding/mruby"
require "suppify/runtime_sources"
require "suppify/symbol_prefix"

module Suppify
  module Emitter
    # Assembles a PicoRuby/mruby mrbgem from a pipeline result. The gem's
    # src/*.c (spinel-generated TU + runtime sources + mruby binding) are
    # compiled into libmruby.a by the consumer's own picoruby cross build, so
    # the target toolchain and ABI flags (-mlongcalls, MRB_NO_BOXING, ...) are
    # applied by that build — suppify never cross-compiles anything itself.
    # Add to a build with: conf.gem gemdir: "<out_dir>".
    module PicoRubyGem
      module_function

      def emit(lib_name:, c_source:, header:, exports:, spinel_lib:, out_dir:, gem_name: nil,
               discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
               version: "0.1.0", license: "MIT")
        gem_name ||= "picoruby-#{lib_name}"
        init_func = "mrb_#{gem_name.tr('-', '_')}_gem_init"
        src = File.join(out_dir, "src")
        inc = File.join(out_dir, "include")
        FileUtils.mkdir_p(src)
        FileUtils.mkdir_p(inc)

        File.write(File.join(src, "#{lib_name}_gen.c"), c_source)
        File.write(File.join(src, "#{lib_name}.h"), header) # quoted include from src/*.c
        File.write(File.join(inc, "#{lib_name}.h"), header)  # public header for consumers
        File.write(File.join(src, "binding.c"), Binding::Mruby.render(lib_name, init_func, exports))
        RuntimeSources.copy_flat(spinel_lib, src)

        symbols = discover_symbols.call(spinel_lib)
        File.write(File.join(src, "#{lib_name}_prelude.h"), SymbolPrefix.prelude(lib_name, symbols))

        File.write(File.join(out_dir, "mrbgem.rake"), mrbgem_rake(gem_name, lib_name, version, license))
        { gem_dir: out_dir, gem_name: gem_name, init_func: init_func }
      end

      # version/license are consumer-controlled: a placeholder version is
      # harmless, but presuming a license on the consumer's own code's
      # behalf would not be, so it's omitted unless explicitly given.
      def mrbgem_rake(gem_name, lib_name, version, license)
        <<~RUBY
          MRuby::Gem::Specification.new('#{gem_name}') do |spec|
            spec.version = "#{version}"
            spec.author  = 'suppify'
            spec.summary = 'suppify-generated native gem'
            #{"spec.license = #{license.inspect}\n" if license}
            # Public neutral header for firmware/consumer code.
            spec.cc.include_paths << "\#{dir}/include"
            # libm for the spinel runtime's math (harmless where libm is in libc).
            spec.linker.libraries << 'm'
            # Namespaces every vendored spinel runtime symbol to this library
            # (so a second suppify mrbgem linked into the same firmware image
            # doesn't collide with this one's runtime state) and silences the
            # bundled runtime's own harmless warnings. See Suppify::SymbolPrefix.
            spec.cc.flags << "-include \#{dir}/src/#{lib_name}_prelude.h"
          end
        RUBY
      end
    end
  end
end
