# suppify.rb
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "suppify"
exit Suppify::CLI.run(ARGV)
