# suppify.rb  (compiled by spinel in Plan 2; runs under CRuby for dev)
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "suppify"
require "suppify/cli"
exit Suppify::CLI.run(ARGV)
