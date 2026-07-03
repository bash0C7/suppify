# suppify

`suppify` converts a Ruby program that [spinel](https://github.com/matz/spinel)
(a Ruby AOT compiler) can compile into a **neutral, linkable C library**
(`.a` + header) — callable from any plain-C-ABI consumer, without spinel
itself being modified, and without spinel being needed at the consumer's
build or run time. Design rationale: `docs/superpowers/specs/2026-06-21-suppify-design.md`.

## Status

The core pipeline (this doc) is implemented and verified end-to-end against
a real build of `spinel` — see `HANDOFF.md` for exactly what's proven and
what open gaps remain (type coverage beyond scalars, real consuming
platforms beyond a Ruby native extension, CI). Treat this as a working core,
not a finished, broadly-hardened tool.

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
ruby suppify.rb app.rb -o libname [-d out_dir]
```

| Argument | Meaning | Default |
|---|---|---|
| positional (first non-flag arg) | input `.rb` path | required — raises `Suppify::Error` if missing |
| `-o <name>` | output library name (`lib<name>.a` / `<name>.h`) | input filename without `.rb` (e.g. `app.rb` → `app`) |
| `-d <dir>` / `--out-dir <dir>` | output directory | `.` (current directory) |

The `.rbs` sidecar isn't a flag — it's looked up automatically next to the
input file, same basename (e.g. `foo/app.rb` → `foo/app.rbs`). There's no
`--spinel-bin` / `--spinel-lib` flag yet; spinel is only discovered via
`PATH` and the `SPINEL` / `SPINEL_LIB` env vars described above.

Produces in `out_dir` (default `.`):

- `liblibname.a` — your compiled program
- `libspinel_rt.a` — copied alongside, so the output is self-contained
  (consumers never need spinel installed)
- `libname.h` — a **neutral** header (no spinel types leak through; see
  "Supported types" below)

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
`suppi_error()` / `suppi_error_message()` after invoking an exported
function to check whether it raised. Full per-call exception propagation is
a later phase, not v1.

### Constraint: one suppify library per binary

`sp_lib_init`, `sp__main`, `suppi_error`, and `libspinel_rt.a`'s symbols
are shared C names across any suppify-built library. Linking two
suppify-built libraries into the same binary will collide. v1 supports
exactly one suppify library per consuming binary.

### Constraint: no cross-compilation

`suppify` only produces binaries for the host it runs on. `Builder`
invokes a hardcoded `cc` (no `--cc=` / `CC` override, no target triple, no
sysroot), and the bundled `libspinel_rt.a` is copied as-is from your local
spinel build, so it's whatever architecture that build targeted. To
produce output for a different target (e.g. an ESP32 toolchain, or an iOS
device slice), you'd need to build spinel and run suppify natively for
that target yourself — there's no built-in cross-compilation support yet.

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

   This leaves `addlib.h`, `libaddlib.a`, and `libspinel_rt.a` in the
   current directory (see "Usage" above for `-o`/`-d`).

3. Only now, with `addlib.h` on disk, does it make sense to write a C
   consumer:

   ```c
   /* harness.c */
   #include "addlib.h"
   #include <stdio.h>
   int main(void) {
       sp_lib_init();
       printf("%ld\n", (long)add(2, 3));  /* 5 */
       boom();
       printf("%d\n", suppi_error());     /* 1 */
   }
   ```

4. Compile and link `harness.c` against the two `.a` files from step 2.
   This is ordinary static-library linking — nothing suppify-specific:

   ```sh
   cc harness.c -I. -L. -laddlib -lspinel_rt -lm -o harness
   ```

   - `-I.` — look for headers (`addlib.h`) in the current directory
   - `-L.` — look for libraries (`.a` files) in the current directory
   - `-laddlib` — link `libaddlib.a` (the `lib`/`.a` are implied by `-l`)
   - `-lspinel_rt` — link `libspinel_rt.a`, which `libaddlib.a` depends on
   - `-lm` — the math library, linked by convention
   - the order (`-laddlib` before `-lspinel_rt`) follows the usual Unix
     linker convention of listing a dependent library before the library
     it depends on

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

The Ruby-layer unit tests always run. Two gated integration tests
(`test/test_integration.rb`, `test/test_ruby_ext_integration.rb`)
additionally run — and must pass — whenever `spinel` is on `PATH`;
otherwise they're skipped (omitted) so the suite stays green without
spinel installed.
