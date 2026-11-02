# suppify

suppify packs a Ruby kernel compiled by [spinel](https://github.com/matz/spinel) as a
self-contained PicoRuby mrbgem. The gem runs on both PicoRuby VMs: mruby (`conf.picoruby`)
and mruby/c (`conf.femtoruby`). It also gives the kernel a plain C contract, so C code
and callers with no Ruby VM can call it too.

suppify uses spinel's library output (`--ext-init`, `--ext-entry`, `--emit-symbol-map`,
`--print-build`) and adds what PicoRuby needs:

- **VM bindings**: each entry becomes a module method on the mruby and mruby/c VMs.
- **Typed C entries**: `int calc_Calc_add(intptr_t a0, intptr_t a1, intptr_t *ret)`, using plain C types only.
- **MessagePack entries**: `int32_t calc_Calc_add_call(in, in_len, out, out_cap)`, plus a kernel table.
- **Build settings**: the runtime defines, cflags and libraries spinel reports, plus the kernel's
  `ffi_lib` / `ffi_cflags`, go into `mrbgem.rake`.

## Choosing between picoruby-aot and suppify

| Need | Use |
|---|---|
| Speed up a gem on the mruby VM | picoruby-aot (`spec.aot = true`, or `g.aot = true` in your build_config) |
| Run a kernel fully native, as spinel compiles it | suppify |
| Speed up code on the mruby/c VM | suppify |
| Call a kernel from C, or from a core with no VM (multicore) | suppify (typed or MessagePack entries) |
| A CRuby extension | `spinel --ext cruby` / `spin ext` |

Start with picoruby-aot. Its methods stay ordinary VM methods that take and return VM
objects, and it needs no extra build step. Use suppify for a kernel whose picoruby-aot
time you have measured and found too slow. Host timings for three kernels on the mruby VM:

| Kernel | mruby bytecode | picoruby-aot | suppify (spinel native) |
|---|---|---|---|
| `ulaw` | 0.347 s | 0.133 s | 0.017 s |
| `glyph` | 1.739 s | 0.879 s | 0.043 s |
| `spin` | 0.997 s | 0.141 s | 0.037 s |

## Requirements

