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

## Example

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

```sh
ruby suppify.rb app.rb -o addlib
```

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

```sh
cc harness.c -I. -L. -laddlib -lspinel_rt -lm -o harness
```

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
