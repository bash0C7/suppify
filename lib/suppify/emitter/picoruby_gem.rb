# lib/suppify/emitter/picoruby_gem.rb
require "fileutils"
require "suppify/binding/mruby"
require "suppify/runtime_sources"

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

      def emit(lib_name:, c_source:, header:, exports:, spinel_lib:, out_dir:, gem_name: nil)
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

        File.write(File.join(out_dir, "mrbgem.rake"), mrbgem_rake(gem_name))
        { gem_dir: out_dir, gem_name: gem_name, init_func: init_func }
      end

      def mrbgem_rake(gem_name)
        <<~RUBY
          MRuby::Gem::Specification.new('#{gem_name}') do |spec|
            spec.license = 'MIT'
            spec.author  = 'suppify'
            spec.summary = 'suppify-generated native gem'
            # Public neutral header for firmware/consumer code.
            spec.cc.include_paths << "\#{dir}/include"
            # libm for the spinel runtime's math (harmless where libm is in libc).
            spec.linker.libraries << 'm'
            # Same harmless spinel-runtime-origin warnings as the cruby target
            # (e.g. sp_types.h unconditionally #defines _DARWIN_C_SOURCE).
            # -Wno-* for an unrecognized name is silently accepted by both
            # gcc and clang, so this is safe across whatever cross toolchain
            # the consuming build_config selects.
            spec.cc.flags << '-Wno-macro-redefined' << '-Wno-missing-noreturn'
          end
        RUBY
      end
    end
  end
end
