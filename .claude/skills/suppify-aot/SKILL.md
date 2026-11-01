---
name: suppify-aot
description: Use when adding spinel-native acceleration (via suppify) to a hot method in an existing PicoRuby project (mruby or mruby/c VM, e.g. R2P2 firmware), while keeping the interpreted version in-tree so the two can be benchmarked and switched with a single toggle.
---

# suppify-aot: accelerate a PicoRuby kernel, keep the interpreter for comparison

One plain-Ruby kernel file is the single source of truth. The interpreter runs it as the
baseline, and suppify compiles it into a native mrbgem. Both expose the same module
methods, so the call sites stay the same.

## 1. Choose the tool

Follow the guide in suppify's `README.md`:

- On the mruby VM, try picoruby-aot first (`g.aot = true` in the build_config) and measure it.
- Use suppify when picoruby-aot measured too slow, on the mruby/c VM, or when C or a core with no VM calls the kernel.

suppify pays off for a method that is:

- **compute-bound**: its loop waits on no I2C, SPI, serial or GC. Profile first.
- **bulk per call**: each call pays a fixed boundary cost, so pass a count or a buffer and loop inside one call.
- **scalar at the boundary**: its arguments and return are `Integer`, `Float`, `bool`, `String` or `void`.
  On a 32-bit MCU, an `Integer` crosses as 32 bits.

When the method fails these, report that and stop.

## 2. Extract the kernel

Move the method body verbatim into a module of `def self.` methods, each with an inline `#:` type:

```ruby
# kernel.rb
module Mykernel
  #: (Integer, Integer) -> Integer
  def self.run(seed, n)
    # integer/float work in a bounded loop
  end
end
```

The kernel reaches board C functions through spinel's `ffi_func` (with `ffi_lib` / `ffi_cflags`
for the build). suppify passes those settings into the gem.

A firmware links one suppify gem, so all of its kernels go into this one file.

## 3. Generate the gem

```sh
SPINEL=/path/to/spinel ruby /path/to/suppify/suppify.rb kernel.rb Mykernel.run -o mykernel -d build [--newlib]
```

Use `--newlib` for a board whose C library is newlib. Edit `kernel.rb` and regenerate;
the generated files stay untouched.

## 4. Wire the switch

Keep two entrypoints that differ only in the backend line:

```ruby
# app_interp.rb
require "kernel"          # the interpreted baseline
# ... driver calling Mykernel.run ...

# app_aot.rb
require "mykernel"        # mruby/c (picoruby-require); on mruby the gem defines Mykernel at startup
# ... identical driver ...
```

Embed the gem the way the project embeds its other mrbgems, e.g. in the build_config:

```ruby
conf.gem gemdir: "/abs/path/to/build/picoruby-mykernel"
```

## 5. Build so the gem reaches the artifact

A firmware build that wraps PicoRuby in a CMake target can skip recompiling it. Do a full
rebuild of the PicoRuby target whenever the gem changes, then confirm the gem is in the image:

```sh
strings -a build/<firmware>.bin | grep -c Mykernel   # expect >= 1
```

## 6. Benchmark: parity first, then timing

To run both in one binary, rename the baseline module (`MykernelRef`):

```ruby
raise "mismatch" unless MykernelRef.run(seed, n) == Mykernel.run(seed, n)
```

Time each with a large `n`, and sweep `n` from small to large to see the boundary cost amortize.
Repeat each measurement long enough for the board's clock, and read the serial output directly.

## 7. Decide

Keep the gem when it is faster on the real critical path. `kernel.rb` stays in-tree as the
baseline and the fallback.
