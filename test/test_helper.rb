require "test/unit"
require "tmpdir"
require "open3"
require "suppify"

module Fixtures
  module_function

  CALC = File.expand_path("fixtures/calc.rb", __dir__)
  CALC_ENTRIES = %w[Calc.add Calc.half Calc.greet Calc.even? Calc.check Calc.nully Calc.blen Calc.ignore].freeze
  CALL_HOST = File.expand_path("fixtures/call_host.c", __dir__)

  def entry(name, ret, *params, mod: "Calc", cname: "sp_#{mod}_s_#{name}") = Suppify::Entry.new(mod:, name:, cname:, ret:, params:)

  def library(entries, runtime_dir: "/rt", cflags: [], libs: ["m", "crypt"], ldflags: [], sources: []) =
    Suppify::Library.new(name: "calc", kernel_c: "/* kernel */\n", kernel_h: "/* header */\n", entries:,
                         runtime_dir:, defines: ["SP_ONE_STRING"], cflags:, libs:, ldflags:, sources:)

  def which(cmd) = ENV["PATH"].split(File::PATH_SEPARATOR).map { File.join(_1, cmd) }.find { File.executable?(_1) }.to_s

  def spinel = ENV.fetch("SPINEL") { which("spinel") }

  def calc_gem(dir, *flags)
    Suppify::CLI.run([CALC, *CALC_ENTRIES, "-d", dir, *flags], spinel: Suppify::Spinel.new(bin: spinel))
    File.join(dir, "picoruby-calc")
  end

  def runtime_sources(gem) = Dir[File.join(gem, "src", "*.c")].reject { File.basename(_1) == "binding.c" }
end
