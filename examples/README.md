# suppify examples

Runnable, repo-checked-in examples that go beyond the main README's minimal
`add`/`boom` walkthroughs: each one embeds a real suppify-generated
gem/mrbgem into something that actually runs it, and each is driven by a
single Rake task (no manual copy-pasting required).

## `fib`: embedding proof + edit-and-recompile + AOT vs interpreter benchmark

`fib/cruby/` and `fib/picoruby/` each hold two versions of the same `fib(n)`
method -- `fib_naive.rb` (a naive recursive definition) and `fib_iter.rb` (an
iterative rewrite of the exact same public signature, O(n) instead of
O(2^n)). Running the Rake task below builds *both* versions in turn, into
the same output directory each time -- i.e. it generates, builds, and runs
the naive version, then edits the source out from under it and does the
whole thing again with the iterative version. That's suppify's
modify-and-recompile workflow: there's no way to hand-edit the generated C,
gemspec, or mrbgem.rake and have it mean anything -- you always change the
original `.rb`, and re-run suppify.

Each run also proves the AOT-compiled `fib` actually works: before printing
any timing, the script asserts the AOT result matches a plain-interpreter
implementation of the same algorithm (defined directly in the benchmark
script, never touched by suppify), then reports how much faster the
AOT-compiled version is.

Requires the same environment as the main README's cruby/picoruby target
examples (`SPINEL_LIB`, and for picoruby, a picoruby checkout via
`PICORUBY_ROOT`):

```sh
export SPINEL_LIB=/path/to/spinel/lib
bundle exec rake examples:fib:cruby

export PICORUBY_ROOT=/path/to/picoruby
bundle exec rake examples:fib:picoruby
```

Neither task is part of the default `bundle exec rake test` -- like
`spinel:check_pin`, they need a real spinel (and, for picoruby, a real
picoruby checkout) and take real build time, so they're only run when
explicitly invoked.
