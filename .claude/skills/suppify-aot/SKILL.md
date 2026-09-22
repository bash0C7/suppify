---
name: suppify-aot
description: Use when adding AOT (spinel/suppify) native acceleration to a hot method in an existing Ruby or PicoRuby project, while keeping the interpreted version in-tree so the two can be benchmarked and switched between with a single toggle. Applies to CRuby gems and PicoRuby/mruby-c firmware (e.g. R2P2-ESP32).
---

# suppify-aot: accelerate an existing project's hot kernel, keep the interpreter for comparison

Take one hot method in an existing project, compile it to native with spinel→suppify,
and wire it so the interpreted original stays as the benchmark baseline and fallback.
The kernel has **one source of truth** (a plain-Ruby file), consumed two ways: run it
as Ruby (interpreted) or `require` the generated gem (native). The switch is one line.

## When this pays off (and when it doesn't)

AOT wins only when the work is shaped right — this is empirical, not a given. Before
doing anything, confirm the target method is:

- **compute-bound**, not I/O-bound. If the enclosing loop waits on I2C/SPI/serial/GC,
  making the math faster changes nothing. Profile first; accelerate the actual critical path.
- **amortizable per call**. Each native call pays a fixed boundary cost (VM dispatch +
  arg type-check + spinel's per-call `setjmp`). Measured on ESP32 mruby/c: ~23 µs/call.
  A scalar called once per iteration hides the speedup under that cost. A method that
  loops many times *inside one call* (pass a count/buffer, compute in bulk) amortizes it.
  Same kernel, ESP32: ~4× at 1 iter/call → ~150× at 4096 iters/call.
- **flat scalars in / scalar out**, no allocation. The method the VM calls is wrapped
  only when its types are `Integer`, `Float`, `String`, `bool`, `nil`, `void` (return);
  a method taking or returning `Array`/`Hash`/`Symbol` gets no VM binding at all — it is
  reachable only through the flat MessagePack entry (`<lib>_<m>_call`, for callers with
  no Ruby VM), and decoding one allocates, which drags in spinel's GC and its RAM. On a
  32-bit MCU, boundary values must fit 32 bits — pack wider results yourself (see the
  project's README "32bit" notes).

If it fails these, say so and stop — suppify won't help this method.

## Steps

Create a TodoWrite item per step.

### 1. Pick the kernel and extract it to a standalone source

The suppify input is a plain-Ruby file with the method(s) as **public top-level defs**,
each carrying an RBS method type. This same file is also the interpreted baseline — do
not fork the body.

```ruby
# kernel.rb  — the single source of truth for the kernel
#: (Integer, Integer) -> Integer
def mykernel(seed, n)
  # ... integer/float work, bounded loop, no allocation ...
end
```

The `#:` comment is required in the sense that spinel drops uncalled top-level methods
without a signature. A `kernel.rbs` sidecar next to `kernel.rb` does the same job if you
prefer a separate file (declare the methods under `class Object`) — but not both for the
same method.

Leave the original project code that *calls* this method untouched. If the method
currently lives inline in the app, move its body verbatim into `kernel.rb` and have the
app load it (see step 3) — the app's call sites don't change.

### 2. Generate the native gem

```sh
# PicoRuby / mruby-c firmware:
SPINEL_LIB=/path/to/spinel/lib ruby /path/to/suppify/suppify.rb kernel.rb -o mykernel -t picoruby
#   -> picoruby-mykernel/   (an mrbgem)

# CRuby project:
SPINEL_LIB=/path/to/spinel/lib ruby /path/to/suppify/suppify.rb kernel.rb -o mykernel -t cruby
#   -> mykernel/            (a native-extension gem)
```

`-o mykernel` names the gem and C API. The exported **Ruby method keeps its `def` name**
(`mykernel`), not the lib name. spinel must be discoverable (`PATH`/`SPINEL`, and
`SPINEL_LIB` for the gem targets). Never hand-edit generated C/gemspec/mrbgem.rake — to
change the kernel, edit `kernel.rb` and re-run suppify.

### 3. Wire the switch (the point of this skill)

Both backends expose the **identical method name**, so caller code is backend-agnostic.

**CRuby / host** — one conditional selects the backend:

```ruby
if ENV["AOT"]
  require "mykernel"        # native gem: defines top-level mykernel
else
  load "kernel.rb"          # interpreted: the same source suppify compiled
end
# ... app calls mykernel(...) unchanged ...
```

**PicoRuby firmware** — you flash one app, so keep two tiny sibling entrypoints that
differ only in the backend line (this is the proven, simplest form):

```ruby
# app_interp.rb
require "kernel"            # or inline the def; interpreted baseline
# ... driver ...

# app_aot.rb
require "mykernel"          # native mrbgem (activated by require on the mruby-c VM)
# ... identical driver ...
```

Build/flash whichever you want to run. On the mruby-c VM, `require 'mykernel'` is what
activates the gem (registration goes through picoruby-require's prebuilt-gem table); on
the full-mruby VM no require is needed. Embed the gem the way the project already embeds
mrbgems — `conf.gem gemdir: "/abs/path/to/picoruby-mykernel"` in its `build_config`, or
dropping `picoruby-mykernel/` into the firmware's mrbgems tree — follow the project's
existing convention, don't invent one.

### 4. Build so the gem actually reaches the artifact

**PicoRuby firmware (critical):** picoruby is often a CMake custom target inside the
firmware build. A plain incremental build (`idf.py build`, `rake build`) may **not**
recompile it, so edits/new gems silently never reach the flashed image and you debug a
stale binary. Force a full rebuild of the picoruby target (e.g. `idf.py fullclean` +
the project's clean-build task) whenever the gem or kernel changes.

Verify the gem is really in the artifact before trusting on-device behavior — grep the
binary for the exported method name or a known string:

```sh
strings -a build/<firmware>.bin | grep -c mykernel   # expect >= 1
```

**CRuby:** build the extension the ordinary way (`extconf.rb && make`, or a Bundler
`git:` source that builds on `bundle install`).

### 5. Benchmark: parity first, then timing

Prove correctness before speed. Run the interpreted and AOT kernels on the same inputs
and assert identical results; only then compare times. To measure the two in one binary,
give the baseline a distinct name (`mykernel_ref`) so both are callable at once:

```ruby
raise "mismatch" unless mykernel_ref(seed, n) == mykernel(seed, n)
# time each; drive with a LARGE n (bulk per call) so boundary cost is amortized
```

Sweep the per-call scope (small→large) to see the boundary cost amortize — a single
small-`n` number understates AOT. On a firmware target where host timing is coarse, keep
each measurement long enough (repeat K times with total work fixed) and read the serial
output directly rather than trusting a fragile sync layer.

### 6. Decide and record

Keep the AOT backend if it is genuinely faster on the real critical path. The interpreted
`kernel.rb` stays in-tree permanently as the benchmark baseline and the switch's fallback
— that coexistence is the deliverable, not scaffolding to delete.

## References

- suppify usage, targets, supported types, 32-bit boundary, error convention: the repo `README.md`.
- Worked interp-vs-AOT benchmark harnesses (both targets): `examples/fib/`.
- Design rationale: `docs/superpowers/specs/2026-06-21-suppify-design.md`.
