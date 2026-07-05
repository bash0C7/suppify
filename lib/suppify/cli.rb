# lib/suppify/cli.rb
require "suppify/spinel_runner"
require "suppify/builder"
require "suppify/pipeline"
require "suppify/visibility"
require "suppify/rbs_seed"
require "suppify/root_injector"
require "suppify/emitter/cruby_gem"
require "suppify/emitter/picoruby_gem"
require "suppify/runtime_sources"

module Suppify
  module CLI
    module_function

    TARGETS = %w[c cruby picoruby].freeze

    # Only a valid C identifier is safe: lib_name is spliced verbatim into
    # #define replacement text by SymbolPrefix.prelude ("#define sym
    # lib_name_sym"), and any other character breaks the C preprocessor's
    # tokenization of every renamed runtime symbol (a hyphen, for example,
    # splits the replacement into an unrelated subtraction expression
    # between two undeclared identifiers instead of one valid name).
    LIB_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    # A lib_name equal to one of spinel's own runtime source basenames would
    # give the "c" target's archive two members both literally named
    # <basename>.o (the user's own generated <lib_name>.c and spinel's
    # <basename>.c), which some ar/toolchains mis-handle when unpacking by
    # member name.
    RESERVED_LIB_NAMES = RuntimeSources::SOURCES.map { |s| File.basename(s, ".c") }.freeze

    # Hand-rolled rather than OptionParser: flag_value! (below) must reject a
    # flag's value when it's missing or looks like another flag, which plain
    # OptionParser switches don't validate on their own.
    def parse(argv)
      input = nil
      lib_name = nil
      out_dir = "."
      target = "c"
      gem_version = "0.1.0"
      license = nil
      i = 0
      while i < argv.length
        case argv[i]
        when "-o" then lib_name = flag_value!(argv, i); i += 2
        when "-d", "--out-dir" then out_dir = flag_value!(argv, i); i += 2
        when "-t", "--target" then target = flag_value!(argv, i); i += 2
        when "--gem-version" then gem_version = flag_value!(argv, i); i += 2
        when "--license" then license = flag_value!(argv, i); i += 2
        else input = argv[i]; i += 1
        end
      end
      raise Error, "usage: suppify <app.rb> [-o name] [-d out_dir] [-t c|cruby|picoruby]" unless input
      raise Error, "unknown target #{target.inspect} (expected #{TARGETS.join('/')})" unless TARGETS.include?(target)
      lib_name ||= File.basename(input, ".rb")
      unless lib_name =~ LIB_NAME_PATTERN
        raise Error, "invalid library name #{lib_name.inspect} (must be a valid C identifier: " \
                     "letters, digits, underscore, not starting with a digit) -- pass -o explicitly"
      end
      if RESERVED_LIB_NAMES.include?(lib_name)
        raise Error, "library name #{lib_name.inspect} collides with a spinel runtime source file " \
                     "name -- pick a different -o"
      end
      { input: input, lib_name: lib_name, out_dir: out_dir, target: target,
        gem_version: gem_version, license: license }
    end

    # Rejects a missing value or one that looks like another flag, so a
    # forgotten/misordered argument (e.g. "--license -o mylib") raises a
    # clear error instead of silently swallowing the next flag or the
    # positional input filename as the value.
    def flag_value!(argv, i)
      flag = argv[i]
      v = argv[i + 1]
      raise Error, "#{flag} requires a value" if v.nil? || v.start_with?("-")
      v
    end

    def run(argv)
      opts = parse(argv)
      require "fileutils"
      tmp_dir = ".suppify-tmp"
      FileUtils.mkdir_p(tmp_dir)
      ruby_source = File.read(opts[:input])
      c_path = File.join(tmp_dir, "#{opts[:lib_name]}.c")
      rooted_path, rbs_dir = root_and_seed(opts[:input], ruby_source, c_path)

      emitted = SpinelRunner.new(rbs_dir: rbs_dir).emit(rooted_path, c_path)
      result = Pipeline.new(
        ruby_source: ruby_source,
        c_source: File.read(emitted[:c_path]),
        symbols_json: File.read(emitted[:symbols_path]),
        lib_name: opts[:lib_name],
      ).run

      case opts[:target]
      when "c"        then emit_c(opts, result, emitted)
      when "cruby"    then emit_gem(:cruby, opts, result)
      when "picoruby" then emit_gem(:picoruby, opts, result)
      end
      0
    end

    # The base target: a self-contained .a + neutral header, compiled here with
    # the host cc/ar (no cross-compilation).
    def emit_c(opts, result, emitted)
      File.write(emitted[:c_path], result[:c_source])
      File.write(File.join(opts[:out_dir], "#{opts[:lib_name]}.h"), result[:header])
      built = Builder.new.build(c_path: emitted[:c_path],
                                lib_name: opts[:lib_name], out_dir: opts[:out_dir])
      $stdout.puts "wrote #{built[:archive]} and #{opts[:lib_name]}.h " \
                   "(#{result[:exports].length} exports)"
    end

    # The cruby / picoruby targets: emit a buildable gem whose own source set
    # (generated C + spinel runtime sources + language binding) is compiled by
    # the consumer's toolchain — this is what makes cross-compilation work
    # without suppify carrying per-target toolchains.
    def emit_gem(kind, opts, result)
      spinel_lib = ENV["SPINEL_LIB"].to_s
      raise Error, "set SPINEL_LIB to spinel's lib dir for --target #{kind}" if spinel_lib.empty?

      if kind == :cruby
        gem_dir = File.join(opts[:out_dir], opts[:lib_name])
        Emitter::CRubyGem.emit(lib_name: opts[:lib_name], c_source: result[:c_source],
                               header: result[:header], exports: result[:exports],
                               spinel_lib: spinel_lib, out_dir: gem_dir,
                               version: opts[:gem_version], license: opts[:license])
      else
        gem_dir = File.join(opts[:out_dir], "picoruby-#{opts[:lib_name]}")
        # Unlike a CRuby gemspec, picoruby's mrbgem build hard-fails without
        # a license, so an unset (or explicitly empty -- "" is truthy in
        # Ruby and wouldn't trip a bare `||`) --license falls back to the
        # ecosystem's common permissive default instead of forwarding a
        # value picoruby's own hard-fail check wouldn't catch either.
        license = opts[:license].to_s.empty? ? "MIT" : opts[:license]
        Emitter::PicoRubyGem.emit(lib_name: opts[:lib_name], c_source: result[:c_source],
                                  header: result[:header], exports: result[:exports],
                                  spinel_lib: spinel_lib, out_dir: gem_dir,
                                  version: opts[:gem_version], license: license)
      end
      $stdout.puts "wrote #{kind} gem at #{gem_dir} (#{result[:exports].length} exports)"
    end

    # spinel DCEs any top-level method with no call site, regardless of
    # visibility, so public methods (the very ones suppify must export) get
    # silently dropped from the generated C unless something calls them. This
    # writes a "rooted" copy of the source with one synthetic, RBS-typed call
    # per public method appended, so spinel's reachability analysis keeps
    # them. Returns [rooted_rb_path, rbs_dir_or_nil].
    def root_and_seed(input_path, ruby_source, c_path)
      rooted_path = c_path.sub(/\.c\z/, ".rooted.rb")
      public_methods = Visibility.public_methods(ruby_source)
      if public_methods.empty?
        File.write(rooted_path, ruby_source)
        return [rooted_path, nil]
      end

      rbs_path = input_path.sub(/\.rb\z/, ".rbs")
      unless File.exist?(rbs_path)
        raise Error, "missing RBS sidecar #{rbs_path} (needed to type-export " \
                     "public method(s): #{public_methods.join(', ')})"
      end

      rbs_sigs = RbsSeed.parse(File.read(rbs_path))
      File.write(rooted_path, RootInjector.inject(ruby_source, public_methods, rbs_sigs))
      [rooted_path, File.dirname(File.expand_path(rbs_path))]
    end
  end
end
