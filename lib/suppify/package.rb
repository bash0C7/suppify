# lib/suppify/package.rb — the エミッタ layer: everything that turns a
# Pipeline result into a shippable artifact. Shared services first
# (RuntimeSources bundles spinel's runtime C; SymbolPrefix namespaces its
# global symbols per library), then one emitter per target under Emitter:
# CArchive (`-t c`: self-contained .a + header, host cc), CRubyGem
# (`-t cruby`: mkmf native-extension gem), PicoRubyGem (`-t picoruby`:
# picoruby mrbgem).
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "suppify/bindings"

module Suppify
  # Bundles the spinel runtime's C sources + headers so a consumer's own build
  # (mkmf for a CRuby gem, rake for a PicoRuby mrbgem, ...) compiles them with
  # the consumer's own toolchain and flags. This is what makes cross-compilation
  # "just work": suppify never cross-compiles the runtime itself — it ships the
  # sources and lets the target build do it. Sources are flattened into one
  # directory; the runtime's includes are all quoted same-dir references.
  module RuntimeSources
    module_function

    # The .c files archived into libspinel_rt.a (spinel Makefile's RT_MEMBERS +
    # the regexp objects), relative to spinel's lib/ dir. Kept explicit rather
    # than globbed so an unexpected extra .c in a future spinel doesn't silently
    # get pulled in. spinel's optional extension packages (json, stringio,
    # strscan, base64) live under packages/*, are NOT part of libspinel_rt.a, and
    # aren't needed by suppify's scalar-only exports, so they're intentionally
    # excluded here.
    SOURCES = %w[
      regexp/re_compile.c regexp/re_exec.c regexp/re_utf8.c
      sp_bigint.c sp_crypto.c sp_pack.c sp_time.c
      sp_core.c sp_net.c sp_system.c sp_gc.c sp_alloc.c sp_slab.c
      sp_marshal.c sp_format.c sp_string.c sp_inspect.c sp_dtoa.c
      sp_array.c sp_str.c sp_hash.c sp_proc.c sp_exc.c sp_random.c
      sp_re.c sp_fiber.c sp_sched.c sp_io.c sp_process.c
      sp_process_status.c sp_iobuffer.c sp_cold.c
    ].freeze

    # spinel's Fiber context switch is defined in a file-scope asm string
    # (sp_fiber.c), which a #define never reaches, so the prelude cannot
    # namespace it. The copied text can be rewritten instead: every spelling
    # of the name -- the ELF label, the Mach-O label with its leading
    # underscore, the ucontext-fallback definition, the prototype in
    # sp_fiber_ctx.h and each call site -- contains the substring, so one
    # substitution renames them all consistently.
    CTX_SWAP = "sp_ctx_swap"

    # With lib_name, the copy carries <lib_name>_sp_ctx_swap so no external
    # symbol is shared between two libraries; without it (symbol discovery)
    # the sources are copied as they are.
    def copy_flat(lib_dir, dest_dir, lib_name: nil)
      FileUtils.mkdir_p(dest_dir)
      sources = SOURCES.map do |rel|
        src = File.join(lib_dir, rel)
        raise Error, "spinel runtime source missing: #{src}" unless File.exist?(src)
        base = File.basename(rel)
        copy_file(src, File.join(dest_dir, base), lib_name)
        base
      end
      header_paths(lib_dir).each do |src|
        copy_file(src, File.join(dest_dir, File.basename(src)), lib_name)
      end
      { sources: sources }
    end

    def copy_file(src, dest, lib_name)
      return FileUtils.cp(src, dest) unless lib_name
      File.write(dest, File.binread(src).gsub(CTX_SWAP, "#{lib_name}_#{CTX_SWAP}"))
    end

    def header_paths(lib_dir)
      Dir[File.join(lib_dir, "*.h")] + Dir[File.join(lib_dir, "regexp", "*.h")]
    end
  end

  # spinel's vendored runtime (sp_gc.c, sp_alloc.c, ...) exposes ~600 global
  # (externally-linked) symbols shared by every generated program that links
  # against it. Fine for spinel's normal one-program-per-binary use, but two
  # suppify libraries linked into the same binary/firmware image would each
  # bring their own copy of that runtime and collide at link time. This
  # module discovers the exact symbol set from a real compile (rather than
  # guessing prefixes) and renders a C prelude that #defines each one to a
  # lib_name-specific name, so N suppify libraries can coexist.
  module SymbolPrefix
    module_function

    # Compiles the flattened runtime sources with the host cc (a throwaway,
    # discovery-only build -- the actual target build, possibly a cross
    # toolchain, does the real compile later) and returns every externally
    # linked (non-static) symbol name spinel's runtime defines. Symbol names
    # are portable across target architectures; only the object code differs.
    # sp_ctx_swap (spinel's Fiber context-switch primitive) is defined in a
    # file-scope __asm__ string, out of a #define's reach; RuntimeSources.
    # copy_flat renames it textually in each library's own copy of the
    # sources, so it is not part of the #define set here.
    EXCLUDED = %w[sp_ctx_swap].freeze

    # Globals the GENERATED translation unit defines (spinel emits them into
    # <lib>_gen.c: the user-defined exception class table), not the vendored
    # runtime -- so compiling lib/*.c never discovers them (they appear there
    # only as undefined references) and they stayed unprefixed, colliding
    # between two suppify libraries in one binary. The prelude is
    # force-included into every .c of a library, generated TU included, so a
    # #define here renames the definition and its references together.
    # Harmless if a future spinel stops emitting one: a #define with nothing
    # to rename has no effect.
    # With --ext-init the generated TU also defines the symbol/class lookups
    # (sp_sym_to_s, ...) as external symbols instead of statics.
    # _sp_proc_poly_ret / _sp_proc_poly_args (Proc call slots) are declared
    # extern by the runtime and defined by the generated TU.
    GENERATED_TU_SYMBOLS = %w[
      sp_exc_subclass_count sp_exc_subclass_ids
      sp_sym_to_s sp_sym_intern sp_sym_intern_n sp_class_to_s
      _sp_proc_poly_ret _sp_proc_poly_args
    ].freeze

    # spinel_rt.h -- included only by each generated program's own TU, not
    # by any of the lib/*.c sources -- embeds ~200 non-static function
    # bodies directly (spinel's normal build compiles it into exactly one
    # program TU per binary). Every suppify library's generated .c includes
    # it too, so scanning only lib/*.c misses these entirely, leaving them
    # unrenamed and colliding across libraries (confirmed empirically). This
    # stub mirrors what a generated TU provides (the three symbol/class
    # lookups spinel expects the program itself to define, always static
    # there) so compiling it surfaces the header-embedded symbols too.
    DISCOVERY_STUB = <<~C
      #include "spinel_rt.h"
      static const char *sp_sym_to_s(sp_sym id) { (void)id; return ""; }
      static sp_sym sp_sym_intern(const char *s) { (void)s; return (sp_sym)0; }
      static const char *sp_class_to_s(sp_Class c) { (void)c; return ""; }
    C

    # Compiled without SP_THREADS, so the handful of globals unique to
    # spinel's threaded runtime variant (sp_heap_lock, sp_sched_sleep,
    # sp_sched_wait_io) go unrenamed if the real target build ever compiles
    # suppify's bundled runtime with SP_THREADS -- nothing in suppify does
    # today (no target passes it through), so this is a dormant gap, not an
    # active one.
    def discover_runtime_symbols(spinel_lib)
      Dir.mktmpdir do |dir|
        RuntimeSources.copy_flat(spinel_lib, dir)
        File.write(File.join(dir, "_discovery_stub.c"), DISCOVERY_STUB)
        objs = Dir[File.join(dir, "*.c")].map do |c_path|
          o_path = c_path.sub(/\.c\z/, ".o")
          out = `cc -c #{c_path} -I#{dir} -o #{o_path} 2>&1`
          raise Error, "discovery compile failed for #{c_path}:\n#{out}" unless $?.success?
          o_path
        end
        ((parse_nm(`nm #{objs.join(' ')} 2>/dev/null`) - EXCLUDED) + GENERATED_TU_SYMBOLS).uniq
      end
    end

    # nm output is "<addr> <type> <name>"; an uppercase type letter means
    # external linkage (what we must rename), lowercase means file-local
    # (already collision-safe, left alone). Mach-O (macOS) prefixes every
    # symbol with an extra "_" that isn't part of the C identifier; ELF does
    # not, so there a leading "_" is the identifier's own (spinel's
    # _sp_ret_strbuf, _sp_proc_poly_args, ...) and must stay.
    def parse_nm(output, mach_o: RbConfig::CONFIG["host_os"].include?("darwin"))
      names = []
      output.each_line do |line|
        addr, type, name = line.split
        next unless addr && type && name && type =~ /\A[A-Z]\z/
        names << (mach_o ? name.sub(/\A_/, "") : name)
      end
      names.uniq.sort
    end

    KNOWN_HARMLESS_WARNINGS = %w[
      -Wunused-function
      -Wunused-variable
      -Wcomment
    ].freeze

    CLANG_ONLY_WARNINGS = %w[
      -Wmacro-redefined
      -Wmissing-noreturn
      -Wunterminated-string-initialization
      -Wshorten-64-to-32
    ].freeze

    # Force-included (-include) ahead of every .c file compiled for one
    # suppify library: renames every vendored runtime symbol to a lib_name-
    # prefixed name, and silences the vendored runtime's own harmless
    # warnings (portably -- clang-specific diagnostic names are guarded so a
    # plain-GCC cross toolchain, e.g. ESP32's, never sees an unknown pragma).
    def prelude(lib_name, symbols)
      out = +"/* Generated by suppify: per-library symbol namespacing + vendored-runtime warning triage. */\n"
      out << "#if defined(__clang__)\n"
      CLANG_ONLY_WARNINGS.each { |w| out << "#pragma clang diagnostic ignored \"#{w}\"\n" }
      out << "#endif\n"
      KNOWN_HARMLESS_WARNINGS.each { |w| out << "#pragma GCC diagnostic ignored \"#{w}\"\n" }
      symbols.each { |s| out << "#define #{s} #{lib_name}_#{s}\n" }
      out
    end
  end

  module Emitter
    # Emits the "c" target: compiles the generated translation unit AND a
    # bundled (recompiled, not prebuilt-copied) copy of the spinel runtime into
    # one self-contained lib<name>.a. The runtime is recompiled per library
    # (rather than reusing spinel's own prebuilt libspinel_rt.a) so its ~600
    # global symbols can be namespaced by SymbolPrefix -- otherwise two
    # suppify-built libraries linked into the same binary would collide on
    # spinel's shared runtime state.
    class CArchive
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
        copied = @copy_runtime.call(@spinel_lib, runtime_dir, lib_name: lib_name)

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

    # Assembles a complete, buildable CRuby native-extension gem from a
    # pipeline result. The gem compiles the spinel-generated C + the runtime
    # sources + the CRuby binding with the consumer's own Ruby toolchain
    # (mkmf), so the caller's Ruby (any platform) produces the native library.
    module CRubyGem
      module_function

      def emit(lib_name:, c_source:, header:, exports:, spinel_lib:, out_dir:,
               discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
               version: "0.1.0", license: nil)
        ext = File.join(out_dir, "ext", lib_name)
        lib = File.join(out_dir, "lib")
        FileUtils.mkdir_p(ext)
        FileUtils.mkdir_p(lib)

        File.write(File.join(ext, "#{lib_name}_gen.c"), c_source)
        File.write(File.join(ext, "#{lib_name}.h"), header)
        File.write(File.join(ext, "binding.c"), Binding::CRuby.render(lib_name, exports))
        RuntimeSources.copy_flat(spinel_lib, ext, lib_name: lib_name)

        symbols = discover_symbols.call(spinel_lib)
        File.write(File.join(ext, "#{lib_name}_prelude.h"), SymbolPrefix.prelude(lib_name, symbols))

        File.write(File.join(ext, "extconf.rb"), extconf(lib_name))
        File.write(File.join(lib, "#{lib_name}.rb"), %(require "#{lib_name}/#{lib_name}"\n))
        File.write(File.join(out_dir, "#{lib_name}.gemspec"), gemspec(lib_name, version, license))
      end

      def extconf(lib_name)
        <<~RUBY
          require "mkmf"
          # libm for the runtime's math (sp_format); harmless where libm is in libc.
          $LDFLAGS << " -lm"
          # Namespaces every vendored spinel runtime symbol to this library
          # (so a second suppify gem loaded into the same process doesn't
          # collide with this one's runtime state) and silences the bundled
          # runtime's own harmless warnings. See Suppify::SymbolPrefix.
          $CFLAGS << " -include \#{__dir__}/#{lib_name}_prelude.h"
          # All .c in this dir (generated TU, binding, flattened spinel runtime)
          # are picked up by mkmf's default *.c globbing.
          create_makefile("#{lib_name}/#{lib_name}")
        RUBY
      end

      # version/license are consumer-controlled: a placeholder version is
      # harmless, but presuming a license on the consumer's own code's
      # behalf would not be, so it's omitted unless explicitly given.
      # Both are rendered via #inspect (not raw interpolation) since the
      # emitted gemspec is literal Ruby source that gem build/bundle load
      # and execute -- an unescaped value could break out of the string
      # literal and splice arbitrary Ruby into the file.
      def gemspec(lib_name, version, license)
        <<~RUBY
          Gem::Specification.new do |s|
            s.name        = "#{lib_name}"
            s.version     = #{version.inspect}
            s.summary     = "suppify-generated native extension"
            s.authors     = ["suppify"]
            #{"s.license      = #{license.inspect}\n" if license}
            s.files       = Dir["lib/**/*.rb"] + Dir["ext/**/*.{c,h,rb}"]
            s.extensions  = ["ext/#{lib_name}/extconf.rb"]
            s.required_ruby_version = ">= 3.0"
          end
        RUBY
      end
    end

    # Assembles a PicoRuby/mruby mrbgem from a pipeline result. The gem's
    # src/*.c (spinel-generated TU + runtime sources + mruby binding) are
    # compiled into libmruby.a by the consumer's own picoruby cross build, so
    # the target toolchain and ABI flags (-mlongcalls, MRB_NO_BOXING, ...) are
    # applied by that build — suppify never cross-compiles anything itself.
    # Add to a build with: conf.gem gemdir: "<out_dir>".
    module PicoRubyGem
      module_function

      def emit(lib_name:, c_source:, header:, exports:, spinel_lib:, out_dir:,
               discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
               version: "0.1.0", license: "MIT")
        gem_name = "picoruby-#{lib_name}"
        init_func = "mrb_#{gem_name.tr('-', '_')}_gem_init"
        src = File.join(out_dir, "src")
        inc = File.join(out_dir, "include")
        mrblib = File.join(out_dir, "mrblib")
        FileUtils.mkdir_p(src)
        FileUtils.mkdir_p(inc)
        FileUtils.mkdir_p(mrblib)

        File.write(File.join(src, "#{lib_name}_gen.c"), c_source)
        File.write(File.join(src, "#{lib_name}.h"), header) # quoted include from src/*.c
        File.write(File.join(inc, "#{lib_name}.h"), header)  # public header for consumers
        File.write(File.join(src, "binding.c"), render_binding(lib_name, init_func, exports))
        File.write(File.join(mrblib, "#{lib_name}.rb"), mrblib_stub(lib_name))
        RuntimeSources.copy_flat(spinel_lib, src, lib_name: lib_name)

        symbols = discover_symbols.call(spinel_lib)
        File.write(File.join(src, "#{lib_name}_prelude.h"), SymbolPrefix.prelude(lib_name, symbols))

        File.write(File.join(out_dir, "mrbgem.rake"), mrbgem_rake(gem_name, lib_name, version, license))
      end

      # A single binding.c that adapts to whichever VM the consumer's own
      # picoruby build selects: PICORB_VM_MRUBYC (mruby/c -- PicoRuby's
      # default, and what microcontroller targets like R2P2-ESP32 actually
      # run) gets the mrubyc-native registration; anything else (full mruby,
      # PICORB_VM_MRUBY) keeps today's mrb_define_method binding. Mirrors
      # the #if/#elif VM dispatch already used by this ecosystem's other
      # hand-written mrubyc gems (e.g. picoruby-irq's src/irq.c).
      def render_binding(lib_name, init_func, exports)
        <<~C
          #if defined(PICORB_VM_MRUBYC)
          #{Binding::Mrubyc.render(lib_name, init_func, exports)}
          #else
          #{Binding::Mruby.render(lib_name, init_func, exports)}
          #endif
        C
      end

      # Load-bearing even though it defines nothing: picoruby-require's
      # collect_gems task only puts a gem into the mrubyc prebuilt_gems[]
      # require table if the gem has mrblib/*.rb to compile into the
      # table's bytecode entry. Without it, `require '<lib>'` fails and
      # mrbc_<lib>_init (which registers the native methods) never runs.
      def mrblib_stub(lib_name)
        <<~RUBY
          # #{lib_name} is a suppify-generated native gem. Its Ruby-visible
          # methods are C functions registered on Object by mrbc_#{lib_name.tr('-', '_')}_init
          # (src/binding.c) when this gem is required; this file only anchors
          # the gem in picoruby-require's prebuilt gem table.
        RUBY
      end

      # version/license are consumer-controlled: a placeholder version is
      # harmless, but presuming a license on the consumer's own code's
      # behalf would not be, so it's omitted unless explicitly given. Both
      # are rendered via #inspect (not raw interpolation) since mrbgem.rake
      # is literal Ruby source that picoruby's Rake build loads and
      # executes -- an unescaped value could break out of the string
      # literal and splice arbitrary Ruby into the file.
      def mrbgem_rake(gem_name, lib_name, version, license)
        <<~RUBY
          MRuby::Gem::Specification.new('#{gem_name}') do |spec|
            spec.version = #{version.inspect}
            spec.author  = 'suppify'
            spec.summary = 'suppify-generated native gem'
            #{"spec.license = #{license.inspect}\n" if license}
            # Public neutral header for firmware/consumer code.
            spec.cc.include_paths << "\#{dir}/include"
            # libm for the spinel runtime's math (harmless where libm is in libc).
            spec.linker.libraries << 'm'
            # glibc keeps crypt(3) (String#crypt) in libcrypt; a host build on Linux
            # links it. Cross builds are left alone.
            spec.linker.libraries << 'crypt' if !build.is_a?(MRuby::CrossBuild) && RbConfig::CONFIG['host_os'].include?('linux')
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
