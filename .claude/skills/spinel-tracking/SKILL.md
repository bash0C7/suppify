---
name: spinel-tracking
description: Use when checking whether suppify still tracks matz/spinel's current upstream, or when advancing spinel.pin to a newer spinel commit. Applies to this repo (suppify) only — downstream consumers (e.g. R2P2-darwin) have their own pin and their own tracking skill.
---

# spinel-tracking: keep suppify verified against one spinel commit

`spinel.pin` names the one commit of bash0C7/spinel suppify is verified against. The fork is
matz/spinel plus `lib/newlib` on its `newlib-runtime-pr` branch. spinel is an external tool;
`rakelib/spinel.rake` clones the fork into a temporary directory to verify a ref.

## Rake tasks

```sh
rake spinel:latest              # matz/spinel's master SHA
rake spinel:check_pin[<ref>]    # clone bash0C7/spinel, build <ref>, run the suite with SPINEL set to it (default: spinel.pin)
rake spinel:bump_pin[<ref>]     # check_pin[<ref>], then write spinel.pin when it passes
```

## Procedure

1. **Compare** `rake spinel:latest` with the base of `newlib-runtime-pr` in the fork. When they match, tracking is current.
2. **Rebase** `newlib-runtime-pr` onto matz/spinel's master and push it to the fork.
3. **Verify** with `rake spinel:check_pin[<rebased sha>]`. A failing run keeps its clone and prints the path.
4. **When green**, run `rake spinel:bump_pin[<rebased sha>]` and commit `spinel.pin`. The commit message
   names the spinel ref and any change it took to reach green.
5. **When red**, read the kept clone's actual output before changing code:
   - **A CLI flag or report line changed**: compare `spinel --help` and `spinel --print-build`
     with `Spinel#compile` and `Spinel#build_report` (`lib/suppify/spinel.rb`).
   - **An entry's C type is new**: compare the generated `<name>_spinel.h` with `TYPES`
     (`lib/suppify/glue.rb`).
   - **A runtime file moved or was added**: compare the clone's `lib/` with
     `Mrbgem::RUNTIME` (`lib/suppify/mrbgem.rb`).
   - **The glue fails to compile**: compare the runtime API the glue calls (`SP_GC_SAVE`,
     `SP_GC_ROOT`, `SP_STR_HDL`, `sp_str_from_bytes`, `sp_str_byte_len`, `<name>_spinel_try`)
     with the clone's `lib/spinel_rt.h`.
   - **The newlib test fails**: fix `lib/newlib` on the fork's `newlib-runtime-pr` branch.
   - Re-run `check_pin` after each fix until green, then do step 4.

## Integration tests

`check_pin` runs every test whose tools are present. Before bumping, also run the tests the
host may skip:

- `PICORUBY_ROOT=<picoruby checkout>` runs `test_picoruby_integration.rb` and
  `test_example_integration.rb` on both VMs.
- `arm-none-eabi-gcc` with newlib on `PATH` builds and links the board gem in
  `test_newlib_integration.rb` and `test_example_integration.rb`. With `qemu-arm` also on `PATH`, they
  run the program. `qemu-arm` runs on a Linux host only.

`.github/workflows/test.yml` runs the whole suite on ubuntu with all of these tools on every push, and
fails when a test is omitted. After pushing the commit that changes `spinel.pin`, read that run's result.

## Downstream

A consumer that pins both spinel and suppify advances suppify's pin first, after it is
verified green here, then re-verifies its own kernels against that pair.
