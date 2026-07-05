# rakelib/spinel_pin.rb
module SpinelPin
  module_function

  def rt_members(makefile_text)
    line = makefile_text[/^RT_MEMBERS\s*=\s*(.*)$/, 1]
    raise "RT_MEMBERS not found in Makefile" unless line
    line.split
  end

  def diff_sources(makefile_text, known_sources)
    upstream = rt_members(makefile_text)
    known = known_sources.reject { |path| path.include?("/") }.map { |path| File.basename(path, ".c") }
    { added: upstream - known, removed: known - upstream }
  end
end
