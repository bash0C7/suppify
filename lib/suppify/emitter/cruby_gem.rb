# lib/suppify/emitter/cruby_gem.rb
require "fileutils"
require "suppify/binding/cruby"
require "suppify/runtime_sources"

module Suppify
  module Emitter
    # Assembles a complete, buildable CRuby native-extension gem from a
    # pipeline result. The gem compiles the spinel-generated C + the runtime
    # sources + the CRuby binding with the consumer's own Ruby toolchain
    # (mkmf), so the caller's Ruby (any platform) produces the native library.
    module CRubyGem
      module_function

      def emit(lib_name:, c_source:, header:, exports:, spinel_lib:, out_dir:)
        ext = File.join(out_dir, "ext", lib_name)
        lib = File.join(out_dir, "lib")
        FileUtils.mkdir_p(ext)
        FileUtils.mkdir_p(lib)

        File.write(File.join(ext, "#{lib_name}_gen.c"), c_source)
        File.write(File.join(ext, "#{lib_name}.h"), header)
        File.write(File.join(ext, "binding.c"), Binding::CRuby.render(lib_name, exports))
        RuntimeSources.copy_flat(spinel_lib, ext)

        File.write(File.join(ext, "extconf.rb"), extconf(lib_name))
        File.write(File.join(lib, "#{lib_name}.rb"), %(require "#{lib_name}/#{lib_name}"\n))
        File.write(File.join(out_dir, "#{lib_name}.gemspec"), gemspec(lib_name))

        { gemspec: File.join(out_dir, "#{lib_name}.gemspec"), ext_dir: ext }
      end

      def extconf(lib_name)
        <<~RUBY
          require "mkmf"
          # libm for the runtime's math (sp_format); harmless where libm is in libc.
          $LDFLAGS << " -lm"
          # All .c in this dir (generated TU, binding, flattened spinel runtime)
          # are picked up by mkmf's default *.c globbing.
          create_makefile("#{lib_name}/#{lib_name}")
        RUBY
      end

      def gemspec(lib_name)
        <<~RUBY
          Gem::Specification.new do |s|
            s.name        = "#{lib_name}"
            s.version     = "0.0.0"
            s.summary     = "suppify-generated native extension"
            s.authors     = ["suppify"]
            s.files       = Dir["lib/**/*.rb"] + Dir["ext/**/*.{c,h,rb}"]
            s.extensions  = ["ext/#{lib_name}/extconf.rb"]
            s.required_ruby_version = ">= 3.0"
          end
        RUBY
      end
    end
  end
end
