# lib/suppify/cli.rb
require "suppify/spinel_runner"
require "suppify/builder"
require "suppify/pipeline"

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
      c_path = File.join(tmp_dir, "#{opts[:lib_name]}.c")

      emitted = SpinelRunner.new.emit(opts[:input], c_path)
      result = Pipeline.new(
        ruby_source: File.read(opts[:input]),
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
  end
end
