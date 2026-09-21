# suppify

`suppify` converts a Ruby program that [spinel](https://github.com/matz/spinel)
(a Ruby AOT compiler) can compile into a **neutral, linkable C library**
(`.a` + header) — callable from any plain-C-ABI consumer, without spinel
itself being modified, and without spinel being needed at the consumer's
build or run time. Design rationale: `docs/superpowers/specs/2026-06-21-suppify-design.md`.

## Status

The `c`, `cruby`, and `picoruby` targets are implemented and verified
end-to-end against a real `spinel` (for `picoruby`, against a real
picoruby host build).

Two ways to call an exported method, with different reach:

- the **plain C entry** (`intptr_t add(intptr_t, intptr_t)`) — scalars only
  (`Integer`, `Float`, `String`, `bool`, `void`), and what the CRuby /
  PicoRuby bindings wrap;
- the **flat-message entry** (`<lib>_add_call`, one MessagePack message in,
  one out) — every type spinel can represent, including `Array`, `Hash`,
  `Symbol`, tuples, optionals and `untyped`, nested at any depth. See
  [The flat-message entry](#the-flat-message-entry-messagepack).

Known limits: top-level methods only; no custom classes; whatever spinel
itself cannot type (see [What crosses the
boundary](#what-crosses-the-boundary)). Work in flight is tracked in
`HANDOFF.md`. Treat this as a working core, not a finished,
broadly-hardened tool.

## Requirements

- Ruby (this repo's own tooling; not needed by consumers of the generated
  library)
- [spinel](https://github.com/matz/spinel), built and either on `PATH` or
  pointed at via env vars (see below). Build it with `make deps && make`
  (see spinel's own README).
- A C toolchain: `cc` and `ar`.

## Setup

```sh
bundle install
```

spinel is discovered like `cc` would be — not vendored, not a git
dependency:

- binary: `PATH`, or the `SPINEL` env var
- runtime (`spinel_rt.h` / `libspinel_rt.a`): the `SPINEL_LIB` env var
  (defaults to empty, i.e. current directory)

suppify targets exactly the spinel commit recorded in `spinel.pin` at the repo
root — never a range of versions. `rake spinel:latest` / `spinel:check_pin` /
`spinel:bump_pin` track and advance that pin; see the `spinel-tracking` skill
(`.claude/skills/spinel-tracking/`).

## Usage

```sh
ruby suppify.rb app.rb -o libname [-d out_dir] [-t c|cruby|picoruby]
```

| Argument | Meaning | Default |
|---|---|---|
| positional (first non-flag arg) | input `.rb` path | required — raises `Suppify::Error` if missing |
| `-o <name>` | output library name (`lib<name>.a` / `<name>.h`) | input filename without `.rb` (e.g. `app.rb` → `app`) |
| `-d <dir>` / `--out-dir <dir>` | output directory | `.` (current directory) |
| `-t <target>` / `--target <target>` | output target: `c`, `cruby`, or `picoruby` (see [Targets](#targets)) | `c` |
| `--gem-version <version>` | `cruby`/`picoruby` only: the emitted gem/mrbgem's version | `0.1.0` |
| `--license <name>` | `cruby`/`picoruby` only: the emitted gem/mrbgem's license | unset for `cruby` (omitted from the gemspec); `MIT` for `picoruby` (its build requires one) |

The `.rbs` sidecar isn't a flag — it's looked up automatically next to the
input file, same basename (e.g. `foo/app.rb` → `foo/app.rbs`), and it is
optional: the method types can be written inline above each `def` instead
(see [Every exported method needs an RBS method
type](#every-exported-method-needs-an-rbs-method-type)). There's no
`--spinel-bin` / `--spinel-lib` flag yet; spinel is only discovered via
`PATH` and the `SPINEL` / `SPINEL_LIB` env vars described above.

With the default `c` target, produces in `out_dir` (default `.`):

- `liblibname.a` — your compiled program, self-contained: it bundles a
  recompiled, namespaced copy of spinel's runtime (consumers never need
  spinel installed, and never link a separate runtime archive)
- `libname.h` — a **neutral** header (no spinel types leak through; see
  [What crosses the boundary](#what-crosses-the-boundary) below)

## Targets

The neutral C library is the substrate; a `--target` selects how it's
surfaced to a consumer ecosystem. All targets share the same
spinel→neutral-C core (same `.rbs`, same supported types, same error
convention); they differ only in the binding they generate and how the
result is packaged.

| Target | Output | Consumed by |
|---|---|---|
| `c` (default) | self-contained `liblibname.a` + neutral `libname.h`, **compiled here** with the host `cc`/`ar` | any C program, linked directly (see [Example](#example)) |
| `cruby` | a buildable **CRuby native-extension gem** (`ext/.../extconf.rb` + `*.gemspec`) under `out_dir/libname` | CRuby, via a Bundler `git:` source — the AOT-compiled methods become ordinary Ruby methods |
| `picoruby` | a buildable **PicoRuby mrbgem** (`mrbgem.rake` + `src/`) under `out_dir/picoruby-libname` | PicoRuby, via `conf.gem gemdir:` in a build_config |

The `cruby` and `picoruby` targets require `SPINEL_LIB` to be set (they
bundle the spinel runtime **sources**). They do **not** compile anything
themselves — the emitted gem carries the generated C plus the spinel
runtime sources plus the language binding, and the consumer's own build
(mkmf for `cruby`, the picoruby rake build for `picoruby`) compiles it all
with the consumer's toolchain and flags. That delegation is what lets a
`picoruby` gem cross-compile for ESP32, iOS, etc.: whatever toolchain the
target's picoruby build uses compiles suppify's sources too, so the ABI
always matches.

Same call site across targets — the exported top-level methods are callable
exactly as written (`add(2, 3)`), whether from C, CRuby, or PicoRuby.

### cruby target example

1. Write the Ruby source and its `.rbs` sidecar (the same `add`/`boom` example
   used above):

   ```ruby
   # app.rb
   def add(a, b) = a + b
   def boom = raise "x"
   ```

   ```
   # app.rbs
   class Object
     def add: (Integer, Integer) -> Integer
     def boom: () -> void
   end
   ```

2. Run `suppify` with `-t cruby`. `--gem-version` and `--license` are
   optional and only matter for this target's `.gemspec` (the `c` target
   ignores them entirely):

   ```sh
   SPINEL_LIB=/path/to/spinel/lib \
     ruby suppify.rb app.rb -o addlib -t cruby --gem-version 1.0.0 --license MIT
   ```

   This leaves a buildable gem tree under `addlib/` (default `out_dir` is
   `.`):

   ```
   addlib/
     addlib.gemspec
     lib/addlib.rb
     ext/addlib/
       extconf.rb
       addlib.h
       addlib_gen.c
       binding.c
       addlib_prelude.h
       <spinel runtime sources, copied flat>
   ```

   Because `--license MIT` was passed, `addlib.gemspec` includes
   `s.license = "MIT"`; omit the flag and that line is left out of the
   gemspec entirely rather than guessing a license on your behalf.

3. Build the native extension with the consumer's own Ruby toolchain
   (`mkmf`) — ordinary extension building, nothing suppify-specific.
   `extconf.rb` writes its `Makefile` and compiled output into the current
   directory, so build from inside `ext/addlib` itself, not the gem root:

   ```sh
   cd addlib
   (cd ext/addlib && ruby extconf.rb && make)
   ```

4. Require the built extension and call the exported method as an ordinary
   Ruby method (still from `addlib/`):

   ```sh
   ruby -r./ext/addlib/addlib -e 'p add(2, 3)'   # => 5
   ```

5. Add it to a consumer project's `Gemfile` as a Bundler `git:` source —
   no `gem build` / `gem install` needed. Bundler's `git:` source builds
   native extensions itself (`bundle install` runs `extconf.rb`/`make` for
   you); a `path:` source does not, which is why `git:` is used here.
   Still inside `addlib/` from step 4, turn it into a git repo, then step
   back out to create a sibling `consumer/` directory:

   ```sh
   git init -q && git add -A && git commit -q -m "addlib"
   cd .. && mkdir consumer && cd consumer
   ```

   ```ruby
   # consumer/Gemfile
   source "https://rubygems.org"
   gem "addlib", git: "#{__dir__}/../addlib"
   ```

   ```sh
   bundle install
   bundle exec ruby -e 'require "addlib"; p add(2, 3)'   # => 5
   ```

   `git: "#{__dir__}/../addlib"` is a local path here for demonstration —
   any git remote (GitHub, a private server, ...) works the same way once
   `addlib` is pushed there.

### picoruby target example

1. Write the Ruby source and its `.rbs` sidecar (the same `add`/`boom`
   example used above):

   ```ruby
   # app.rb
   def add(a, b) = a + b
   def boom = raise "x"
   ```

   ```
   # app.rbs
   class Object
     def add: (Integer, Integer) -> Integer
     def boom: () -> void
   end
   ```

2. Run `suppify` with `-t picoruby -o addlib`. The emitted directory is
   named `picoruby-addlib`, not `addlib`:

   ```sh
   SPINEL_LIB=/path/to/spinel/lib \
     ruby suppify.rb app.rb -o addlib -t picoruby
   ```

   ```
   picoruby-addlib/
     mrbgem.rake
     include/addlib.h        # public neutral header for consumer/firmware code
     mrblib/addlib.rb        # stub anchoring the gem in picoruby-require's prebuilt gem table
     src/
       addlib.h               # same header, quoted-include form for src/*.c
       addlib_gen.c
       binding.c
       addlib_prelude.h
       <spinel runtime sources, copied flat>
   ```

   `-o addlib` still names the exported C API (`add()`, `addlib_init()`,
   `addlib_error()`, ...), but suppify defaults the mrbgem's own spec name
   to `picoruby-<lib_name>` rather than reusing `lib_name` verbatim.
   `picoruby-xxxx` is the real ecosystem convention for PicoRuby-specific
   mrbgems — picoruby's own tree is full of them (`picoruby-gpio`,
   `picoruby-json`, `picoruby-sqlite3`, ...), distinct from the much
   smaller set of portable `mruby-xxxx` gems that also run under upstream
   mruby (the compiler, `mrbc`, ...). That spec name is also where
   picoruby's build derives the generated C init function's name from —
   here, `mrb_picoruby_addlib_gem_init`.

3. Embed it into a picoruby build via a `build_config` that points
   `conf.gem gemdir:` at the emitted directory:

   ```ruby
   # host.rb -- a build_config for your picoruby checkout, not part of suppify's own output
   MRuby::Build.new do |conf|
     conf.toolchain :gcc
     conf.cc.defines << "MRB_TICK_UNIT=4"
     conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
     conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
     conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
     conf.cc.defines << "PICORB_PLATFORM_POSIX"
     conf.cc.defines << "MRB_INT64"
     conf.cc.defines << "MRB_NO_BOXING"
     conf.cc.defines << "MRB_UTF8_STRING"
     conf.picoruby
     conf.gembox "minimum"
     conf.gem core: "picoruby-bin-picoruby"
     conf.gem gemdir: "/abs/path/to/picoruby-addlib"
   end
   ```

   Of these settings, only `conf.picoruby` is actually load-bearing for a
   suppify-generated gem; the rest is picoruby's own standard POSIX
   host-build boilerplate (see "Embedding an mrbgem..." below for why).

4. Build picoruby against that config, with the picoruby checkout as the
   working directory. Point `MRUBY_BUILD_DIR` at an **absolute path
   outside the checkout** (e.g. a scratch/temp directory) — a relative
   `MRUBY_BUILD_DIR=build` would write build artifacts straight into the
   picoruby checkout's own working tree:

   ```sh
   cd /path/to/picoruby
   MRUBY_CONFIG=/path/to/host.rb MRUBY_BUILD_DIR=/abs/path/to/scratch/build rake
   ```

   This compiles the mrbgem's `src/*.c` — suppify's generated TU, the
   copied spinel runtime sources, and the mruby binding — straight into
   the host build's `libmruby.a` alongside picoruby's own gems, producing
   `<MRUBY_BUILD_DIR>/host/bin/picoruby`.

5. Run a script against the resulting binary. `conf.gembox "minimum"`
   already pulls in `picoruby-bin-picoruby` on POSIX, so the binary is a
   script runner and `add` is callable as an ordinary top-level Ruby
   method, AOT-compiled:

   ```sh
   echo 'print add(2, 3)' > prog.rb
   /abs/path/to/scratch/build/host/bin/picoruby prog.rb
   # => 5
   ```

### Exported symbols = public top-level methods

Only public top-level methods in `app.rb` become part of the C API.
Private methods stay hidden (`static`) inside the archive. This follows
Ruby's own `public`/`private` declarations — there's no separate `--export`
mechanism.

### Every exported method needs an RBS method type

spinel eliminates any top-level method nothing in the program calls,
regardless of visibility. Since suppify's exported methods are — by
definition — never called from inside the program, suppify needs a type
signature for each one, both to keep spinel from deleting it and to give it
a concrete C-callable type.

Write it **inline**, in the comment block immediately above the `def`, and
`app.rb` is the only file you need:

```ruby
# app.rb
#: (Integer, Integer) -> Integer
def add(a, b) = a + b

#: (Array[Integer], Integer) -> Integer
def scale_sum(xs, k) = xs.sum * k

#: () -> void
def boom = raise "x"
```

That `#:` line is [rbs-inline](https://github.com/soutaro/rbs-inline)'s
method-type comment. Its per-parameter form works too, for the cases where
naming each parameter reads better:

```ruby
# @rbs a: Integer
# @rbs b: Integer
# @rbs return: Integer
def add(a, b) = a + b
```

Only that trivial subset of `@rbs` is read (one `name: type` per
parameter, plus `return:`); every parameter needs one, or suppify fails and
says which is missing. Mixing `#:` and `@rbs` on the same `def` is an
error rather than a guess about which wins.

The **`.rbs` sidecar** keeps working exactly as before, unchanged: a file
`<basename>.rbs` next to `app.rb` (same convention spinel's own `--rbs`
support uses for top-level methods, which are Object instance methods under
the hood):

```
class Object
  def add: (Integer, Integer) -> Integer
  def boom: () -> void
end
```

The two can be mixed across methods in one program, but **not for the same
method**: a method declared both inline and in the sidecar is an error
naming the method, never a silent precedence. If a public method has no
signature in either place, `suppify` fails fast and names it — it never
silently drops it.

### What crosses the boundary

Which types are available is spinel's call, not suppify's: a top-level
method's parameters and return get the C type spinel's own codegen gives
them, and suppify marshals exactly those. The table below is that
inventory, read off spinel's generated C at the pinned commit (the unit
test `TestFlatCallTypes` asserts every row):

| RBS type | spinel's C type | plain C entry | flat-message entry |
|---|---|---|---|
| `Integer` | `sp_int` (= `intptr_t`: 8 bytes on a host, 4 on a 32-bit MCU) | ✅ `intptr_t` | ✅ |
| `Float` | `sp_float` (= `double`, on **every** target) | ✅ `double` | ✅ |
| `String` | `const char *` | ✅ | ✅ |
| `bool` / `TrueClass` / `FalseClass` | `sp_bool` | ✅ `int` | ✅ |
| `void` (return only) | `void` | ✅ | ✅ (writes `nil`) |
| `Symbol` | `sp_sym` | ❌ | ✅ (carried as a str) |
| `Array[Integer]` | `sp_IntArray *` | ❌ | ✅ |
| `Array[Float]` | `sp_FloatArray *` | ❌ | ✅ |
| `Array[String]` | `sp_StrArray *` | ❌ | ✅ |
| `Array[T]` otherwise (incl. nested containers, `Array[Symbol]`) | `sp_PolyArray *` | ❌ | ✅ |
| tuple `[T1, T2, ...]` | `sp_PolyArray *` | ❌ | ✅ |
| `Hash[Integer, Integer]` | `sp_IntIntHash *` | ❌ | ✅ |
| `Hash[Integer, String]` | `sp_IntStrHash *` | ❌ | ✅ |
| `Hash[String, Integer]` | `sp_StrIntHash *` | ❌ | ✅ |
| `Hash[String, String]` | `sp_StrStrHash *` | ❌ | ✅ |
| `Hash[String, V]` otherwise | `sp_StrPolyHash *` | ❌ | ✅ |
| `Hash[Symbol, V]` | `sp_SymPolyHash *` | ❌ | ✅ |
| `Hash[K, V]` otherwise | `sp_PolyPolyHash *` | ❌ | ✅ |
| `Integer?` / `Float?` / `String?` / `Array[...]?` / `Hash[...]?` | the same C type, carrying nil in-band (`SP_INT_NIL`, a reserved NaN, `NULL`) | ❌ | ✅ |
| `Symbol?` / `bool?` | `sp_RbVal` (boxed) | ❌ | ✅ |
| `untyped` | `sp_RbVal` (boxed) | ❌ | ✅ |

Containers nest to any depth (`Array[Array[Integer]]`,
`Hash[String, Array[Float]]`, `Array[Hash[Symbol, Float]]`, …): the element
type decides the element's representation, recursively, and suppify
generates a decoder per type node rather than per supported shape.

Rejected, with an error naming the reason:

- **any other class** (`Time`, `Set`, your own classes): spinel has no
  boundary representation for it — `RBS type Time has no spinel
  representation at the suppify boundary`.
- **unions** (`Integer | String`): a union has no single C type, and
  spinel's `--rbs` seeding does not reject one — it silently collapses it
  to whatever type the call site passes. suppify rejects it instead.
- **`nil` as a parameter type**: rejected by spinel itself (`spinel: method
  'f' param 'a' has unsupported type nil`). Use `T?`, or `void` for a
  return.
- **a parameter whose C type spinel did not give the type suppify expects**:
  suppify predicts each parameter's C type and checks the prediction against
  the signature spinel emitted, so a divergence is reported instead of
  compiled into a type-punned call.

Two limits belong to spinel, not to suppify, and show up as a spinel error
or a C compile error rather than a suppify message:

- a method **returning `Symbol`** from a poly slot (e.g. `def f(xs) =
  xs[0]` typed `(Array[Symbol]) -> Symbol`) makes spinel emit C that
  returns `sp_RbVal` from a function declared `sp_sym`, and the generated
  TU fails to compile.
- an `Integer` equal to `INTPTR_MIN` (`-2**63` on a host, `-2147483648` on
  a 32-bit MCU) **is** spinel's in-band nil for an int slot (`SP_INT_NIL`),
  so passing it reaches the kernel as `nil` and the kernel raises. suppify
  cannot tell the two apart and does not pretend to — the call answers "the
  kernel raised" with spinel's own message.

### The flat-message entry (MessagePack)

Besides the plain C entry, **every** exported method gets a byte-message
entry that hides the Ruby types from the caller entirely:

```c
int32_t     <lib>_<m>_call(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t out_cap);
const char *<lib>_<m>_signature(void);
```

- **`in`** is one MessagePack **array**: one element per parameter, in
  declaration order.
- **`out`** receives one MessagePack **value**: the return value (`nil` for
  a `void` method).
- the **return value of `_call`** is the number of bytes written (`>= 0`),
  or a negative status:

  | status | `<LIB>_E_…` | meaning |
  |---|---|---|
  | `-1` | `_E_MALFORMED` | truncated input, wrong argument count, or a value that is not the declared RBS type |
  | `-2` | `_E_NOSPACE` | `out_cap` is too small for the reply (nothing is written) |
  | `-3` | `_E_RAISED` | the kernel raised; the message is at `<lib>_error_message()` |
  | `-4` | `_E_RANGE` | an `Integer` in the message does not fit this target's `sp_int` |

  Those four macros are in the generated header.
- **`_signature()`** returns the RBS method type as written, e.g.
  `"(Array[String], Hash[Symbol, Float]) -> Array[Float]"` — no compact
  private encoding, so a caller can log it, check it, or drive a generic
  codec from it.

Why MessagePack: it is a standard, self-describing format with an
implementation in every language, so the **caller needs no knowledge of the
RBS at all** — encode whatever value tree you have. It is the kernel side
that knows the declared types: it validates the message against them while
decoding and answers `-1` on a mismatch.

How the Ruby types map onto the format:

| Ruby / RBS | MessagePack |
|---|---|
| `nil` | nil |
| `true` / `false` | bool |
| `Integer` | int (any width; range-checked against the target's `sp_int` on the way in, `-4` if it does not fit) |
| `Float` | **float64 only** (`0xcb`), never narrowed to float32, so `NaN`, `±Infinity`, `-0.0` and subnormals survive bit for bit. `sp_float` is `double` on every spinel target, host and MCU alike, so the same bytes mean the same number on both |
| `String` | str (raw bytes; a String with embedded NULs or non-UTF-8 bytes survives) |
| `Symbol` | str — MessagePack has no symbol type. A `Symbol`-declared slot decodes a str back into a Symbol; on the way out a Symbol is written as a str |
| `Array`, tuple | array |
| `Hash` | map, **in insertion order**, both directions |

A `Float`-declared slot accepts only a MessagePack float (`0xca`/`0xcb`);
an int there is a type mismatch (`-1`), not a silent widening. A
`String`-declared slot accepts str (not bin). An `untyped` slot takes
whatever the message says — a str becomes a `String` (nothing in the
message says Symbol), an array becomes an `Array`, a map becomes a `Hash`.

What goes **out** is what the kernel actually produced, encoded from
spinel's own runtime value: if a `Hash[Symbol, Float]`'s value slot holds
an Integer, the reply carries an int — exactly what CRuby would answer for
the same call. A value spinel can hold but MessagePack cannot name (a
Bignum, `Time`, `Range`, a user object) answers `-1`.

Calling it is plain C:

```c
#include "addlib.h"
uint8_t in[] = { 0x92, 0x02, 0x03 };   /* [2, 3] */
uint8_t out[64];
addlib_init();
int32_t n = addlib_add_call(in, sizeof in, out, sizeof out);
/* n == 1, out[0] == 0x05 */
```

#### Memory

Decoding builds real Ruby objects in **the kernel's own spinel heap** —
there is no second allocator. Every object is rooted (`SP_GC_ROOT`) from
the moment it is built until its owner holds it, so a collection triggered
mid-decode cannot sweep a half-built message; once the call returns they
are ordinary garbage for that instance's GC. Two suppify libraries in one
binary have two separate heaps (their runtime symbols are namespaced per
library), but they share the C `malloc` underneath.

Sizing knobs, all spinel's:

- `-DSP_GC_STACK_MAX=<n>` sets the GC root stack (default 65536 entries =
  512 KB of static buffer, usually the largest static allocation on an
  MCU). Pass the same value to the runtime sources and the generated TU —
  with the gem targets your own build_config's `cc.defines` reaches both.
- `-DSP_DYN_SYMS_MAX=<n>` (default 8192) bounds dynamically interned
  symbols. Symbol keys arriving from the wire intern dynamically, so a
  caller sending unbounded *distinct* symbol keys fills that table; spinel
  then returns symbol 0 for further names rather than raising. Prefer
  `Hash[String, V]` for keys that come from untrusted input.
- **Heap exhaustion is not a status.** spinel's allocator calls
  `sp_oom_die()`, which prints `unhandled exception: out of memory` to
  stderr and `exit(1)`s; the runtime offers no hook to turn that into a
  return value, so `_call` cannot answer with one. Size the heap for the
  largest message you will send.

#### What the VM bindings do with these methods

The CRuby and PicoRuby/mruby-c bindings wrap only the exports that have a
plain scalar C entry. A method whose RBS gives it an `Array`, `Hash`,
`Symbol` (or any other non-scalar) parameter or return has no such entry to
wrap, so **the binding skips it**: the emitted gem still builds and its
scalar methods are registered as usual, but that method is not defined as a
Ruby method by the gem. Its contract is the flat entry, which is compiled
into the same extension/mrbgem and callable from C there (`<lib>.h` is
installed by both gem targets). From a Ruby VM you would otherwise just
call the interpreted method — the flat entry exists for callers with no
Ruby VM at all, such as a second MCU core.

### Errors

Exceptions don't cross the C boundary as Ruby exceptions. Call
`<name>_error()` / `<name>_error_message()` (e.g. `addlib_error()` for a
library built with `-o addlib`) after invoking an exported function to
check whether it raised. Full per-call exception propagation is a later
phase, not v1.

### String returns and embedded NULs

A `String` return value's C pointer is a plain `const char *`, but Ruby
strings can contain embedded NUL bytes that `strlen` would truncate at. If
that matters for your use case, call `<name>_str_len(ptr)` (e.g.
`addlib_str_len(...)`) to get the real byte length instead of assuming
NUL-termination — this is exactly what the `cruby`/`picoruby` bindings do
internally when building a Ruby/mruby string from a returned value.

### Multiple suppify libraries in one binary

Each suppify library namespaces spinel's runtime symbols and its own
lifecycle/error API (`<name>_init`, `<name>_error`, `<name>_error_message`,
`<name>_str_len`) to its own `-o <name>`, so multiple suppify libraries can
coexist — verified as two `cruby` gems `require`d into one Ruby process,
and as two `picoruby` mrbgems linked into one picoruby binary.

The rename set is discovered by compiling spinel's runtime, which sees only
what that runtime *defines*. A few globals are defined by the **generated**
translation unit instead — `sp_exc_subclass_count` and
`sp_exc_subclass_ids` (spinel's user-defined exception class table) and,
under `--ext-init`, the `sp_sym_to_s` / `sp_sym_intern` / `sp_sym_intern_n` /
`sp_class_to_s` lookups — so they are missed by discovery and would collide
between two libraries. They are renamed
explicitly (`SymbolPrefix::GENERATED_TU_SYMBOLS`; the wrapper module's entry
symbols are unique by construction, `SuppiExport_<lib>`); the prelude is
force-included into the generated TU as well as the runtime sources, so the
definition and its references move together.

The `c` target has one remaining gap: directly linking two suppify-built
`.a` files into the same binary (`cc ... -laddlib -lmullib`) still fails on
a duplicate **`sp_ctx_swap`** symbol (spinel's Fiber context-switch
primitive). Its name lives inside a raw assembly block as a *string
literal*, where `#define` substitution never reaches: renaming it would
rename the call sites and leave the definition behind, i.e. an
undefined-symbol error instead of a duplicate one. Renaming it needs an
object-file rewrite (`llvm-objcopy --redefine-sym`) that suppify does not
do, because it would make every build depend on a binutils/llvm tool that
is not present by default on macOS. It's stateless and bit-identical across
libraries, so this only bites if you link the raw `c`-target archives
directly; the `cruby`/`picoruby` targets aren't affected. Pick distinct
exported method names (`-o`/`def` names) across libraries either way, same
as any C code.

### Embedding an mrbgem in a PicoRuby application or firmware project

Once a suppify-generated mrbgem (`picoruby-<lib_name>`) exists, adding it
to your *own* picoruby-based app or firmware is the same
`conf.gem gemdir: "/abs/or/config-relative/path/to/picoruby-<lib_name>"`
line as the walkthrough above, just inside your project's own
`build_config` instead of a throwaway `host.rb`. `gemdir:` paths resolve
relative to the `build_config` file's own directory, not your terminal's
working directory or the picoruby repo root, so an absolute path (as shown
above) sidesteps that entirely.

- **The generated binding adapts to both of picoruby's VMs.** The emitted
  `binding.c` dispatches on whether the consuming build defines
  `PICORB_VM_MRUBYC`: under the mruby/c VM (what microcontroller firmware
  such as R2P2-ESP32 runs) it registers via mrubyc's API
  (`mrbc_define_method`), under the full-mruby VM (`PICORB_VM_MRUBY`) via
  `mrb_define_method`. Which VM a build_config method (`conf.picoruby`,
  `conf.microruby`, ...) selects differs between picoruby versions — check
  your checkout's `lib/picoruby/build.rb` rather than relying on the
  method name.
- **On the mruby/c VM, `require '<lib_name>'` activates the gem.**
  Registration runs through picoruby-require's prebuilt gem table — that
  table is what the emitted `mrblib/<lib_name>.rb` stub anchors the gem
  in — so call `require 'addlib'` before using the exported methods. On
  the full-mruby VM the methods are registered at gem-init time and no
  `require` is needed.
- **Most of the other defines in the walkthrough's `build_config` are not
  suppify requirements** — they're picoruby's own standard POSIX host
  recipe (the same set `build_config/default.rb` uses), and three of them
  (`MRB_INT64`, `MRB_NO_BOXING`, `MRB_UTF8_STRING`) get forced on
  unconditionally by picoruby's own `picoruby-mruby` gem regardless of
  what your build_config sets. Don't feel obliged to copy that whole list
  into a firmware build_config on suppify's account — only
  `conf.picoruby` matters to a suppify-generated gem; your target's own
  build_config (POSIX host, an MCU cross build, ...) already sets
  whatever it needs for its own gems.
- **`spec.license` / `spec.author` are hard requirements of picoruby's own
  gem loader, not a suppify convention.**
  `MRuby::Gem::Specification#setup` fails the entire build if a gem's
  `mrbgem.rake` omits either — this is why the emitted `mrbgem.rake`
  always sets `spec.author = 'suppify'` and why suppify's CLI defaults
  `--license` to `MIT` for this target even if you don't pass one. If you
  hand-edit a generated `mrbgem.rake`, keep both fields.
- **Two suppify mrbgems must use different `-o lib_name` values, for a
  second, independent reason beyond symbol namespacing.** picoruby derives
  each mrbgem's generated init/final C function name directly from its
  gem name, and only deduplicates loaded gems by directory, not by
  declared name — two gem directories that resolve to the same
  `picoruby-<lib_name>` produce a duplicate C function definition and a
  hard compile/link error, independent of and in addition to the
  runtime-symbol-prefix collision covered above.
- **Flash/code-size footprint: each suppify mrbgem bundles and namespaces
  its own copy of spinel's runtime sources, not a shared one.** Embedding
  several suppify-generated mrbgems into one firmware image compiles and
  links the spinel runtime once *per gem*, not once total — size
  budgeting on a flash-constrained target should account for N runtime
  copies when combining N suppify mrbgems, not one.
- **Cross-compilation toolchain flags come entirely from your own
  build_config.** The emitted `mrbgem.rake` never sets `conf.cc.command`,
  target ABI flags (`-mcpu`, `-mthumb`, ...), or any toolchain selection —
  it only adds its own include path, the runtime-symbol-prefix include,
  and `-lm` (`spec.cc.include_paths`, `spec.cc.flags`,
  `spec.linker.libraries`). Whichever toolchain your build_config already
  targets (`arm-none-eabi-gcc` for a Cortex-M board, host `gcc`/`clang`
  for POSIX, etc.) compiles the mrbgem's sources too, same as noted in
  [Cross-compilation](#cross-compilation) below.

### Cross-compilation

Cross-compilation depends on the target:

- The **`c` target compiles here**, with a hardcoded host `cc` (no `--cc=` /
  `CC` override, no target triple/sysroot), recompiling spinel's runtime
  into the same archive. It only produces output for the host architecture.
- The **`cruby` / `picoruby` targets don't compile at all** — they emit a
  source bundle (generated C + spinel runtime sources + binding) that the
  *consumer's* build compiles. So a `picoruby` gem cross-compiles wherever
  the consuming picoruby build does (ESP32 xtensa/riscv, iOS arm64, …): the
  target toolchain and its ABI flags compile suppify's sources too. suppify
  itself carries no cross toolchains.

There is no direct cross-compiling `.a` emitter (a `c` target for a foreign
arch); the gem targets cover the cross use cases in practice.

## Example

The steps below run strictly in this order — **no C code needs to exist
before `suppify` runs.** `addlib.h` and `libaddlib.a` don't exist until
step 3, so a consumer like `harness.c` can only be written afterward: it
`#include`s a header that step 3 generates.

1. Write the Ruby source and its `.rbs` sidecar:

   ```ruby
   # app.rb
   def add(a, b) = a + b
   def boom = raise "x"
   ```

   ```
   # app.rbs
   class Object
     def add: (Integer, Integer) -> Integer
     def boom: () -> void
   end
   ```

2. Run suppify. Nothing C-related exists yet at this point — this step
   only reads Ruby and shells out to spinel:

   ```sh
   ruby suppify.rb app.rb -o addlib
   ```

   This leaves `addlib.h` and the self-contained `libaddlib.a` in the
   current directory (see "Usage" above for `-o`/`-d`).

3. Only now, with `addlib.h` on disk, does it make sense to write a C
   consumer:

   ```c
   /* harness.c */
   #include "addlib.h"
   #include <stdio.h>
   int main(void) {
       addlib_init();
       printf("%ld\n", (long)add(2, 3));  /* 5 */
       boom();
       printf("%d\n", addlib_error());    /* 1 */
   }
   ```

4. Compile and link `harness.c` against `libaddlib.a` from step 2. This is
   ordinary static-library linking — nothing suppify-specific:

   ```sh
   cc harness.c -I. -L. -laddlib -lm -o harness
   ```

   - `-I.` — look for headers (`addlib.h`) in the current directory
   - `-L.` — look for libraries (`.a` files) in the current directory
   - `-laddlib` — link `libaddlib.a` (the `lib`/`.a` are implied by `-l`);
     it's self-contained (spinel's runtime is bundled in, namespaced to
     this library — see [Multiple suppify libraries in one
     binary](#multiple-suppify-libraries-in-one-binary))
   - `-lm` — the math library, linked by convention

   This is the same procedure you'd use to link against any third-party
   static library (e.g. `zlib`, `libcurl`) you built yourself — suppify's
   output doesn't require any special linker flags or build steps.

The same library is also verified callable from a real Ruby native
extension built with `mkmf` (`test/test_ruby_ext_integration.rb`) —
useful as a template if you want to consume suppify's output from Ruby
itself rather than a standalone C program.

For runnable, repo-checked-in examples that embed a real generated
cruby gem / picoruby mrbgem, demonstrate editing the source and
recompiling, and benchmark the AOT-compiled result against a plain
interpreter, see [`examples/`](examples/README.md).

## Development

```sh
bundle exec rake test
```

The Ruby-layer unit tests always run. Gated integration tests run — and must
pass — only when their prerequisites are present, otherwise they're skipped
(omitted) so the suite stays green without them:

- `test_integration.rb`, `test_ruby_ext_integration.rb`,
  `test_cruby_target_integration.rb` — need `spinel` on `PATH` + `SPINEL_LIB`.
- `test_flat_call_integration.rb` — needs `spinel` on `PATH`; builds a
  library from `test/fixtures/flat.rb` (inline `#:` annotations, no
  sidecar), links a C driver against its flat-message entries, and compares
  every answer against the same kernel running under CRuby.
- `test_picoruby_target_integration.rb` — additionally needs a local picoruby
  checkout (`PICORUBY_ROOT`, default `~/dev/src/github.com/picoruby/picoruby`);
  it runs a full picoruby host build linking the generated mrbgem.

```sh
rake spinel:latest              # matz/spinel's current upstream master SHA
rake spinel:check_pin[<ref>]    # verify a spinel ref (default: spinel.pin); clones + builds it + runs this suite against it
rake spinel:bump_pin[<ref>]     # check_pin[<ref>], and only on success, write spinel.pin
```
