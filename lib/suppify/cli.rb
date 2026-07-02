# lib/suppify/cli.rb
require "suppify/spinel_runner"
require "suppify/builder"
require "suppify/pipeline"
require "suppify/visibility"
require "suppify/rbs_seed"
require "suppify/root_injector"

module Suppify
  module CLI
    module_function

    # Minimal arg parsing (optparse-free so it compiles under spinel too).
    def parse(argv)
      input = nil
      lib_name = nil
      out_dir = "."
      i = 0
      while i < argv.length
        case argv[i]
        when "-o" then lib_name = argv[i + 1]; i += 2
        when "-d", "--out-dir" then out_dir = argv[i + 1]; i += 2
        else input = argv[i]; i += 1
        end
      end
      raise Error, "usage: suppify <app.rb> [-o name] [-d out_dir]" unless input
      lib_name ||= File.basename(input, ".rb")
      { input: input, lib_name: lib_name, out_dir: out_dir }
    end

    def run(argv, tmp_dir: ".suppify-tmp")
      opts = parse(argv)
      require "fileutils"
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

      File.write(emitted[:c_path], result[:c_source])
      File.write(File.join(opts[:out_dir], "#{opts[:lib_name]}.h"), result[:header])
      built = Builder.new.build(c_path: emitted[:c_path],
                                lib_name: opts[:lib_name], out_dir: opts[:out_dir])
      $stdout.puts "wrote #{built[:archive]} and #{opts[:lib_name]}.h " \
                   "(#{result[:exports].length} exports)"
      0
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
