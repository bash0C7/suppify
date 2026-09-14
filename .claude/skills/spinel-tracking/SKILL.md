---
name: spinel-tracking
description: Use when checking whether suppify still tracks matz/spinel's current upstream, or when advancing spinel.pin to a newer spinel commit. Applies to this repo (suppify) only — downstream consumers (e.g. R2P2-darwin) have their own pin and their own tracking skill.
---

# spinel-tracking: keep suppify compatible with the spinel commit it targets

suppify targets exactly **one** spinel commit at a time, recorded in `spinel.pin` at the
repo root. spinel is never vendored (submodule/subtree are forbidden by this repo's
CLAUDE.md) — it is cloned ephemerally, the same way `cc` is discovered on `PATH`. That
means spinel can change shape (a runtime header rename, a type-name change, a new/removed
runtime source file) at any point after `spinel.pin` was last set, silently, with no
signal from this repo's own green test suite (which never touches spinel unless you point
it at one).

## The two Rake tasks (deterministic — always start here)

```sh
rake spinel:latest              # matz/spinel's current upstream master SHA (no clone)
rake spinel:check_pin[<ref>]    # clone+build <ref>, run this repo's suite against it
                                 # ref defaults to spinel.pin's current contents
rake spinel:bump_pin[<ref>]     # check_pin[<ref>], and ONLY on success, write spinel.pin
```

`check_pin` never writes `spinel.pin` — a review gate, not an oversight. `bump_pin` is the
one-shot "adopt if it works" command; run it only once `check_pin` (or the investigation
below) has convinced you the diff is understood, not as a blind first move.

## Procedure

Create a TodoWrite item per step.

1. **Compare** `rake spinel:latest` against `spinel.pin`. If they match, tracking is
   current — stop here.
2. **Verify**: `rake spinel:check_pin[<latest-sha>]`. This clones spinel at that SHA,
   builds it, and runs the full suite against it (the tests that need a real spinel are
   otherwise skipped/omitted). Two independent things can fail:
   - **Test failures** — spinel's generated C, its runtime headers, or its CLI flags
     changed shape in a way that breaks `lib/suppify/{core,package,bindings}.rb`.
   - **Runtime source drift** — spinel's `Makefile`'s `RT_MEMBERS` no longer matches
     `Suppify::RuntimeSources::SOURCES` (`lib/suppify/package.rb`). This is printed
     separately from the test result and can be true even when every test still passes
     (a new optional runtime file this repo simply hasn't picked up yet).
3. **If green**: run `rake spinel:bump_pin[<latest-sha>]` and commit the resulting
   `spinel.pin` change (commit message: what spinel ref, and — if anything below
   applied — what had to change to reach green).
4. **If red**: diagnose before touching any code. `check_pin` leaves the failing clone on
   disk (its path is printed) — read the ACTUAL generated C, not assumptions from a prior
   spinel version:
   - **A public function's C type looks unfamiliar** (e.g. it no longer matches
     `NeutralType::TABLE` in `lib/suppify/core.rb`) — spinel renamed one of its
     boxed/native type aliases. Confirm by grepping the clone's `lib/*.h` for the
     typedef, then add the new name to `NeutralType::TABLE` (and `KIND` if it introduces
     a new marshalling category). Do not remove the old name reflexively — check whether
     any currently-supported spinel version besides the pin still needs it (usually none,
     since this repo only ever targets one commit, so the old name can go).
   - **A `#include` fails, or a symbol vanishes from discovery** (`SymbolPrefix` in
     `lib/suppify/package.rb`) — spinel renamed or relocated a runtime header (its
     `DISCOVERY_STUB`'s `#include` line names the one it currently expects). Grep the
     clone's `lib/` for the actual current filename and fix the constant.
   - **The "Runtime source list differs" print from step 2 is non-empty** — add or
     remove the named `.c` files in `RuntimeSources::SOURCES`, matching the clone's
     `Makefile`'s `RT_MEMBERS` line exactly (plus the `regexp/*.c` trio, always present).
   - Every test fixture that hardcodes a spinel-generated C type or filename (grep
     `test/` for the old name) needs the same rename — these assert on spinel's literal
     output, not suppify's own naming, so they must track spinel's current shape.
   - Re-run `rake spinel:check_pin[<latest-sha>]` after each fix until green, then do
     step 3.
5. **If a fix touches suppify's own public naming/behavior** (rare — most drift is
   internal), note it in `HANDOFF.md` under this repo's own conventions (not as a change
   log — a snapshot of what's true now) so a fresh session doesn't have to re-derive it.

## Downstream

A consumer that pins both spinel and suppify (e.g. R2P2-darwin's
`.github/aot-pins.yml`) upgrades **suppify's pin first, verified green here**, then
advances its own suppify pin to the new commit, then re-verifies its own AOT kernels
against that pair. Never skip straight to a newer spinel from a downstream repo — a
suppify pin that has not itself been verified against that spinel commit is not a known
state.
