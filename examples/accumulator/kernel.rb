module Acc
  # @rbs @sums: Array[Float]

  @sums = Array.new(4, 0.0)

  #: (Integer, Float) -> Float
  def self.add(slot, x)
    @sums[slot] = @sums.fetch(slot) + x
  end

  #: (Integer) -> Float
  def self.at(slot) = @sums[slot]

  #: (Integer) -> String
  def self.label(slot) = "slot #{slot}: #{@sums.fetch(slot)}"

  #: () -> void
  def self.reset
    @sums.fill(0.0)
    nil
  end
end
