# lib/suppify/spinel_runner.rb
module Suppify
  class SpinelRunner
    # runner: callable(cmd_string) -> [stdout_string, exit_status_int]
    def initialize(spinel_bin: ENV["SPINEL"] || "spinel", runner: method(:shell))
      @spinel_bin = spinel_bin
      @runner = runner
    end

    # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
    # emit modes (the symbol-map path short-circuits before the C-output
    # branch), so the two artifacts require separate invocations.
    def emit(rb_path, c_path)
      symbols_path = c_path.sub(/\.c\z/, "") + ".symbols.json"
      run!("#{@spinel_bin} #{rb_path} -c -o #{c_path}")
      run!("#{@spinel_bin} #{rb_path} --emit-symbol-map -o #{symbols_path}")
      { c_path: c_path, symbols_path: symbols_path }
    end

    # Default backtick runner (kept subset-compatible for Plan 2).
    def shell(cmd)
      out = `#{cmd} 2>&1`
      [out, $?.exitstatus]
    end

    private

    def run!(cmd)
      out, status = @runner.call(cmd)
      raise Error, "spinel failed (#{status}): #{out}" unless status == 0
    end
  end
end
