$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "suppify"

begin
  exit Suppify::CLI.run(ARGV)
rescue Suppify::Error => e
  warn e.message
  exit 1
end
