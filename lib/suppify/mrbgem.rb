require "fileutils"

module Suppify
  # Writes a Library as a self-contained PicoRuby mrbgem directory.
  module Mrbgem
    module_function

    RUNTIME = %w[*.c *.h regexp/*.c regexp/*.h regexp/*.inc regexp/shim/*.h].freeze

    # Writes `picoruby-<name>/` under +out_dir+ and returns its path. +newlib+ adds spinel's
    # lib/newlib layer for a board whose C library is newlib (docs/newlib.md in spinel).
    #: (Library, String, ?license: String, ?newlib: bool) -> String
    def write(lib, out_dir, license: "MIT", newlib: false)
      glue = Glue.source(lib)
      binding_c = Binding.render(lib)
      dir = File.join(out_dir, "picoruby-#{lib.name}")
      src = File.join(dir, "src")
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p([File.join(src, "mruby"), File.join(dir, "include"), File.join(dir, "mrblib")])
      vendor_runtime(lib.runtime_dir, src)
      vendor_newlib(lib.runtime_dir, File.join(src, "newlib")) if newlib
      File.write(File.join(src, "#{lib.name}_spinel.c"), lib.kernel_c)
      File.write(File.join(src, "#{lib.name}_spinel.h"), lib.kernel_h)
      File.write(File.join(src, "#{lib.name}_glue.c"), glue)
      File.write(File.join(src, "binding.c"), binding_c)
      File.write(File.join(dir, "include", "#{lib.name}.h"), Glue.header(lib))
      File.write(File.join(dir, "mrblib", "#{lib.name}.rb"), lib.entries.map(&:mod).uniq.map { "module #{_1}\nend\n" }.join)
      File.write(File.join(dir, "mrbgem.rake"), rake(lib, license, newlib))
      dir
    end

    # Copies the runtime flat into +src+. The regexp engine names its mruby shim as <mruby.h>;
    # the copies name it "mruby.h", so the shim beside them is read even where the real mruby's
    # headers come first on the include path.
    #: (String, String) -> void
    def vendor_runtime(runtime_dir, src)
      files = RUNTIME.flat_map { |pattern| Dir[File.join(runtime_dir, pattern)] }
      raise Error, "no spinel runtime sources in #{runtime_dir}" if files.none? { |f| File.basename(f) == "spinel_rt.h" }
      files.each { |f| File.binwrite(File.join(src, File.basename(f)), quote_mruby(f)) }
      Dir[File.join(runtime_dir, "regexp/shim/mruby/*.h")].each { |f| File.binwrite(File.join(src, "mruby", File.basename(f)), quote_mruby(f)) }
    end

    #: (String) -> String
    def quote_mruby(path)
      text = File.binread(path)
      path.include?("/regexp/") ? text.gsub(/#include <(mruby(?:\/\w+)?\.h)>/, '#include "\1"') : text
    end

    #: (String, String) -> void
    def vendor_newlib(runtime_dir, dest)
      from = File.join(runtime_dir, "newlib")
      raise Error, "this spinel has no lib/newlib" unless File.directory?(from)
      FileUtils.cp_r(from, dest)
    end

    #: (Library, String, bool) -> String
    def rake(lib, license, newlib)
      includes = lib.cflags.grep(/\A-I/).map { _1.delete_prefix("-I") }
      defines = lib.defines + lib.cflags.grep(/\A-D/).map { _1.delete_prefix("-D") }
      board = <<~RUBY if newlib
        newlib = "\#{dir}/src/newlib"
        spec.cc.include_paths.unshift(newlib)
        spec.cc.defines << "_DEFAULT_SOURCE"
        spec.cc.flags << "-include \#{newlib}/sp_newlib_config.h"
        stubs = objfile("\#{build_dir}/src/newlib/sp_newlib")
        spec.objs << stubs
        file(stubs => "\#{newlib}/sp_newlib.c") { |t| spec.cc.run t.name, t.prerequisites.first }
      RUBY
      link = ["libs = #{(lib.libs - ['crypt']).inspect}"]
      link << 'libs << "crypt" if !build.is_a?(MRuby::CrossBuild) && RUBY_PLATFORM.include?("linux")' unless newlib
      link << "build.linker.libraries.concat(libs - build.linker.libraries)"
      <<~RUBY
        MRuby::Gem::Specification.new(#{"picoruby-#{lib.name}".inspect}) do |spec|
          SUPPIFY_GEMS = {} unless defined?(SUPPIFY_GEMS)
          other = SUPPIFY_GEMS[build.name] ||= spec.name
          raise "\#{other} and \#{spec.name} are both suppify gems in build \#{build.name}; compile every kernel into one gem" if other != spec.name
          spec.license = #{license.inspect}
          spec.author = "suppify"
          spec.summary = #{"#{lib.name}: Ruby compiled by spinel".inspect}
          spec.cc.defines.concat(#{defines.inspect})
          spec.cc.include_paths.concat(#{includes.inspect})
        #{"#{board}#{link.join("\n")}\n".gsub(/^/, '  ')}end
      RUBY
    end
  end
end
