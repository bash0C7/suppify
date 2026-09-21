# test/msgpack_mini.rb — a MessagePack codec for the tests only.
#
# The flat-message entries suppify generates speak MessagePack, so the tests
# have to speak it too: this packs the call arguments a test sends and
# unpacks the reply it gets back, then compares both against plain CRuby.
# Deliberately a test fixture rather than a runtime dependency -- suppify
# itself never encodes MessagePack (the generated C does), and a consumer
# picks whichever MessagePack library its own language already has.
#
# Covers exactly the types the boundary carries: nil, bool, Integer, Float
# (always float64, so a binary64 survives bit for bit), String (UTF-8 or
# binary bytes), Symbol (packed as str, as the wire format has no symbol),
# Array, Hash.
module MsgPackMini
  module_function

  def pack(obj)
    case obj
    when nil        then [0xc0].pack("C")
    when true       then [0xc3].pack("C")
    when false      then [0xc2].pack("C")
    when Integer    then pack_int(obj)
    when Float      then [0xcb].pack("C") + [obj].pack("G")
    when Symbol     then pack_str(obj.to_s)
    when String     then pack_str(obj)
    when Array      then pack_seq(0x90, 0xdc, 0xdd, obj.length) + obj.map { |e| pack(e) }.join
    when Hash
      pack_seq(0x80, 0xde, 0xdf, obj.length) +
        obj.map { |k, v| pack(k) + pack(v) }.join
    else raise ArgumentError, "MsgPackMini cannot pack #{obj.class}"
    end
  end

  def pack_int(n)
    case n
    when 0..0x7f                then [n].pack("C")
    when -32..-1                then [n].pack("c")
    when -0x80..0x7f            then [0xd0, n].pack("Cc")
    when -0x8000..0x7fff        then [0xd1, n].pack("Cs>")
    when -0x8000_0000..0x7fff_ffff then [0xd2, n].pack("Cl>")
    else [0xd3, n].pack("Cq>")
    end
  end

  def pack_str(s)
    b = s.dup.force_encoding(Encoding::BINARY)
    head = if b.bytesize < 32 then [0xa0 | b.bytesize].pack("C")
           elsif b.bytesize < 256 then [0xd9, b.bytesize].pack("CC")
           elsif b.bytesize < 65_536 then [0xda, b.bytesize].pack("Cn")
           else [0xdb, b.bytesize].pack("CN")
           end
    head + b
  end

  def pack_seq(fix, wide16, wide32, n)
    return [fix | n].pack("C") if n < 16
    return [wide16, n].pack("Cn") if n < 65_536
    [wide32, n].pack("CN")
  end

  # Returns the decoded value; raises if the buffer holds anything else.
  def unpack(bytes)
    value, rest = read(bytes.dup.force_encoding(Encoding::BINARY))
    raise ArgumentError, "trailing MessagePack bytes: #{rest.bytesize}" unless rest.empty?
    value
  end

  def read(s)
    t = s.getbyte(0)
    rest = s.byteslice(1..) || +""
    case t
    when 0xc0 then [nil, rest]
    when 0xc2 then [false, rest]
    when 0xc3 then [true, rest]
    when 0x00..0x7f then [t, rest]
    when 0xe0..0xff then [t - 256, rest]
    when 0xcc then int(rest, 1, "C")
    when 0xcd then int(rest, 2, "n")
    when 0xce then int(rest, 4, "N")
    when 0xcf then int(rest, 8, "Q>")
    when 0xd0 then int(rest, 1, "c")
    when 0xd1 then int(rest, 2, "s>")
    when 0xd2 then int(rest, 4, "l>")
    when 0xd3 then int(rest, 8, "q>")
    when 0xca then int(rest, 4, "g")
    when 0xcb then int(rest, 8, "G")
    when 0xa0..0xbf then str(rest, t & 0x1f)
    when 0xd9 then n, r = int(rest, 1, "C"); str(r, n)
    when 0xda then n, r = int(rest, 2, "n"); str(r, n)
    when 0xdb then n, r = int(rest, 4, "N"); str(r, n)
    when 0x90..0x9f then seq(rest, t & 0x0f)
    when 0xdc then n, r = int(rest, 2, "n"); seq(r, n)
    when 0xdd then n, r = int(rest, 4, "N"); seq(r, n)
    when 0x80..0x8f then map(rest, t & 0x0f)
    when 0xde then n, r = int(rest, 2, "n"); map(r, n)
    when 0xdf then n, r = int(rest, 4, "N"); map(r, n)
    else raise ArgumentError, format("unknown MessagePack tag 0x%02x", t)
    end
  end

  def int(s, n, fmt)
    [s.byteslice(0, n).unpack1(fmt), s.byteslice(n..) || +""]
  end

  def str(s, n)
    [s.byteslice(0, n).force_encoding(Encoding::UTF_8), s.byteslice(n..) || +""]
  end

  def seq(s, n)
    out = []
    n.times { v, s = read(s); out << v }
    [out, s]
  end

  def map(s, n)
    out = {}
    n.times do
      k, s = read(s)
      v, s = read(s)
      out[k] = v
    end
    [out, s]
  end
end
