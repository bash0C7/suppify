# lib/suppify/spinel_runner.rb
require "open3"

module Suppify
  class SpinelRunner
    # runner: callable(argv_array) -> [stdout_string, exit_status_int]
    # rbs_dir: directory of *.rbs sidecars fed to spinel's --rbs (advisory
    # type seeding; see RootInjector for why suppify needs this).
    def initialize(spinel_bin: ENV["SPINEL"] || "spinel", runner: method(:shell), rbs_dir: nil)
      @spinel_bin = spinel_bin
      @runner = runner
      @rbs_dir = rbs_dir
    end

    # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
    # emit modes (the symbol-map path short-circuits before the C-output
    # branch), so the two artifacts require separate invocations.
    def emit(rb_path, c_path)
      symbols_path = c_path.sub(/\.c\z/, "") + ".symbols.json"
      rbs_args = @rbs_dir ? ["--rbs", @rbs_dir] : []
      run!([@spinel_bin, rb_path, *rbs_args, "-c", "-o", c_path])
      run!([@spinel_bin, rb_path, "--emit-symbol-map", "-o", symbols_path])
      { c_path: c_path, symbols_path: symbols_path }
    end

    # Default runner: array-form argv, no shell involved.
    def shell(argv)
      out, status = Open3.capture2e(*argv)
      [out, status.exitstatus]
    end

    private

    def run!(argv)
      out, status = @runner.call(argv)
      raise Error, "spinel failed (#{status}): #{out}" unless status == 0
    end
  end
end
