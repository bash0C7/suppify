module Suppify
  # `suppify <kernel.rb> <Mod.method>... [-o name] [-d out_dir] [--license id] [--newlib]`
  module CLI
    module_function

    USAGE = "usage: suppify <kernel.rb> <Mod.method>... [-o name] [-d out_dir] [--license id] [--newlib]".freeze

    #: (Array[String], ?spinel: Spinel) -> Integer
    def run(argv, spinel: Spinel.new)
      opts = parse(argv)
      lib = spinel.compile(opts[:kernel], opts[:entries], name: opts[:name])
      dir = Mrbgem.write(lib, opts[:out_dir], license: opts[:license], newlib: opts[:newlib])
      puts "wrote #{dir} (#{lib.entries.length} entries)"
      0
    end

    #: (Array[String]) -> { kernel: String, entries: Array[String], name: String, out_dir: String, license: String, newlib: bool }
    def parse(argv)
      flags = { "-o" => :name, "-d" => :out_dir, "--license" => :license }
      opts = { out_dir: ".", license: "MIT", newlib: false }
      words = []
      args = argv.dup
      while (arg = args.shift)
        next opts[:newlib] = true if arg == "--newlib"
        raise Error, "unknown option #{arg}\n#{USAGE}" if arg.start_with?("-") && !flags.key?(arg)
        next words << arg unless flags.key?(arg)
        opts[flags[arg]] = args.shift or raise Error, "#{arg} needs a value\n#{USAGE}"
      end
      kernel, *entries = words
      raise Error, USAGE if kernel.nil? || entries.empty?
      bad = entries.grep_v(/\A[A-Z]\w*\.\w+[?!]?\z/)
      raise Error, "entries must be Module.method: #{bad.join(', ')}" unless bad.empty?
      twice = entries.tally.select { |_, n| n > 1 }.keys
      raise Error, "entries listed more than once: #{twice.join(', ')}" unless twice.empty?
      opts[:name] ||= File.basename(kernel, ".rb")
      raise Error, "-o must be a C identifier: #{opts[:name]}" unless opts[:name].match?(/\A[A-Za-z_]\w*\z/)
      opts.merge(kernel:, entries:)
    end
  end
end