- Ruby 3.2 or later.
- spinel from [bash0C7/spinel](https://github.com/bash0C7/spinel) at the commit in `spinel.pin`, built
  (`make deps && make`). suppify finds it through `SPINEL` or `PATH`. The fork is matz/spinel
  plus `lib/newlib`.

## Usage

```sh
ruby suppify.rb kernel.rb Calc.add Calc.greet -o calc -d build
```

- **Arguments**: the kernel file, then each exported method as `Module.method`.
- **`-o NAME`**: the gem name (`picoruby-NAME`) and the C prefix. The default is the kernel's basename.
- **`-d DIR`**: the output directory. The default is `.`.
- **`--license ID`**: `spec.license`. The default is `MIT`.
- **`--newlib`**: build for a board whose C library is newlib (see [Boards with newlib](#boards-with-newlib)).
- **`--workers K`**, **`--table NAME`**, **`--no-vm`**: the callers outside the VM (see
  [Callers and instances](#callers-and-instances)).

### The kernel

A kernel is a module of `def self.` methods, each typed with an inline `#:` RBS comment:

```ruby
module Calc
  #: (Integer, Integer) -> Integer
  def self.add(a, b) = a + b

  #: (String) -> String
  def self.greet(name) = "hi, " + name
end
```

Entries cross the contract in these types:

| RBS | C contract | spinel |
|---|---|---|
| `Integer` | `intptr_t` | `sp_int` |
| `Float` | `double` | `sp_float` |
| `bool` | `bool` | `sp_bool` |
| `String` | `const char *s, size_t n` | `sp_String *` |
| `void` / `nil` (return) | none | `void` |

The kernel calls C through spinel's FFI (`ffi_func`, see spinel's `docs/FFI.md`) and uses spin
packages through `require` (`base64`, `json`, `strscan`, ...). suppify carries what spinel's build
needs into the gem:

- **Compile flags** (`ffi_cflags` and spinel's own): `-I` and `-D` go to the gem's include paths
  and defines, and the rest to its flags.
- **Libraries** (`ffi_lib` and spinel's own): added to the build's linker libraries. Every binary
  the PicoRuby build links gets them, and they appear in `libmruby.flags.mak`.
- **Packages**: each package's C source is copied into `src/` and built for the target.

```ruby
module Hw
  ffi_lib "hw"
  ffi_cflags "-I/opt/hw/include"
  ffi_cflags "-DHW_BOARD=3"
  ffi_func :hw_scale, [:long], :long
end

module Native
  #: (Integer) -> Integer
  def self.mag(n) = Hw.hw_scale(n)
end
```

Set the library's directory in your build_config with `conf.linker.library_paths << "/opt/hw/lib"`.
A firmware that links `libmruby.a` with its own build system links the library there.

### The gem

```
picoruby-calc/
  mrbgem.rake
  include/suppify/calc.h  the C contract
  mrblib/calc.rb          the kernel's modules
  src/binding.c           mruby and mruby/c methods
  src/calc_glue.c         typed and MessagePack entries
  src/calc_spinel.c/.h    spinel's output
  src/*.c, *.h            spinel's runtime and the kernel's packages
  src/instances/          the glue and exported names of each sealed instance
```

Add it to your build_config:

```ruby
conf.gem gemdir: "/path/to/build/picoruby-calc"
```

On mruby, `Calc.add(2, 3)` works as soon as the VM starts. On mruby/c, call
`require "calc"` first; this needs `picoruby-require`.

A build links one suppify gem: spinel's runtime serves one compiled program, and each kernel
is its own program. Put all of a build's kernels into one kernel file (a top file can
`require_relative` the others). A second suppify gem stops the build with both gem names.

### Callers and instances

spinel's runtime holds its heap, GC and exception state once per copy, so one copy serves one
caller at a time. A caller is a core, a thread or a preemptive task; the VM is one caller, since
it runs its own tasks one at a time. The gem holds one instance (a copy of the kernel and the
runtime) per caller, chosen when the gem is generated:

| Option | Instances |
|---|---|
| none | one, for the VM |
| `--workers K` | one for the VM, plus one per worker `k` = 1..K |
| `--table NAME` | names worker 1's kernel table, and implies `--workers 1` when no count is given |
| `--no-vm` | no VM methods and no VM instance; implies `--workers 1` when no count is given |

Each instance runs on its own: callers of different instances run the kernel at the same time.
Worker `k`'s entries are `<name>_w<k>_*` and its table is `<name>_w<k>_kernels` (or `NAME`).
Each instance belongs to one caller; that caller runs its `init`.

For a VM and one picoruby-multicore worker on the other core:

```sh
ruby suppify.rb kernel.rb Calc.add -o calc --table multicore_kernels
```

```ruby
Calc.add(2, 3)                 # the VM instance
Multicore.run(:add, 2, 3)      # the worker instance, on the other core
```

The first instance builds from `src/` like any gem source. Each further one compiles the same
sources into its own objects, links them into one relocatable object, and keeps only its own
entries global (`objcopy --keep-global-symbols` with GNU tools, `-exported_symbols_list` with
Apple's linker). An instance adds the kernel and the runtime once more: about 200 KB of code and
20 KB of static RAM on a Cortex-M.

### Errors

When the kernel raises, the VM raises the same class name if that class exists, and
`RuntimeError` otherwise. The message is the kernel's. Arguments of the wrong type raise
`TypeError`: an `Integer` parameter takes an Integer only, and a `Float` parameter takes a Float
or an Integer. An Integer that `intptr_t` or the VM's Integer cannot hold raises `RangeError`.

## The C contract

`include/suppify/calc.h` uses plain C types only. It includes only `<stdbool.h>`, `<stddef.h>` and
`<stdint.h>`, so it works next to any VM's headers.

```c
void calc_init(void);                       /* call once before any entry */
const char *calc_error_class(void);         /* the class the last call raised, or "" */
const char *calc_error_message(void);       /* the message the last call raised, or "" */

int calc_Calc_add(intptr_t a0, intptr_t a1, intptr_t *ret);
int calc_Calc_greet(const char *s0, size_t n0, const char **ret, size_t *ret_len);
int32_t calc_Calc_add_call(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t out_cap);
const char *calc_Calc_add_signature(void);  /* "(Integer, Integer) -> Integer" */

extern const suppify_kernel_t calc_kernels[];
```

- **Names**: the C name is `<name>_<Module>_<method>` for the VM instance and
  `<name>_w<k>_<Module>_<method>` for worker `k`. A trailing `?` becomes `_p`. The header leaves
  a table named by `--table` undeclared, for the header of the code that looks it up.
- **Typed entries**: return `0` on success and `1` when the kernel raised. They write the result
  through `ret`. A returned string stays valid until the next call into the library.
- **MessagePack entries**: `in` is a MessagePack array of the arguments. The return value is written
  to `out` as one MessagePack value, and the entry returns its length. Integers wider than
  `intptr_t` return `SUPPIFY_RANGE`. A `Float` argument also accepts an integer, and a `bool`
  argument treats `nil` as false. A negative return is a status, and a negative `in_len` or
  `out_cap` is `SUPPIFY_MALFORMED`:

  | Status | Value |
  |---|---|
  | `SUPPIFY_MALFORMED` | -1 |
  | `SUPPIFY_NOSPACE` | -2 |
  | `SUPPIFY_RAISED` | -3 |
  | `SUPPIFY_RANGE` | -4 |

- **Kernel table**: `calc_kernels` lists every entry as a `suppify_kernel_t` and ends with a
  `NULL` name. Its fields are `name` (the method name), `call`, `signature`, `init` and
  `error_message`.

## Boards with newlib

`--newlib` copies spinel's `lib/newlib` into `src/newlib`. The gem's build then:

- puts `src/newlib` first on the include path;
- defines `_DEFAULT_SOURCE`;
- force-includes `sp_newlib_config.h`, which sizes the runtime's tables and first GC triggers for a small heap;
- links `sp_newlib.c`, which holds weak stubs for the system calls the board lacks.

spinel's `docs/newlib.md` describes the settings and how to override them.

## Development

```sh
bundle install
bundle exec rake test
```

The integration tests run when their tools are present:

| Test | Needs |
|---|---|
| `test_spinel_integration.rb` | spinel (`SPINEL` or `PATH`) |
| `test_call_integration.rb` | spinel, `cc` |
| `test_newlib_integration.rb` | spinel, `arm-none-eabi-gcc`, `qemu-arm` |
| `test_picoruby_integration.rb` | spinel, `cc`, a PicoRuby checkout in `PICORUBY_ROOT` |

`rakelib/spinel.rake` tracks `spinel.pin`:

- `rake spinel:latest` prints matz/spinel's master.
- `rake spinel:check_pin[ref]` clones bash0C7/spinel at `ref` and runs the suite against it.
- `rake spinel:bump_pin[ref]` writes `ref` to `spinel.pin` after the suite passes.
