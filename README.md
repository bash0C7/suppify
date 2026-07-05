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

### Embedding an mrbgem in a PicoRuby application or firmware project

Once a suppify-generated mrbgem (`picoruby-<lib_name>`) exists, adding it
to your *own* picoruby-based app or firmware is the same
`conf.gem gemdir: "/abs/or/config-relative/path/to/picoruby-<lib_name>"`
line as the walkthrough above, just inside your project's own
`build_config` instead of a throwaway `host.rb`. `gemdir:` paths resolve
relative to the `build_config` file's own directory, not your terminal's
working directory or the picoruby repo root, so an absolute path (as shown
above) sidesteps that entirely.

- **VM selection is a real, load-bearing requirement: `conf.picoruby`, not
  `conf.femtoruby`.** suppify's generated mruby binding targets picoruby's
  `PICORB_VM_MRUBY` VM (`mrb_state`, `mrb_value`, `mrb_get_args`,
  `mrb_define_method`, ...) — that API only exists when the build_config
  selects it via `conf.picoruby`. picoruby's other VM variant, selected by
  `conf.femtoruby` (`PICORB_VM_MRUBYC`, the mruby/c VM), exposes a
  different, incompatible API; a suppify-generated mrbgem won't compile
  against it.
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
- `test_picoruby_target_integration.rb` — additionally needs a local picoruby
  checkout (`PICORUBY_ROOT`, default `~/dev/src/github.com/picoruby/picoruby`);
  it runs a full picoruby host build linking the generated mrbgem.
