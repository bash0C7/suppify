# lib/suppify/cli.rb
require "fileutils"
require "suppify/core"
require "suppify/package"

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
      tmp_dir = ".suppify-tmp"
      FileUtils.mkdir_p(tmp_dir)
      ruby_source = File.read(opts[:input])
      c_path = File.join(tmp_dir, "#{opts[:lib_name]}.c")
      source = build_source(opts[:input], ruby_source, opts[:lib_name])
      rooted_path, rbs_dir = root_and_seed(source, opts[:input], ruby_source, c_path)

      emitted = SpinelRunner.new(rbs_dir: rbs_dir,
                                 ext_init: Suppify.kernel_init_name(opts[:lib_name]),
                                 ext_entries: source.ext_entries).emit(rooted_path, c_path)
      result = Pipeline.new(
        ruby_source: ruby_source,
        c_source: File.read(emitted[:c_path]),
        header_text: File.read(emitted[:header_path]),
        symbols_json: File.read(emitted[:symbols_path]),
        lib_name: opts[:lib_name],
        rbs_signatures: source.public_methods.empty? ? {} : source.export_signatures,
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
      built = Emitter::CArchive.new.build(c_path: emitted[:c_path],
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

    # The analyzed input: the Ruby plus the .rbs sidecar next to it, when
    # there is one. A sidecar is optional -- the method types can be written
    # inline above each def instead (Source merges the two and rejects a
    # method declared in both).
    def build_source(input_path, ruby_source, lib_name = nil)
      rbs_path = input_path.sub(/\.rb\z/, ".rbs")
      Source.new(ruby_source, rbs_source: File.exist?(rbs_path) ? File.read(rbs_path) : nil, lib_name: lib_name)
    end

    # spinel's --ext-entry exports only `Module.method` names and DCEs a
    # top-level method nothing calls, so the compiled copy of the source
    # gets a wrapper module (Source#rooted_source) whose entries delegate to
    # each public method. Its signatures reach spinel through the --rbs seed:
    # the wrapper's RBS (Source#wrapper_rbs_text) plus the input's own
    # sidecar and inline annotations, in one seed directory. spinel's --rbs
    # seed is a directory of .rbs files, all of which it reads, and it merges
    # several `class Object` blocks.
    # Returns [rooted_rb_path, rbs_dir_or_nil].
    def root_and_seed(source, input_path, ruby_source, c_path)
      rooted_path = c_path.sub(/\.c\z/, ".rooted.rb")
      if source.public_methods.empty?
        File.write(rooted_path, ruby_source)
        return [rooted_path, nil]
      end

      File.write(rooted_path, source.rooted_source) # raises, naming them, if a type is missing
      seed_dir = File.join(File.dirname(rooted_path), "rbs")
      FileUtils.rm_rf(seed_dir)
      FileUtils.mkdir_p(seed_dir)
      Dir[File.join(File.dirname(File.expand_path(input_path)), "*.rbs")].each { |f| FileUtils.cp(f, seed_dir) }
      inline = source.inline_rbs_text
      File.write(File.join(seed_dir, "_suppify_inline.rbs"), inline) if inline
      File.write(File.join(seed_dir, "_suppify_wrapper.rbs"), source.wrapper_rbs_text)
      [rooted_path, seed_dir]
    end
  end
end
