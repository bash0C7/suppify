require "fileutils"

module Suppify
  # Writes a Library as a self-contained PicoRuby mrbgem directory.
  module Mrbgem
    module_function

    RUNTIME = %w[*.c *.h regexp/*.c regexp/*.h regexp/*.inc regexp/shim/*.h].freeze

    # The instances a gem holds: one for the VM when +vm+, then one per worker. Worker k's entries
    # are `<name>_w<k>_*`; +table+ names worker 1's kernel table.
    #: (String, vm: bool, workers: Integer, ?table: String?) -> Array[Instance]
    def instances(name, vm:, workers:, table: nil)
      list = vm ? [Instance.new(api: name, table: "#{name}_kernels")] : []
      list + (1..workers).map { |k| Instance.new(api: "#{name}_w#{k}", table: (k == 1 && table) || "#{name}_w#{k}_kernels") }
    end

    # Writes `picoruby-<name>/` under +out_dir+ and returns its path. +newlib+ adds spinel's
    # lib/newlib layer for a board whose C library is newlib (docs/newlib.md in spinel).
    # The first instance builds from src/ as the gem's own code; every other one compiles the same
    # runtime and kernel again and is sealed, so its symbols meet no other instance's.
    #: (Library, String, ?license: String, ?newlib: bool, ?vm: bool, ?workers: Integer, ?table: String?) -> String
    def write(lib, out_dir, license: "MIT", newlib: false, vm: true, workers: 0, table: nil)
      primary, *sealed = instances(lib.name, vm:, workers:, table:)
      raise Error, "a gem with no VM methods needs a worker" unless primary
      dir = File.join(out_dir, "picoruby-#{lib.name}")
      src = File.join(dir, "src")
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p([File.join(src, "mruby"), File.join(src, "spinel"), File.join(src, "instances"), File.join(dir, "include", "suppify")])
      vendor_runtime(lib.runtime_dir, src)
      vendor_newlib(lib.runtime_dir, File.join(src, "newlib")) if newlib
      lib.sources.each { |f| FileUtils.cp(f, src) }
      File.write(File.join(src, "#{lib.name}_spinel.c"), lib.kernel_c)
      File.write(File.join(src, "#{lib.name}_spinel.h"), lib.kernel_h)
      File.write(File.join(src, "#{lib.name}_glue.c"), Glue.source(lib, primary))
      sealed.each do |inst|
        File.write(File.join(src, "instances", "#{inst.api}_glue.c"), Glue.source(lib, inst))
        File.write(File.join(src, "instances", "#{inst.api}.exports"), Glue.exports(lib, inst).join("\n") + "\n")
      end
      File.write(File.join(src, "binding.c"), vm ? Binding.render(lib) : Binding.stubs(lib))
      File.write(File.join(dir, "include", "suppify", "#{lib.name}.h"), Glue.header(lib, [primary, *sealed]))
      if vm
        FileUtils.mkdir_p(File.join(dir, "mrblib"))
        File.write(File.join(dir, "mrblib", "#{lib.name}.rb"), lib.entries.map(&:mod).uniq.map { "module #{_1}\nend\n" }.join)
      end
      File.write(File.join(dir, "mrbgem.rake"), rake(lib, license, newlib, sealed))
      dir
    end

    # Copies the runtime flat into +src+. The regexp engine names its mruby shim as <mruby.h>;
    # the copies name it "mruby.h", so the shim beside them is read even where the real mruby's
    # headers come first on the include path. spinel/runtime.h, the header spin packages include,
    # goes to src/spinel/ and names the flat headers one level up.
    #: (String, String) -> void
    def vendor_runtime(runtime_dir, src)
      files = RUNTIME.flat_map { |pattern| Dir[File.join(runtime_dir, pattern)] }
      raise Error, "no spinel runtime sources in #{runtime_dir}" if files.none? { |f| File.basename(f) == "spinel_rt.h" }
      files.each { |f| File.binwrite(File.join(src, File.basename(f)), quote_mruby(f)) }
      Dir[File.join(runtime_dir, "regexp/shim/mruby/*.h")].each { |f| File.binwrite(File.join(src, "mruby", File.basename(f)), quote_mruby(f)) }
      Dir[File.join(runtime_dir, "spinel/*.h")].each do |f|
        File.binwrite(File.join(src, "spinel", File.basename(f)), File.binread(f).gsub(/#include "(\w+\.h)"/, '#include "../\1"'))
      end
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

    # The rake lines that build each sealed instance: the gem's runtime and kernel sources and the
    # instance's glue, compiled into build_dir/instances/<api>/ without common symbols, linked into
    # one relocatable object, with every symbol but the instance's exports made local.
    #: (Library, Array[Instance]) -> String
    def sealing(lib, sealed)
      return "" if sealed.empty?
      <<~RUBY
        shared = Dir["\#{dir}/src/*.c"] - ["\#{dir}/src/binding.c", "\#{dir}/src/#{lib.name}_glue.c"]
        seal = lambda do |out, objs, exports|
          *wrapper, cc = build.cc.command.split
          if `\#{cc} -dumpmachine`.include?("apple")
            File.write("\#{out}.exports", File.readlines(exports, chomp: true).map { "_\#{_1}" }.join("\\n"))
            sh(*wrapper, cc, "-r", "-nostdlib", "-Wl,-exported_symbols_list,\#{out}.exports", "-o", out, *objs)
          else
            sh(*wrapper, cc, "-r", "-nostdlib", "-o", "\#{out}.r", *objs)
            sh(cc.sub(/(gcc|clang|cc)(-[\\d.]+)?\\z/, "objcopy"), "--keep-global-symbols=\#{exports}", "\#{out}.r", out)
          end
        end
        #{sealed.map(&:api).inspect}.each do |api|
          glue = "\#{dir}/src/instances/\#{api}_glue.c"
          objs = [*shared, glue].map do |source|
            obj = objfile("\#{build_dir}/instances/\#{api}/\#{File.basename(source, ".c")}")
            first = objfile("\#{build_dir}/src/\#{source == glue ? "#{lib.name}_glue" : File.basename(source, ".c")}")
            file(obj => [source, first]) { spec.cc.run obj, source, [], source == glue ? ["\#{dir}/src"] : [], ["-fno-common"] }
            obj
          end
          sealed = objfile("\#{build_dir}/instances/\#{api}")
          file(sealed => objs) { |t| seal.(t.name, objs, "\#{dir}/src/instances/\#{api}.exports") }
          spec.objs << sealed
        end
      RUBY
    end

    #: (Library, String, bool, Array[Instance]) -> String
    def rake(lib, license, newlib, sealed)
      includes = lib.cflags.grep(/\A-I/).map { _1.delete_prefix("-I") }
      defines = lib.defines + lib.cflags.grep(/\A-D/).map { _1.delete_prefix("-D") }
      flags = lib.cflags.grep_v(/\A-[ID]/)
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
      link << "build.linker.flags.concat(#{lib.ldflags.inspect} - build.linker.flags)" unless lib.ldflags.empty?
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
          spec.cc.flags.concat(#{flags.inspect})
        #{"#{board}#{link.join("\n")}\n#{sealing(lib, sealed)}".gsub(/^/, '  ').gsub(/^  $/, '')}end
      RUBY
    end
  end
end
