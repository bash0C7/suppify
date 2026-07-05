# suppify code simplification (sub-project A) — design

## Goal

Remove speculative and dead complexity from suppify's own Ruby codebase without
changing observable behavior. Two independent sources of unnecessary
complexity, found via a fresh-context review + adversarial verification pass:

1. **Plan-2 speculative code.** `docs/superpowers/plans/2026-06-21-suppify-core.md`
   documents an unstarted, unspec'd future direction ("Plan 2": making suppify
   itself compile under spinel). Several places in the current, actually-shipping
   code were written in a "subset-compatible" style to avoid rework if Plan 2
   ever happens. Plan 2 is decided against — suppify will not compile itself
   under spinel. The resulting speculative code should go.
2. **Dead code / redundant validation**, unrelated to Plan 2, found by the same
   review pass: unused methods, unused return values, an unused keyword
   argument, a validation that's unconditionally re-run downstream, a trivial
   wrapper method.

This is a pure refactor: delete/simplify, do not add behavior, do not
introduce new abstractions (e.g. no shared "runner" class to de-duplicate
`Builder#shell` / `SpinelRunner#shell` — each is fixed independently).

## Changes

### Plan-2 speculative code

| File | Change |
|---|---|
| `lib/suppify/json_parser.rb` | Delete (111-line hand-rolled recursive-descent JSON parser). |
| `lib/suppify/symbol_map.rb` | `require "json"`; use `JSON.parse` instead of `Suppify::JSONParser.parse`. |
| `lib/suppify.rb` | Drop the `require "suppify/json_parser"` line. |
| `test/test_json_parser.rb` | Delete. |
| `lib/suppify/spinel_runner.rb` (`#shell`) | Replace backtick + `$?.exitstatus` with `Open3.capture2e` using array-form argv (no shell interpolation of paths). |
| `lib/suppify/builder.rb` (`#shell`) | Same fix, applied independently (no shared helper). |
| `lib/suppify/cli.rb` | Rewrite the "optparse-free so it compiles under spinel too" comment on `parse` — the stated reason is both false (the design doc says `optparse` *is* available under spinel) and moot (Plan 2 is off the table). State the real reason instead: `flag_value!` validates that a flag's value isn't itself flag-shaped, which is why this isn't a bare stdlib argv scan. **Do not swap to `OptionParser`** — confirmed empirically that a plain `OptionParser` swap reintroduces the exact bug `flag_value!` fixed (a flag-shaped value silently swallows the next flag) unless the same validation is reimplemented, so it isn't a net simplification. |
| `suppify.rb` (repo-root entrypoint) | Remove the "(compiled by spinel in Plan 2; runs under CRuby for dev)" parenthetical from the top comment — Plan 2 is no longer a direction, so this is left as a plain entrypoint comment describing only what the file does today. |

### Dead code / redundant validation (independent of Plan 2)

| File | Change |
|---|---|
| `lib/suppify/symbol_map.rb` | Delete `kind_for` (no caller outside its own test). |
| `test/test_symbol_map.rb` | Delete `test_kind`. |
| `lib/suppify/neutral_type.rb` | Delete `neutral?` (no caller anywhere). Delete the two mutable `"char *"` entries in `TABLE`/`KIND` (the design doc's string boundary type is `const char *`; nothing in the pipeline ever produces bare `char *`). |
| `test/test_neutral_type.rb` | Drop the `"char *"` assertion in `test_kind_classifies_scalars`. |
| `lib/suppify/pipeline.rb` | Delete `build_exports`'s early `NeutralType.map` pre-check (lines calling `.map` and discarding the result) — `Trampoline.render` unconditionally re-runs the identical check moments later in the same `Pipeline#run` call, raising the same exception class/message; the pre-check can never be the site that actually protects anything. |
| `lib/suppify/binding/mruby.rb` | Simplify `decls` from a type-grouping hash (~11 lines, combines same-type params into one declaration, e.g. `mrb_int a0, a1;`) to one declaration per parameter (`mrb_int a0; mrb_int a1;`). Purely cosmetic C source difference; `mrb_get_args` doesn't care. |
| `test/test_binding_mruby.rb` | Update assertions to match the ungrouped declaration format. |
| `lib/suppify/runtime_sources.rb` | Drop the `:headers` key from `copy_flat`'s return hash (keep the actual `FileUtils.cp` side effect — only the *tracking/returning* of header basenames is unused). |
| `test/test_runtime_sources.rb` | Drop the assertion on `[:headers]`. |
| `lib/suppify/emitter/cruby_gem.rb`, `lib/suppify/emitter/picoruby_gem.rb` | Drop `emit`'s return hash (`{ gemspec:, ext_dir: }` / `{ gem_dir:, gem_name:, init_func: }`) — no production caller (`cli.rb`) or test reads it. |
| `lib/suppify/emitter/picoruby_gem.rb` | Drop the unused `gem_name:` keyword argument; hardcode `gem_name = "picoruby-#{lib_name}"`. |
| `lib/suppify/builder.rb` | Delete `default_lib` (a one-line wrapper returning `""`); inline as `ENV["SPINEL_LIB"].to_s` (`cli.rb` already uses this exact idiom elsewhere in the same codebase). |
| `lib/suppify/cli.rb` | Drop `CLI.run`'s unused `tmp_dir:` keyword argument; hardcode `".suppify-tmp"` as a local. |
| `lib/suppify.rb` | Delete the redundant `require "suppify/cli"` (already transitively loaded by `require "suppify"` itself). |

### Comment pruning (new, per user request this round)

While touching each file above, review its existing comments and delete any
that are non-essential — comments that just restate what the adjacent code
already says, or that describe a *now-removed* Plan-2 rationale. Keep only
comments carrying a genuinely non-obvious "why" (a hidden constraint, a
verified bug-fix rationale, a subtle invariant). This is scoped to the files
touched by this sub-project, not a repo-wide comment sweep.

### Docs

- `HANDOFF.md`: add a note recording that Plan 2 (self-hosting suppify under
  spinel) was decided against, and that this pass removed the resulting
  speculative code plus unrelated dead code.
- `docs/superpowers/plans/2026-06-21-suppify-core.md`: **not edited** — it's a
  completed-phase planning artifact (historical record of Plan 1), not a
  living status doc.

## Out of scope

- Extracting a shared runner/shell helper to de-duplicate `Builder#shell` /
  `SpinelRunner#shell` — the project avoids adding new abstractions; each is
  fixed independently in place.
- Sub-projects B (spinel re-pin as a repeatable process) and C (Bundler-only
  gem workflow / README update) — separate specs, done after this one lands.

## Testing

Refactor discipline, not new-feature TDD: for each removal/simplification,
run `bundle exec rake test` (spinel + picoruby present) and confirm the full
117-test suite stays green with no new failures. Where a change alters an
observable output (Open3 swap's process invocation shape, `decls`'s emitted
C text), update the corresponding test assertion to match the new output,
then re-run to confirm green — but no new test *cases* are added, since no
new behavior is introduced.
