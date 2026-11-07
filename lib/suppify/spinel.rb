require "json"
require "open3"
require "tmpdir"

module Suppify
  # One exported module method: its Ruby name, its C name and the C signature spinel's header states.
  Entry = Data.define(:mod, :name, :cname, :ret, :params) do
    # The suffix of every C function suppify generates for this entry (`K.even?` is `K_even_p`).
    #: () -> String
    def func = "#{mod}_#{cname.delete_prefix("sp_#{mod}_s_")}"
  end

  # What spinel's library output gives for one kernel.
  Library = Data.define(:name, :kernel_c, :kernel_h, :entries, :runtime_dir, :defines, :cflags, :libs, :ldflags, :sources)

  # Drives the spinel compiler and reads its library contract.
  class Spinel
    #: (?bin: String) -> void
    def initialize(bin: ENV.fetch("SPINEL", "spinel"))
      @bin = bin
    end

    # Compiles +kernel+ into a library named +name+ exporting +entries+ (`Mod.method`). +cc+ is the
    # board's C compiler; every spinel run gets it as `--cc=<cc>`, so spinel sizes Integer to that target.
    #: (String, Array[String], name: String, ?cc: String?) -> Library
    def compile(kernel, entries, name:, cc: nil)
      kernel = File.expand_path(kernel)
      target = cc ? ["--cc=#{cc}"] : []
      Dir.mktmpdir do |dir|
        c_path = File.join(dir, "#{name}_spinel.c")
        run(dir, kernel, *target, "-c", "--no-line-map", "--ext-init", "#{name}_spinel",
            "--ext-entry", entries.join(","), "-o", c_path)
        run(dir, kernel, *target, "--emit-symbol-map")
        cnames = symbol_map(Dir[File.join(dir, "*.symbols.json")].first)
        header = File.read(c_path.sub(/\.c\z/, ".h"))
        build = build_report(run(dir, kernel, *target, "--print-build"))
        Library.new(name:, kernel_c: File.read(c_path), kernel_h: header,
                    entries: entries.map { |e| entry(e, cnames, header) }, **build)
      end
    end

    private

    #: (String, *String) -> String
    def run(dir, *args)
      out, status = Open3.capture2e(@bin, *args, chdir: dir)
      raise Error, "spinel #{args.join(' ')} failed:\n#{out}" unless status.success?
      out
    end

    #: (String?) -> Hash[String, String]
    def symbol_map(path)
      raise Error, "spinel wrote no symbol map" unless path
      JSON.parse(File.read(path)).fetch("symbols").to_h { |s| [s["ruby"], s["c"]] }
    end

    #: (String) -> { runtime_dir: String, defines: Array[String], cflags: Array[String], libs: Array[String], ldflags: Array[String], sources: Array[String] }
    def build_report(text)
      lines = text.lines.map { |l| l.chomp.split(" ", 2) }
      values = ->(kind) { lines.filter_map { |k, v| v if k == kind } }
      runtime = values.("runtime").first or raise Error, "spinel did not report its runtime"
      libs, ldflags = values.("lib").partition { _1.start_with?("-l") }
      { runtime_dir: File.dirname(runtime),
        defines: values.("define").map { _1.delete_prefix("-D") },
        cflags: values.("cflag"),
        libs: libs.map { _1.delete_prefix("-l") },
        ldflags:,
        sources: values.("link").map { source_of(_1) } }
    end

    # The C source of an object spinel links: a package's `sp_<name>.o`, or its `_mt` variant.
    #: (String) -> String
    def source_of(object)
      source = object.sub(/(_mt)?\.[oa]\z/, ".c")
      raise Error, "spinel links #{object}, which has no C source beside it to build into the gem" unless File.file?(source)
      source
    end

    #: (String, Hash[String, String], String) -> Entry
    def entry(ruby_name, cnames, header)
      mod, name = ruby_name.split(".", 2)
      cname = cnames.fetch(ruby_name) { raise Error, "spinel did not export #{ruby_name}" }
      m = header.match(/^(.+?)\s*\b#{cname}\((.*)\);$/) or raise Error, "#{cname} is missing from spinel's header"
      params = m[2] == "void" ? [] : m[2].split(",").map { |p| p.strip.sub(/\s*\b\w+\z/, "") }
      Entry.new(mod:, name:, cname:, ret: m[1].strip, params:)
    end
  end
end
