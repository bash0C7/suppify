# test/test_flat_call_integration.rb -- end-to-end proof of the flat
# MessagePack entry: a kernel written with inline `#:` annotations only (no
# .rbs sidecar) is compiled by a real spinel, linked into a C driver that
# knows nothing but `<lib>_<m>_call`, and driven over a table of value
# shapes -- each answer compared against the same method running in CRuby.
#
# The CRuby comparison is made through the same wire encoding (a Symbol key
# comes back as a String, because MessagePack has no symbol type), so what
# is asserted is "the kernel answers what CRuby answers, as this wire format
# carries it".
require "test_helper"
require "suppify/cli"
require "msgpack_mini"
require "fileutils"
require "tmpdir"

class TestFlatCallIntegration < Test::Unit::TestCase
  FIXTURE = File.expand_path("fixtures/flat.rb", __dir__)
  METHODS = %w[scale_sum bump dbl tag sbump rowsums pick second maybe flip echo add boom].freeze

  # The same kernel under CRuby: its top-level defs become instance methods
  # of an anonymous module, so the reference answers come from plain Ruby
  # without the fixture polluting the test process's Object.
  REFERENCE = Object.new.extend(Module.new { module_eval(File.read(FIXTURE), FIXTURE) })

  class << self
    attr_accessor :build_dir
  end

  def spinel_available?
    !`which spinel`.strip.empty?
  rescue StandardError
    false
  end

  # One library + one driver for the whole file; the cases below are cheap,
  # the spinel compile is not.
  def setup
    omit("spinel not on PATH") unless spinel_available?
    return if self.class.build_dir

    dir = Dir.mktmpdir("suppify-flat-")
    at_exit { FileUtils.remove_entry(dir) if File.directory?(dir) }
    FileUtils.cp(FIXTURE, File.join(dir, "flat.rb"))
    Dir.chdir(dir) { Suppify::CLI.run(["flat.rb", "-o", "flatlib"]) }
    File.write(File.join(dir, "driver.c"), driver_source)
    Dir.chdir(dir) do
      assert system("cc driver.c -I. -L. -lflatlib #{SYS_LIBS} -o driver"), "driver failed to build"
    end
    self.class.build_dir = dir
  end

  # A driver with no knowledge of the kernel's types: it reads a MessagePack
  # request from a file, hands the bytes to <lib>_<m>_call, and writes back
  # the reply bytes plus the status and the signature string.
  def driver_source
    table = METHODS.map { |m| "  {\"#{m}\", flatlib_#{m}_call, flatlib_#{m}_signature}," }.join("\n")
    <<~C
      #include "flatlib.h"
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>

      typedef int32_t (*call_fn)(const uint8_t *, int32_t, uint8_t *, int32_t);
      typedef const char *(*sig_fn)(void);
      static struct ent { const char *name; call_fn call; sig_fn sig; } ents[] = {
      #{table}
        {0, 0, 0}
      };

      int main(int argc, char **argv) {
          static uint8_t in[1 << 20], out[1 << 20];
          int32_t cap = (int32_t)sizeof out, n, rc;
          struct ent *e;
          FILE *f;
          if (argc < 4) return 2;
          if (argc > 4) cap = (int32_t)atol(argv[4]);
          for (e = ents; e->name; e++) if (!strcmp(e->name, argv[1])) break;
          if (!e->name) return 2;
          f = fopen(argv[2], "rb");
          if (!f) return 2;
          n = (int32_t)fread(in, 1, sizeof in, f);
          fclose(f);
          flatlib_init();
          rc = e->call(in, n, out, cap);
          if (rc >= 0) { f = fopen(argv[3], "wb"); fwrite(out, 1, (size_t)rc, f); fclose(f); }
          printf("%d\\n%s\\n%s\\n", rc, e->sig(), rc == -3 ? flatlib_error_message() : "");
          return 0;
      }
    C
  end

  # Sends args (packed as one MessagePack array) to <m>_call; returns
  # [status, decoded_reply_or_nil, signature_string, error_message].
  def call(method, args, out_cap: nil, raw: nil)
    dir = self.class.build_dir
    inp = File.join(dir, "in.bin")
    outp = File.join(dir, "out.bin")
    File.binwrite(inp, raw || MsgPackMini.pack(args))
    FileUtils.rm_f(outp)
    argv = [File.join(dir, "driver"), method, inp, outp]
    argv << out_cap.to_s if out_cap
    lines = IO.popen(argv, &:read).lines
    status = lines[0].to_i
    [status, status >= 0 ? MsgPackMini.unpack(File.binread(outp)) : nil,
     lines[1].to_s.chomp, lines[2].to_s.chomp]
  end

  # What CRuby answers, carried through the same wire encoding.
  def reference(method, args)
    MsgPackMini.unpack(MsgPackMini.pack(REFERENCE.send(method, *args)))
  end

  def assert_matches_cruby(method, args)
    status, got, = call(method, args)
    assert_operator status, :>=, 0, "#{method}#{args.inspect} returned status #{status}"
    assert_equal reference(method, args), got, "#{method}#{args.inspect}"
  end

  # ---- the type table: every shape the boundary claims to carry.

  def test_integer_scalars_round_trip
    assert_matches_cruby("add", [2, 3])
    assert_matches_cruby("add", [-1, -2_000_000])
    assert_matches_cruby("add", [2_147_483_647, 0])   # int32 boundary
    assert_matches_cruby("add", [-2_147_483_648, 0])
    assert_matches_cruby("add", [0, 0])
  end

  def test_int_array_and_empty_container
    assert_matches_cruby("scale_sum", [[1, 2, 3], 10])
    assert_matches_cruby("scale_sum", [[], 10])
    assert_matches_cruby("scale_sum", [[-5, 0, 5], -3])
  end

  # Floats cross as binary64, so the specials survive bit for bit rather
  # than being narrowed to a float32 on the way.
  def test_float_array_specials
    assert_matches_cruby("dbl", [[1.5, 0.25, -2.75]])
    assert_matches_cruby("dbl", [[]])
    status, got, = call("dbl", [[-0.0, Float::INFINITY, -Float::INFINITY, 5e-324, 1.7976931348623157e308]])
    assert_operator status, :>=, 0
    assert_equal [-0.0, Float::INFINITY, -Float::INFINITY, 1.0e-323, Float::INFINITY], got
    assert_equal (-Float::INFINITY), 1.0 / got[0] # -0.0, not 0.0
    status, got, = call("dbl", [[Float::NAN]])
    assert_operator status, :>=, 0
    assert got[0].nan?, "NaN did not survive the round trip: #{got.inspect}"
  end

  def test_string_array_with_multibyte_and_empty
    assert_matches_cruby("tag", [%w[a bé 漢字], "!"])
    assert_matches_cruby("tag", [[], "!"])
    assert_matches_cruby("tag", [["", "x"], ""])
  end

  def test_int_hash_preserves_insertion_order
    args = [{ 30 => 1, 10 => 5, 20 => 9 }]
    assert_matches_cruby("bump", args)
    _status, got, = call("bump", args)
    assert_equal [30, 10, 20], got.keys, "Hash insertion order was not preserved"
    assert_matches_cruby("bump", [{}])
  end

  # A Symbol key has no MessagePack type of its own: it travels as a str and
  # is turned back into a Symbol on the way in because the RBS says Symbol.
  def test_symbol_keyed_hash
    assert_matches_cruby("sbump", [{ a: 1, bb: 2 }])
    assert_matches_cruby("sbump", [{}])
    _status, got, = call("sbump", [{ a: 1, bb: 2 }])
    assert_equal({ "a" => 2, "bb" => 3 }, got)
  end

  def test_nested_containers
    assert_matches_cruby("rowsums", [[[1, 2], [3], []]])
    assert_matches_cruby("rowsums", [[]])
    assert_matches_cruby("pick", [{ "a" => [1.0, 2.5], "b" => [] }, "a"])
    assert_matches_cruby("pick", [{ "a" => [1.0] }, "b"]) # missing key -> nil
  end

  def test_tuple
    assert_matches_cruby("second", [[7, "x"]])
    assert_equal(-1, call("second", [[7]])[0], "a tuple of the wrong arity must be rejected")
  end

  def test_optional_and_bool_and_nil
    assert_matches_cruby("maybe", [21])
    assert_matches_cruby("maybe", [nil])
    assert_matches_cruby("flip", [true, 3])
    assert_matches_cruby("flip", [false, 4])
  end

  # An `untyped` slot is decoded by the message's own types, so a whole
  # value tree crosses without the RBS naming its shape.
  def test_untyped_value_tree
    assert_matches_cruby("echo", [{ "a" => [1, nil, true, 2.5, "s"], "b" => { "c" => [[]] } }])
    assert_matches_cruby("echo", [[]])
    assert_matches_cruby("echo", [nil])
    assert_matches_cruby("echo", [-42])
  end

  # ---- the signature string is the RBS method type itself.

  def test_signature_strings
    assert_equal "(Array[Integer], Integer) -> Integer", call("scale_sum", [[], 1])[2]
    assert_equal "(Hash[Symbol, Integer]) -> Hash[Symbol, Integer]", call("sbump", [{}])[2]
    assert_equal "(Integer, Integer) -> Integer", call("add", [1, 1])[2] # from the `# @rbs` form
    assert_equal "(untyped) -> untyped", call("echo", [nil])[2]
  end

  # ---- the negative statuses.

  def test_malformed_input_is_status_1
    assert_equal(-1, call("add", [2])[0], "wrong argument count")
    assert_equal(-1, call("add", [2, 3, 4])[0], "wrong argument count")
    assert_equal(-1, call("add", ["x", 3])[0], "a str where Integer is declared")
    assert_equal(-1, call("scale_sum", [{ 1 => 2 }, 3])[0], "a map where Array is declared")
    assert_equal(-1, call("add", nil, raw: MsgPackMini.pack([2, 3])[0, 1])[0], "truncated message")
    assert_equal(-1, call("add", nil, raw: "")[0], "empty message")
    assert_equal(-1, call("dbl", [[1]])[0], "an int where Float is declared")
  end

  def test_output_buffer_too_small_is_status_2
    assert_equal(-2, call("scale_sum", [[1, 2], 10], out_cap: 0)[0])
    assert_equal(-2, call("dbl", [[1.0, 2.0]], out_cap: 4)[0])
    # one byte short of the reply is still -2, one byte over is not
    assert_equal(-2, call("tag", [["abc"], "d"], out_cap: 5)[0])
    assert_operator call("tag", [["abc"], "d"], out_cap: 6)[0], :>=, 0
  end

  def test_raised_kernel_is_status_3_with_the_message
    status, _got, _sig, message = call("boom", [7])
    assert_equal(-3, status)
    assert_equal "bang 7", message
    # the barrier resets: the next call still works
    assert_matches_cruby("add", [1, 2])
  end

  # A 64-bit value is carried by the wire format, but the kernel range-checks
  # it against this target's sp_int (8 bytes on this host, 4 on a 32-bit MCU)
  # and answers -4 rather than truncating. 2**63 is a legal MessagePack
  # uint64 that no sp_int holds, on any target.
  def test_integer_out_of_range_is_status_4
    raw = "\x92\xcf".b + [2**63].pack("Q>") + "\x01".b
    assert_equal(-4, call("add", nil, raw: raw)[0])
    assert_matches_cruby("add", [2**40, 1]) # in range on a 64-bit host
  end

  # INTPTR_MIN is the bit pattern spinel reserves as the in-band nil of an
  # int slot (SP_INT_NIL), so a genuine Integer equal to it reaches the
  # kernel as nil and the kernel raises -- suppify cannot tell the two
  # apart, and does not pretend to: the status says the kernel raised and
  # names it. On a 32-bit target the same applies to -2147483648.
  def test_the_int_nil_sentinel_value_raises_rather_than_computing
    status, _got, _sig, message = call("add", [-2**63, 1])
    assert_equal(-3, status)
    assert_match(/nil/, message)
  end

  # The exception-class table spinel emits into the generated TU used to be
  # the one set of unprefixed globals in a built library (the runtime's
  # ~1450 are renamed by the prelude, but these are not defined there), and
  # so collided between two suppify libraries in one binary. They are
  # renamed with everything else now. sp_ctx_swap still is not -- its name
  # lives inside an asm string literal (see the README).
  def test_generated_tu_globals_are_namespaced_in_the_archive
    defined_globals = IO.popen(["nm", "-g", "--defined-only",
                                File.join(self.class.build_dir, "libflatlib.a")],
                               err: File::NULL, &:read).lines
                        .filter_map { |l| l.split[2]&.sub(/\A_/, "") }
    assert_includes defined_globals, "flatlib_sp_exc_subclass_count"
    assert_includes defined_globals, "flatlib_sp_exc_subclass_ids"
    assert_not_includes defined_globals, "sp_exc_subclass_count"
    assert_not_includes defined_globals, "sp_exc_subclass_ids"
  end

  # The decoder builds its objects in the kernel's own heap; a large,
  # deeply nested message decoded thousands of times has to leave every
  # object rooted until its owner holds it, or a collection mid-decode
  # would sweep it.
  def test_repeated_large_messages_survive_collection
    tree = (1..200).map { |i| { "k#{i}" => [i, i.to_f, "値#{i}", [i, [i, "x"]], nil, true] } }
    30.times { assert_matches_cruby("echo", [tree]) }
  end
end
