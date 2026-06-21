# lib/suppify/builder.rb
require "fileutils"

module Suppify
  class Builder
    def initialize(spinel_lib: ENV["SPINEL_LIB"] || default_lib,
                   runner: method(:shell), copier: FileUtils.method(:cp))
      @spinel_lib = spinel_lib
      @runner = runner
      @copier = copier
    end

    def build(c_path:, lib_name:, out_dir:)
      o_path  = c_path.sub(/\.c\z/, ".o")
      archive = File.join(out_dir, "lib#{lib_name}.a")
      run! "cc -c #{c_path} -I#{@spinel_lib} -o #{o_path}"
      run! "ar rcs #{archive} #{o_path}"
      @copier.call(File.join(@spinel_lib, "libspinel_rt.a"),
                   File.join(out_dir, "libspinel_rt.a"))
      { archive: archive, runtime: File.join(out_dir, "libspinel_rt.a") }
    end

    def run!(cmd)
      out, status = @runner.call(cmd)
      raise Error, "command failed (#{status}): #{cmd}\n#{out}" unless status == 0
    end

    def shell(cmd)
      out = `#{cmd} 2>&1`
      [out, $?.exitstatus]
    end

    def default_lib
      ""
    end
  end
end
