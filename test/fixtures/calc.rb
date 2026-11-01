module Calc
  #: (Integer, Integer) -> Integer
  def self.add(a, b) = a + b

  #: (Float) -> Float
  def self.half(x) = x / 2.0

  #: (String) -> String
  def self.greet(name) = "hi, " + name

  #: (Integer) -> bool
  def self.even?(n) = n % 2 == 0

  #: (Integer) -> Integer
  def self.check(n)
    raise ArgumentError, "negative" if n < 0
    n
  end

  #: () -> String
  def self.nully = "a\0b"

  #: (String) -> Integer
  def self.blen(s) = s.bytesize

  #: (Integer) -> void
  def self.ignore(n)
    n + 1
    nil
  end
end
