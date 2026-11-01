---
name: spinel-tracking
description: Use when checking whether suppify still tracks matz/spinel's current upstream, or when advancing spinel.pin to a newer spinel commit. Applies to this repo (suppify) only — downstream consumers (e.g. R2P2-darwin) have their own pin and their own tracking skill.
---

# spinel-tracking: keep suppify verified against one spinel commit

`spinel.pin` names the one matz/spinel commit suppify is verified against. spinel is an
external tool; `rakelib/spinel.rake` clones it into a temporary directory to verify a ref.

## Rake tasks

```sh
rake spinel:latest              # matz/spinel's master SHA
rake spinel:check_pin[<ref>]    # clone and build <ref>, run the suite with SPINEL set to it (default: spinel.pin)
rake spinel:bump_pin[<ref>]     # check_pin[<ref>], then write spinel.pin when it passes
```

## Procedure

1. **Compare** `rake spinel:latest` with `spinel.pin`. When they match, tracking is current.
2. **Verify** with `rake spinel:check_pin[<sha>]`. A failing run keeps its clone and prints the path.
3. **When green**, run `rake spinel:bump_pin[<sha>]` and commit `spinel.pin`. The commit message
   names the spinel ref and any change it took to reach green.
4. **When red**, read the kept clone's actual output before changing code:
   - **A CLI flag or report line changed**: compare `spinel --help` and `spinel --print-build`
     with `Spinel#compile` and `Spinel#build_report` (`lib/suppify/spinel.rb`).
   - **An entry's C type is new**: compare the generated `<name>_spinel.h` with `TYPES`
     (`lib/suppify/glue.rb`).
   - **A runtime file moved or was added**: compare the clone's `lib/` with
     `Mrbgem::RUNTIME` (`lib/suppify/mrbgem.rb`).
   - **The glue fails to compile**: compare the runtime API the glue calls (`SP_GC_SAVE`,
     `SP_GC_ROOT`, `SP_STR_HDL`, `sp_str_from_bytes`, `sp_str_byte_len`, `<name>_spinel_try`)
     with the clone's `lib/spinel_rt.h`.
   - Re-run `check_pin` after each fix until green, then do step 3.

## Integration tests

`check_pin` runs every test whose tools are present. Before bumping, also run the tests the
host may skip:

- `PICORUBY_ROOT=<picoruby checkout>` runs `test_picoruby_integration.rb` on both VMs.
- `arm-none-eabi-gcc` and `qemu-arm` on `PATH`, with a spinel that provides `lib/newlib`,
  run `test_newlib_integration.rb`.

## Downstream

A consumer that pins both spinel and suppify advances suppify's pin first, after it is
verified green here, then re-verifies its own kernels against that pair.
