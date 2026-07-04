# suppify

`suppify` converts a Ruby program that [spinel](https://github.com/matz/spinel)
(a Ruby AOT compiler) can compile into a **neutral, linkable C library**
(`.a` + header) — callable from any plain-C-ABI consumer, without spinel
itself being modified, and without spinel being needed at the consumer's
build or run time. Design rationale: `docs/superpowers/specs/2026-06-21-suppify-design.md`.

## Status

The core pipeline plus the `c`, `cruby`, and `picoruby` targets are
implemented and each verified end-to-end against a real `spinel` (and, for
`picoruby`, a real picoruby host build) — see `HANDOFF.md` for exactly
what's proven and what open gaps remain (scalar-only types, stateful
classes, on-device/on-iPhone runs as opposed to host builds). Treat this as
a working core, not a finished, broadly-hardened tool.

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
- runtime (`sp_runtime.h` / `libspinel_rt.a`): the `SPINEL_LIB` env var
  (defaults to empty, i.e. current directory)

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
input file, same basename (e.g. `foo/app.rb` → `foo/app.rbs`). There's no
`--spinel-bin` / `--spinel-lib` flag yet; spinel is only discovered via
`PATH` and the `SPINEL` / `SPINEL_LIB` env vars described above.

With the default `c` target, produces in `out_dir` (default `.`):

- `liblibname.a` — your compiled program, self-contained: it bundles a
  recompiled, namespaced copy of spinel's runtime (consumers never need
  spinel installed, and never link a separate runtime archive)
- `libname.h` — a **neutral** header (no spinel types leak through; see
  "Supported types" below)

## Targets

The neutral C library is the substrate; a `--target` selects how it's
surfaced to a consumer ecosystem. All targets share the same
spinel→neutral-C core (same `.rbs`, same supported types, same error
convention); they differ only in the binding they generate and how the
result is packaged.

| Target | Output | Consumed by |
|---|---|---|
| `c` (default) | self-contained `liblibname.a` + neutral `libname.h`, **compiled here** with the host `cc`/`ar` | any C program, linked directly (see [Example](#example)) |
| `cruby` | a buildable **CRuby native-extension gem** (`ext/.../extconf.rb` + `*.gemspec`) under `out_dir/libname` | CRuby, via `gem build` / `require` — the AOT-compiled methods become ordinary Ruby methods |
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

```sh
SPINEL_LIB=/path/to/spinel/lib ruby suppify.rb app.rb -o addlib -t cruby
cd addlib && ruby ext/addlib/extconf.rb && make   # or: gem build addlib.gemspec
ruby -r./ext/addlib/addlib -e 'p add(2, 3)'        # => 5
```

### picoruby target example

```sh
SPINEL_LIB=/path/to/spinel/lib ruby suppify.rb app.rb -o addlib -t picoruby
# then in the consumer's build_config/*.rb:
#   conf.gem gemdir: "/abs/path/to/picoruby-addlib"
# rebuild picoruby; `add(2, 3)` now runs as AOT-compiled native code.
```

### Exported symbols = public top-level methods

Only public top-level methods in `app.rb` become part of the C API.
Private methods stay hidden (`static`) inside the archive. This follows
Ruby's own `public`/`private` declarations — there's no separate `--export`
mechanism.

### A `.rbs` sidecar is required for every exported method

spinel eliminates any top-level method nothing in the program calls,
regardless of visibility. Since suppify's exported methods are — by
definition — never called from inside the program, suppify needs a type
signature for each one, both to keep spinel from deleting it and to give it
a concrete C-callable type. Declare it in `<basename>.rbs` next to
`app.rb` (same convention spinel's own `--rbs` support uses for top-level
methods, which are Object instance methods under the hood):

```
class Object
  def add: (Integer, Integer) -> Integer
  def boom: () -> void
end
```

If a public method has no matching signature, `suppify` fails fast and
names the method — it never silently drops it.

### Supported types

`Integer`, `Float`, `String`, `Symbol`, `bool` (`TrueClass`/`FalseClass`),
`nil`/`NilClass`, `void` (return only). Anything else — `Array`, `Hash`,
custom classes — is not yet supported and raises a clear error rather than
silently producing a broken export.

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
and as two `picoruby` mrbgems linked into one picoruby binary. The `c`
target has one remaining gap: directly linking two suppify-built `.a`
files into the same binary (`cc ... -laddlib -lmullib`) still fails on a
duplicate `sp_ctx_swap` symbol (spinel's Fiber context-switch primitive,
whose name is hardcoded inside a raw assembly block that can't be
renamed). It's stateless and identical across libraries, so this only
happens if you link the raw `c`-target archives directly; the `cruby`/
`picoruby` targets aren't affected. Pick distinct exported method names
(`-o`/`def` names) across libraries either way, same as any C code.

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

## Development

```sh
bundle exec rake test
```

The Ruby-layer unit tests always run. Gated integration tests run — and must
pass — only when their prerequisites are present, otherwise they're skipped
(omitted) so the suite stays green without them:

- `test_integration.rb`, `test_ruby_ext_integration.rb`,
  `test_cruby_target_integration.rb` — need `spinel` on `PATH` + `SPINEL_LIB`.
- `test_picoruby_target_integration.rb` — additionally needs a local picoruby
  checkout (`PICORUBY_ROOT`, default `~/dev/src/github.com/picoruby/picoruby`);
  it runs a full picoruby host build linking the generated mrbgem.
