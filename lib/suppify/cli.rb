module Suppify
  # `suppify <kernel.rb> <Mod.method>... [-o name] [-d out_dir] [--license id] [--cc cmd]
  #  [--no-vm] [--workers k] [--table name]`
  module CLI
    module_function

    USAGE = "usage: suppify <kernel.rb> <Mod.method>... [-o name] [-d out_dir] [--license id] [--cc cmd] " \
            "[--no-vm] [--workers k] [--table name]".freeze

    #: (Array[String], ?spinel: Spinel) -> Integer
    def run(argv, spinel: Spinel.new)
      opts = parse(argv)
      lib = spinel.compile(opts[:kernel], opts[:entries], name: opts[:name], cc: opts[:cc])
      dir = Mrbgem.write(lib, opts[:out_dir], **opts.slice(:license, :vm, :workers, :table))
      puts "wrote #{dir} (#{lib.entries.length} entries)"
      0
    end

    #: (Array[String]) -> { kernel: String, entries: Array[String], name: String, out_dir: String, license: String, cc: String?, vm: bool, workers: Integer, table: String? }
    def parse(argv)
      flags = { "-o" => :name, "-d" => :out_dir, "--license" => :license, "--cc" => :cc, "--workers" => :workers, "--table" => :table }
      switches = { "--no-vm" => [:vm, false] }
      opts = { out_dir: ".", license: "MIT", cc: nil, vm: true, workers: nil, table: nil }
      words = []
      args = argv.dup
      while (arg = args.shift)
        next opts.store(*switches[arg]) if switches.key?(arg)
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
      [opts[:name], opts[:table]].compact.each do |id|
        raise Error, "#{id} must be a C identifier" unless id.match?(/\A[A-Za-z_]\w*\z/)
      end
      opts[:workers] = workers(opts)
      opts.merge(kernel:, entries:)
    end

    # The worker count: as given, else 1 when a table is named or the VM is off, else 0.
    #: (Hash[Symbol, untyped]) -> Integer
    def workers(opts)
      return (opts[:table] || !opts[:vm] ? 1 : 0) unless opts[:workers]
      raise Error, "--workers takes a count: #{opts[:workers]}" unless opts[:workers].match?(/\A\d+\z/)
      count = Integer(opts[:workers])
      raise Error, "--table names worker 1's table; it needs --workers 1 or more" if opts[:table] && count.zero?
      raise Error, "--no-vm needs --workers 1 or more" if !opts[:vm] && count.zero?
      count
    end
  end
end
