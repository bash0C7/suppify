# test/fixtures/flat.rb -- a kernel whose method types are written inline
# (no .rbs sidecar exists next to this file, on purpose) and which covers the
# type shapes the flat MessagePack entry has to carry.
#
# Every method is also plain Ruby, so the tests run the same file under CRuby
# and compare answers.

#: (Array[Integer], Integer) -> Integer
def scale_sum(xs, k)
  t = 0
  xs.each { |x| t += x * k }
  t
end

#: (Hash[Integer, Integer]) -> Hash[Integer, Integer]
def bump(h)
  o = {}
  h.each { |k, v| o[k] = v + 1 }
  o
end

#: (Array[Float]) -> Array[Float]
def dbl(xs) = xs.map { |x| x * 2.0 }

#: (Array[String], String) -> Array[String]
def tag(xs, s) = xs.map { |x| x + s }

#: (Hash[Symbol, Integer]) -> Hash[Symbol, Integer]
def sbump(h)
  o = {}
  h.each { |k, v| o[k] = v + 1 }
  o
end

#: (Array[Array[Integer]]) -> Array[Integer]
def rowsums(xs) = xs.map { |row| row.sum }

#: (Hash[String, Array[Float]], String) -> Array[Float]
def pick(h, k) = h[k]

#: ([Integer, String]) -> String
def second(t) = t[1].to_s

#: (Integer?) -> Integer?
def maybe(n) = n.nil? ? nil : n * 2

#: (bool, Integer) -> bool
def flip(b, n) = n.even? ? b : !b

#: (untyped) -> untyped
def echo(v) = v

# The `# @rbs` form, for the same scalar signature the sidecar spells
# `(Integer, Integer) -> Integer`.
# @rbs a: Integer
# @rbs b: Integer
# @rbs return: Integer
def add(a, b) = a + b

#: (Integer) -> Integer
def boom(n) = raise("bang #{n}")
