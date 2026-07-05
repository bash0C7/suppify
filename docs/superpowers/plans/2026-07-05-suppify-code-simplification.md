# suppify Code Simplification (Sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Plan-2 speculative code (suppify was never going to compile itself under spinel, and that direction is now explicitly decided against) and unrelated dead code from suppify's own Ruby codebase, without changing any observable behavior.

**Architecture:** Pure refactor across 8 independently-committable tasks. No new abstractions are introduced (per the design spec, de-duplicating `Builder#shell`/`SpinelRunner#shell` into a shared helper is explicitly out of scope — each is fixed independently). Each task: make the change, update any test assertions whose *expected format* (not behavior) changed, run the full suite, commit.

**Tech Stack:** Ruby (stdlib `json`, `open3`), `test-unit`, Rake.

**Spec:** `docs/superpowers/specs/2026-07-05-suppify-code-simplification-design.md`

**Working directory for all commands below:** `/Users/bash/dev/src/github.com/bash0C7/suppify/.claude/worktrees/suppify-cross-compile`

**Test environment setup (run once per shell before any `bundle exec rake test`):**

```bash
export PATH="$(pwd)/tmp/spinel/bin:$PATH"
export SPINEL_LIB="$(pwd)/tmp/spinel/lib"
export PICORUBY_ROOT=~/dev/src/github.com/picoruby/picoruby
```

**Starting state:** Task 1's changes are already applied to the working tree (uncommitted) from earlier work this session. Task 1 below verifies and commits them; Tasks 2-8 start from a clean tree after Task 1's commit.

---

### Task 1: Finish and commit the core-pipeline dead-code removal

**Files:**
- Modify: `lib/suppify/symbol_map.rb`
- Modify: `lib/suppify/neutral_type.rb`
- Modify: `lib/suppify/pipeline.rb`
- Modify: `test/test_symbol_map.rb`
- Modify: `test/test_neutral_type.rb`

These five files already have the following changes applied in the working tree (uncommitted). This task verifies they're correct and commits them.

- [ ] **Step 1: Confirm `lib/suppify/symbol_map.rb` matches this exactly**

```ruby
# lib/suppify/symbol_map.rb
require "suppify/json_parser"

module Suppify
  class SymbolMap
    def self.from_json(str)
      data = JSONParser.parse(str)
      new(data["symbols"] || [])
    end

    def initialize(entries)
      @by_ruby = {}
      entries.each { |e| @by_ruby[e["ruby"]] = e }
    end

    def cname_for(ruby_name)
      e = @by_ruby[ruby_name]
      e && e["c"]
    end
  end
end
```

(`kind_for` removed — it had no caller anywhere outside its own test.)

- [ ] **Step 2: Confirm `lib/suppify/neutral_type.rb` matches this exactly**

```ruby
# lib/suppify/neutral_type.rb
module Suppify
  # Maps spinel C types to neutral C types usable across a plain-C boundary.
  # Anything not in the table is non-neutral and raises.
  module NeutralType
    TABLE = {
      "mrb_int"       => "intptr_t",
      "double"        => "double",
      "mrb_float"     => "double",
      "const char *"  => "const char *",
      "bool"          => "int",
      "_Bool"         => "int",
      "mrb_bool"      => "int",
      "void"          => "void",
    }.freeze

    module_function

    def map(c_type)
      key = c_type.strip.gsub(/\s+/, " ")
      TABLE[key] or raise NonNeutralType, "non-neutral C type: #{c_type.inspect}"
    end

    # Classifies a C type into a marshalling category the language bindings
    # switch on. Raises (via map) on non-neutral types.
    KIND = {
      "intptr_t"     => :int,
      "double"       => :float,
      "const char *" => :string,
      "int"          => :bool,
      "void"         => :void,
    }.freeze

    def kind(c_type)
      key = c_type.strip.gsub(/\s+/, " ")
      neutral = TABLE[key] || key # spinel type -> neutral, or already neutral
      KIND.fetch(neutral) { raise NonNeutralType, "non-neutral C type: #{c_type.inspect}" }
    end
  end
end
```

(`neutral?` removed — no caller anywhere. The two mutable `"char *"` table/kind
entries removed — the design doc's string boundary type is `const char *`;
nothing in the pipeline ever produces bare `char *`.)

- [ ] **Step 3: Confirm `lib/suppify/pipeline.rb` matches this exactly**

```ruby
# lib/suppify/pipeline.rb
require "suppify/symbol_map"
require "suppify/visibility"
require "suppify/signature"
require "suppify/trampoline"
require "suppify/main_renamer"
require "suppify/header"

module Suppify
  class Pipeline
    def initialize(ruby_source:, c_source:, symbols_json:, lib_name:)
      @ruby_source = ruby_source
      @c_source    = c_source
      @symbols     = SymbolMap.from_json(symbols_json)
      @lib_name    = lib_name
    end

    def run
      exports = build_exports
      c = MainRenamer.rename(@c_source)
      c = c + Trampoline.render(exports, @lib_name)
      header = Header.render(@lib_name, exports)
      { exports: exports, c_source: c, header: header }
    end

    def build_exports
      Visibility.public_methods(@ruby_source).map do |ruby_name|
        cname = @symbols.cname_for(ruby_name)
        next nil unless cname # public method spinel did not emit (e.g. unused) — skip
        sig = SignatureExtractor.extract(@c_source, cname)
        { "public" => ruby_name, "cname" => cname, "sig" => sig }
      end.compact
    end
  end
end
```

(The early `NeutralType.map` pre-check removed — `Trampoline.render`, called
moments later in the same `run`, unconditionally re-runs the identical check
and raises the identical exception, so the pre-check could never be the site
that actually protects anything.)

- [ ] **Step 4: Confirm `test/test_symbol_map.rb` matches this exactly**

```ruby
# test/test_symbol_map.rb
require "test_helper"
require "suppify/symbol_map"

class TestSymbolMap < Test::Unit::TestCase
  def setup
    json = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"},' \
           '{"c":"sp_greet","ruby":"greet","kind":"toplevel"}]}'
    @map = Suppify::SymbolMap.from_json(json)
  end

  def test_cname_for_ruby_name
    assert_equal "sp_add", @map.cname_for("add")
    assert_equal "sp_greet", @map.cname_for("greet")
  end

  def test_unknown_returns_nil
    assert_nil @map.cname_for("missing")
  end
end
```

- [ ] **Step 5: Confirm `test/test_neutral_type.rb` matches this exactly**

```ruby
# test/test_neutral_type.rb
require "test_helper"
require "suppify/neutral_type"

class TestNeutralType < Test::Unit::TestCase
  def map(t) = Suppify::NeutralType.map(t)

  def test_mrb_int_to_intptr
    assert_equal "intptr_t", map("mrb_int")
  end

  def test_double_passthrough
    assert_equal "double", map("double")
  end

  def test_mrb_float_to_double
    assert_equal "double", map("mrb_float")
  end

  def test_const_char_ptr_passthrough
    assert_equal "const char *", map("const char *")
  end

  def test_bool_to_int
    assert_equal "int", map("bool")
    assert_equal "int", map("_Bool")
    assert_equal "int", map("mrb_bool")
  end

  def test_void_passthrough
    assert_equal "void", map("void")
  end

  def test_non_neutral_raises
    assert_raise(Suppify::NonNeutralType) { map("sp_RbVal") }
    assert_raise(Suppify::NonNeutralType) { map("sp_Proc *") }
  end

  # kind classifies a (spinel or neutral) C type into a language-agnostic
  # marshalling category the per-target bindings switch on.
  def test_kind_classifies_scalars
    assert_equal :int,    Suppify::NeutralType.kind("mrb_int")
    assert_equal :int,    Suppify::NeutralType.kind("intptr_t")
    assert_equal :float,  Suppify::NeutralType.kind("mrb_float")
    assert_equal :float,  Suppify::NeutralType.kind("double")
    assert_equal :string, Suppify::NeutralType.kind("const char *")
    assert_equal :bool,   Suppify::NeutralType.kind("mrb_bool")
    assert_equal :bool,   Suppify::NeutralType.kind("bool")
    assert_equal :void,   Suppify::NeutralType.kind("void")
  end

  def test_kind_raises_on_non_neutral
    assert_raise(Suppify::NonNeutralType) { Suppify::NeutralType.kind("sp_RbVal") }
  end
end
```

- [ ] **Step 6: Run the full test suite**

Run: `bundle exec rake test`
Expected: `116 tests, ... 0 failures, 0 errors` (117 minus 1 — deleting
`kind_for` also deletes its dedicated test method, `test_kind` in
`test/test_symbol_map.rb`; the other test edit only removes an assertion
line inside an existing method, so it doesn't change the count).

- [ ] **Step 7: Commit**

```bash
git add lib/suppify/symbol_map.rb lib/suppify/neutral_type.rb lib/suppify/pipeline.rb \
        test/test_symbol_map.rb test/test_neutral_type.rb
git commit -m "$(cat <<'EOF'
refactor: remove dead code in core pipeline

SymbolMap#kind_for and NeutralType.neutral? have no caller anywhere in
lib/ or test/ beyond their own unit tests. The two mutable "char *" table
entries in NeutralType handle a type shape the pipeline never produces
(the design's string boundary type is const char *). Pipeline#build_exports'
early NeutralType.map pre-check is redundant: Trampoline.render
unconditionally re-runs the identical check moments later in the same
Pipeline#run call, raising the same exception either way.
EOF
)"
```

---

### Task 2: Replace hand-rolled JSON parser with stdlib JSON

**Files:**
- Delete: `lib/suppify/json_parser.rb`
- Delete: `test/test_json_parser.rb`
- Modify: `lib/suppify/symbol_map.rb`
- Modify: `lib/suppify.rb`

This is the main Plan-2 speculative-complexity removal: `json_parser.rb`'s own
comment says "No JSON.parse (unavailable under spinel)" — written so suppify
itself could someday compile under spinel (an unstarted, now-decided-against
direction, per `docs/superpowers/plans/2026-06-21-suppify-core.md`'s "Plan 2").
suppify runs under CRuby only; stdlib `JSON` is always available.

- [ ] **Step 1: Delete the hand-rolled parser and its test**

```bash
rm lib/suppify/json_parser.rb test/test_json_parser.rb
```

- [ ] **Step 2: Update `lib/suppify/symbol_map.rb` to use stdlib JSON**

Replace the file's contents with:

```ruby
# lib/suppify/symbol_map.rb
require "json"

module Suppify
  class SymbolMap
    def self.from_json(str)
      data = JSON.parse(str)
      new(data["symbols"] || [])
    end

    def initialize(entries)
      @by_ruby = {}
      entries.each { |e| @by_ruby[e["ruby"]] = e }
    end

    def cname_for(ruby_name)
      e = @by_ruby[ruby_name]
      e && e["c"]
    end
  end
end
```

- [ ] **Step 3: Drop the now-dangling require from `lib/suppify.rb`**

In `lib/suppify.rb`, delete this line (it's currently line 8, right after
`require "suppify/signature"`):

```ruby
require "suppify/json_parser"
```

The file's `require` block should read (in order):

```ruby
require "suppify/neutral_type"
require "suppify/signature"
require "suppify/symbol_map"
require "suppify/visibility"
require "suppify/trampoline"
require "suppify/main_renamer"
require "suppify/header"
require "suppify/pipeline"
require "suppify/spinel_runner"
require "suppify/rbs_seed"
require "suppify/root_injector"
require "suppify/runtime_sources"
require "suppify/binding/cruby"
require "suppify/binding/mruby"
require "suppify/emitter/cruby_gem"
require "suppify/emitter/picoruby_gem"
require "suppify/builder"
require "suppify/cli"
```

- [ ] **Step 4: Run the full test suite**

Run: `bundle exec rake test`
Expected: `113 tests` (116 after Task 1, minus 3 — `test_json_parser.rb` has
three test methods, all deleted along with the file), `0 failures, 0 errors`.
`test/test_symbol_map.rb`'s two tests (which exercise `SymbolMap.from_json`,
now backed by `JSON.parse`) must still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add -A lib/suppify/json_parser.rb test/test_json_parser.rb \
           lib/suppify/symbol_map.rb lib/suppify.rb
git commit -m "$(cat <<'EOF'
refactor: use stdlib JSON instead of a hand-rolled parser

json_parser.rb existed only because suppify's own code was written
"subset-compatible" for an unstarted, now-decided-against future direction
(making suppify itself compile under spinel, which has no JSON.parse).
suppify runs under CRuby only, where stdlib JSON is always available.
EOF
)"
```

---

### Task 3: Simplify `binding/mruby.rb`'s `decls` method

**Files:**
- Modify: `lib/suppify/binding/mruby.rb`
- Modify: `test/test_binding_mruby.rb`

`decls` groups same-type parameters into one combined C declaration
(`mrb_int a0, a1;`) purely for cosmetic reasons — `mrb_get_args` only needs an
addressable slot per format char, and doesn't care whether those slots are
declared in one statement or several. Simplify to one declaration per
parameter.

- [ ] **Step 1: Replace `decls` in `lib/suppify/binding/mruby.rb`**

Find this method (around line 75-88):

```ruby
      # C declarations for the get_args locals, grouped by type in first-seen
      # order: "mrb_int a0, a1;" for values, "const char *a0, *a1;" for pointers.
      def decls(kinds)
        groups = {} # type => [indices]
        kinds.each_with_index { |k, i| (groups[GET[k][:type]] ||= []) << i }
        groups.map do |type, idxs|
          if type.end_with?("*")
            base = type.sub(/\s*\*+\s*\z/, "") # "const char *" -> "const char"
            "#{base} #{idxs.map { |i| "*a#{i}" }.join(', ')};"
          else
            "#{type} #{idxs.map { |i| "a#{i}" }.join(', ')};"
          end
        end.join(" ")
      end
```

Replace it with:

```ruby
      # C declarations for the get_args locals, one per parameter. A pointer
      # type (e.g. "const char *") already ends in "*", so no extra space is
      # inserted before the variable name; other types get a separating space.
      def decls(kinds)
        kinds.each_index.map do |i|
          type = GET[kinds[i]][:type]
          sep = type.end_with?("*") ? "" : " "
          "#{type}#{sep}a#{i};"
        end.join(" ")
      end
```

- [ ] **Step 2: Update the one test assertion whose expected text changes**

In `test/test_binding_mruby.rb`, `test_int_wrapper_uses_get_args_and_fixnum_return`
(the only fixture with two same-type params — `add(mrb_int, mrb_int)`) currently
has:

```ruby
    assert_match(/mrb_int a0, a1;/, @c)
```

Change it to:

```ruby
    assert_match(/mrb_int a0; mrb_int a1;/, @c)
```

No other assertion in this file changes — every other fixture has at most one
parameter, and a single-parameter declaration renders identically whether
grouped or not (e.g. `"const char *a0;"` either way).

- [ ] **Step 3: Run the full test suite**

Run: `bundle exec rake test`
Expected: `113 tests, 0 failures, 0 errors`.

- [ ] **Step 4: Commit**

```bash
git add lib/suppify/binding/mruby.rb test/test_binding_mruby.rb
git commit -m "$(cat <<'EOF'
refactor: emit one C declaration per param in the mruby binding

decls grouped same-type params into one combined declaration
(mrb_int a0, a1;) purely for cosmetic reasons -- mrb_get_args only needs
an addressable slot per format char, indifferent to how many declaration
statements they're spread across. binding/cruby.rb needs no analogous
machinery for the same kinds of signatures, confirming this was optional
styling, not something the ABI demands.
EOF
)"
```

---

### Task 4: Remove dead return values in the packaging layer

**Files:**
- Modify: `lib/suppify/runtime_sources.rb`
- Modify: `test/test_runtime_sources.rb`
- Modify: `lib/suppify/emitter/cruby_gem.rb`
- Modify: `lib/suppify/emitter/picoruby_gem.rb`
- Modify: `test/test_builder.rb`

`RuntimeSources.copy_flat` tracks and returns copied header basenames under a
`:headers` key that nothing reads (only its own test). `CRubyGem.emit` and
`PicoRubyGem.emit` return hashes (`{ gemspec:, ext_dir: }` / `{ gem_dir:,
gem_name:, init_func: }`) that their only production caller (`cli.rb`) invokes
as bare statements, never capturing. `PicoRubyGem.emit`'s `gem_name:` keyword
is never passed by any caller or test — hardcode it.

- [ ] **Step 1: Drop the `:headers` key from `copy_flat`'s return in `lib/suppify/runtime_sources.rb`**

Find:

```ruby
    def copy_flat(lib_dir, dest_dir)
      FileUtils.mkdir_p(dest_dir)
      sources = SOURCES.map do |rel|
        src = File.join(lib_dir, rel)
        raise Error, "spinel runtime source missing: #{src}" unless File.exist?(src)
        base = File.basename(rel)
        FileUtils.cp(src, File.join(dest_dir, base))
        base
      end
      headers = header_paths(lib_dir).map do |src|
        base = File.basename(src)
        FileUtils.cp(src, File.join(dest_dir, base))
        base
      end
      { sources: sources, headers: headers }
    end
```

Replace with (keeps the file-copy side effect, drops the unused tracking/return):

```ruby
    def copy_flat(lib_dir, dest_dir)
      FileUtils.mkdir_p(dest_dir)
      sources = SOURCES.map do |rel|
        src = File.join(lib_dir, rel)
        raise Error, "spinel runtime source missing: #{src}" unless File.exist?(src)
        base = File.basename(rel)
        FileUtils.cp(src, File.join(dest_dir, base))
        base
      end
      header_paths(lib_dir).each do |src|
        FileUtils.cp(src, File.join(dest_dir, File.basename(src)))
      end
      { sources: sources }
    end
```

- [ ] **Step 2: Update `test/test_runtime_sources.rb`**

In `test_copy_flat_copies_sources_and_headers_by_basename`, delete these two
lines:

```ruby
      assert_includes result[:headers], "sp_runtime.h"
      assert_includes result[:headers], "re_internal.h"
```

Keep the rest of the test (including the `assert File.exist?(...)` checks a
few lines below, which verify the copy side effect directly rather than via
the return value).

- [ ] **Step 3: Drop the unused return value from `lib/suppify/emitter/cruby_gem.rb`**

Find the last two lines of `emit`:

```ruby
        File.write(File.join(out_dir, "#{lib_name}.gemspec"), gemspec(lib_name, version, license))

        { gemspec: File.join(out_dir, "#{lib_name}.gemspec"), ext_dir: ext }
      end
```

Replace with:

```ruby
        File.write(File.join(out_dir, "#{lib_name}.gemspec"), gemspec(lib_name, version, license))
      end
```

- [ ] **Step 4: Drop the unused `gem_name:` keyword and return value from `lib/suppify/emitter/picoruby_gem.rb`**

Find:

```ruby
      def emit(lib_name:, c_source:, header:, exports:, spinel_lib:, out_dir:, gem_name: nil,
               discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
               version: "0.1.0", license: "MIT")
        gem_name ||= "picoruby-#{lib_name}"
        init_func = "mrb_#{gem_name.tr('-', '_')}_gem_init"
```

Replace with:

```ruby
      def emit(lib_name:, c_source:, header:, exports:, spinel_lib:, out_dir:,
               discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
               version: "0.1.0", license: "MIT")
        gem_name = "picoruby-#{lib_name}"
        init_func = "mrb_#{gem_name.tr('-', '_')}_gem_init"
```

Then find the last two lines of the same method:

```ruby
        File.write(File.join(out_dir, "mrbgem.rake"), mrbgem_rake(gem_name, lib_name, version, license))
        { gem_dir: out_dir, gem_name: gem_name, init_func: init_func }
      end
```

Replace with:

```ruby
        File.write(File.join(out_dir, "mrbgem.rake"), mrbgem_rake(gem_name, lib_name, version, license))
      end
```

- [ ] **Step 5: Update the two `copy_runtime` fakes in `test/test_builder.rb` to match the new `copy_flat` shape**

In `test_compiles_generated_source_and_bundled_runtime_with_prelude_then_archives`,
find:

```ruby
      fake_copy_runtime = lambda do |_lib, dest|
        FileUtils.mkdir_p(dest)
        FileUtils.touch(File.join(dest, "sp_gc.c"))
        { sources: ["sp_gc.c"], headers: [] }
      end
```

Replace with:

```ruby
      fake_copy_runtime = lambda do |_lib, dest|
        FileUtils.mkdir_p(dest)
        FileUtils.touch(File.join(dest, "sp_gc.c"))
        { sources: ["sp_gc.c"] }
      end
```

In `test_cc_failure_raises`, find:

```ruby
    copy_runtime = lambda do |_lib, dest|
      FileUtils.mkdir_p(dest)
      { sources: [], headers: [] }
    end
```

Replace with:

```ruby
    copy_runtime = lambda do |_lib, dest|
      FileUtils.mkdir_p(dest)
      { sources: [] }
    end
```

- [ ] **Step 6: Run the full test suite**

Run: `bundle exec rake test`
Expected: `113 tests, 0 failures, 0 errors`.

- [ ] **Step 7: Commit**

```bash
git add lib/suppify/runtime_sources.rb test/test_runtime_sources.rb \
        lib/suppify/emitter/cruby_gem.rb lib/suppify/emitter/picoruby_gem.rb \
        test/test_builder.rb
git commit -m "$(cat <<'EOF'
refactor: drop dead return values and an unused keyword in the packaging layer

RuntimeSources.copy_flat's :headers key, both gem emitters' return hashes,
and PicoRubyGem.emit's gem_name: keyword have no reader anywhere in lib/
or test/ beyond copy_flat's own test asserting on :headers. cli.rb (the
only production caller of both emitters) invokes .emit as a bare statement.
EOF
)"
```

---

### Task 5: Remove `Builder#default_lib`

**Files:**
- Modify: `lib/suppify/builder.rb`

`ENV["SPINEL_LIB"] || default_lib` (where `default_lib` returns `""`) is
exactly equivalent to `ENV["SPINEL_LIB"].to_s`, since `ENV[...]` is always
`nil` or a `String`. `cli.rb` already uses the plain `.to_s` idiom for the same
need elsewhere in this codebase.

- [ ] **Step 1: Inline the fallback and delete the wrapper method**

Find:

```ruby
    def initialize(spinel_lib: ENV["SPINEL_LIB"] || default_lib,
                   runner: method(:shell),
                   discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
                   copy_runtime: RuntimeSources.method(:copy_flat))
```

Replace with:

```ruby
    def initialize(spinel_lib: ENV["SPINEL_LIB"].to_s,
                   runner: method(:shell),
                   discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
                   copy_runtime: RuntimeSources.method(:copy_flat))
```

Then delete the `default_lib` method entirely:

```ruby
    def default_lib
      ""
    end
```

- [ ] **Step 2: Run the full test suite**

Run: `bundle exec rake test`
Expected: `113 tests, 0 failures, 0 errors`. `test/test_builder.rb` always
passes `spinel_lib:` explicitly, so this default-value path isn't covered by
(and can't break) any existing test.

- [ ] **Step 3: Commit**

```bash
git add lib/suppify/builder.rb
git commit -m "$(cat <<'EOF'
refactor: inline Builder's default_lib wrapper

ENV["SPINEL_LIB"] || default_lib (default_lib always returning "") is
exactly ENV["SPINEL_LIB"].to_s, since ENV[...] is always nil or a String.
cli.rb already uses the plain .to_s idiom for the same need elsewhere.
EOF
)"
```

---

### Task 6: Replace backtick shell runners with `Open3`

**Files:**
- Modify: `lib/suppify/spinel_runner.rb`
- Modify: `lib/suppify/builder.rb`
- Modify: `test/test_spinel_runner.rb`
- Modify: `test/test_builder.rb`

Both `SpinelRunner#shell` and `Builder#shell` build a command as one
interpolated string and run it via backtick + `$?.exitstatus`.
`spinel_runner.rb`'s copy carries the comment "kept subset-compatible for
Plan 2" — moot now. Switching to `Open3` with array-form argv also means paths
are never interpreted by a shell, closing a latent shell-injection surface
(a filename containing shell metacharacters could otherwise affect the
command line). This changes the injected `runner:` callable's contract from
`callable(cmd_string) -> [stdout, exitstatus]` to
`callable(argv_array) -> [stdout, exitstatus]`, so every caller that builds a
command and every test fake that captures one must move from strings to
arrays.

- [ ] **Step 1: Rewrite `lib/suppify/spinel_runner.rb`**

Replace the entire file with:

```ruby
# lib/suppify/spinel_runner.rb
require "open3"

module Suppify
  class SpinelRunner
    # runner: callable(argv_array) -> [stdout_string, exit_status_int]
    # rbs_dir: directory of *.rbs sidecars fed to spinel's --rbs (advisory
    # type seeding; see RootInjector for why suppify needs this).
    def initialize(spinel_bin: ENV["SPINEL"] || "spinel", runner: method(:shell), rbs_dir: nil)
      @spinel_bin = spinel_bin
      @runner = runner
      @rbs_dir = rbs_dir
    end

    # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
    # emit modes (the symbol-map path short-circuits before the C-output
    # branch), so the two artifacts require separate invocations.
    def emit(rb_path, c_path)
      symbols_path = c_path.sub(/\.c\z/, "") + ".symbols.json"
      rbs_args = @rbs_dir ? ["--rbs", @rbs_dir] : []
      run!([@spinel_bin, rb_path, *rbs_args, "-c", "-o", c_path])
      run!([@spinel_bin, rb_path, "--emit-symbol-map", "-o", symbols_path])
      { c_path: c_path, symbols_path: symbols_path }
    end

    # Default runner: array-form argv, no shell involved.
    def shell(argv)
      out, status = Open3.capture2e(*argv)
      [out, status.exitstatus]
    end

    private

    def run!(argv)
      out, status = @runner.call(argv)
      raise Error, "spinel failed (#{status}): #{out}" unless status == 0
    end
  end
end
```

- [ ] **Step 2: Update `test/test_spinel_runner.rb`**

Replace the entire file with:

```ruby
# test/test_spinel_runner.rb
require "test_helper"
require "suppify/spinel_runner"

class TestSpinelRunner < Test::Unit::TestCase
  # Real spinel treats `-c` and `--emit-symbol-map` as mutually exclusive
  # emit modes (src/main.c: emit_symbol_map short-circuits before the
  # c_only branch, so a combined invocation silently drops the C output).
  # SpinelRunner must therefore issue two separate invocations.
  def test_builds_two_commands_and_returns_paths
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "/opt/spinel", runner: fake)
    out = r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["/opt/spinel", "/work/app.rb", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["/opt/spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
    assert_equal "/tmp/app.c", out[:c_path]
    assert_equal "/tmp/app.symbols.json", out[:symbols_path]
  end

  def test_nonzero_status_raises_on_c_step
    fake = ->(_argv) { ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_nonzero_status_raises_on_symbol_map_step
    calls = 0
    fake = ->(_argv) { calls += 1; calls == 1 ? ["", 0] : ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end

  def test_includes_rbs_flag_on_c_step_only_when_given
    captured = []
    fake = ->(argv) { captured << argv; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake, rbs_dir: "/work/sigs")
    r.emit("/work/app.rb", "/tmp/app.c")
    assert_equal ["spinel", "/work/app.rb", "--rbs", "/work/sigs", "-c", "-o", "/tmp/app.c"], captured[0]
    assert_equal ["spinel", "/work/app.rb", "--emit-symbol-map", "-o", "/tmp/app.symbols.json"], captured[1]
  end
end
```

- [ ] **Step 3: Rewrite `lib/suppify/builder.rb`**

Replace the entire file with (this is Task 5's file plus the argv change —
`default_lib` is already gone from Task 5):

```ruby
# lib/suppify/builder.rb
require "open3"
require "fileutils"
require "suppify/runtime_sources"
require "suppify/symbol_prefix"

module Suppify
  # Builds the "c" target: compiles the generated translation unit AND a
  # bundled (recompiled, not prebuilt-copied) copy of the spinel runtime into
  # one self-contained lib<name>.a. The runtime is recompiled per library
  # (rather than reusing spinel's own prebuilt libspinel_rt.a) so its ~600
  # global symbols can be namespaced by SymbolPrefix -- otherwise two
  # suppify-built libraries linked into the same binary would collide on
  # spinel's shared runtime state.
  class Builder
    def initialize(spinel_lib: ENV["SPINEL_LIB"].to_s,
                   runner: method(:shell),
                   discover_symbols: SymbolPrefix.method(:discover_runtime_symbols),
                   copy_runtime: RuntimeSources.method(:copy_flat))
      @spinel_lib = spinel_lib
      @runner = runner
      @discover_symbols = discover_symbols
      @copy_runtime = copy_runtime
    end

    def build(c_path:, lib_name:, out_dir:)
      build_dir = File.dirname(c_path)
      runtime_dir = File.join(build_dir, "#{lib_name}_runtime")
      copied = @copy_runtime.call(@spinel_lib, runtime_dir)

      prelude_path = File.join(build_dir, "#{lib_name}_prelude.h")
      symbols = @discover_symbols.call(@spinel_lib)
      File.write(prelude_path, SymbolPrefix.prelude(lib_name, symbols))

      sources = [c_path] + copied[:sources].map { |base| File.join(runtime_dir, base) }
      objs = sources.map { |src| compile(src, runtime_dir, prelude_path) }

      archive = File.join(out_dir, "lib#{lib_name}.a")
      run! ["ar", "rcs", archive, *objs]
      { archive: archive }
    end

    def compile(src, runtime_dir, prelude_path)
      o_path = src.sub(/\.c\z/, ".o")
      run! ["cc", "-c", src, "-I#{runtime_dir}", "-include", prelude_path, "-o", o_path]
      o_path
    end

    def run!(argv)
      out, status = @runner.call(argv)
      raise Error, "command failed (#{status}): #{argv.join(' ')}\n#{out}" unless status == 0
    end

    # Default runner: array-form argv, no shell involved.
    def shell(argv)
      out, status = Open3.capture2e(*argv)
      [out, status.exitstatus]
    end
  end
end
```

- [ ] **Step 4: Update `test/test_builder.rb` for the argv change**

In `test_compiles_generated_source_and_bundled_runtime_with_prelude_then_archives`,
find:

```ruby
      cmds = []
      fake_runner = ->(cmd) { cmds << cmd; ["", 0] }
```

Replace with:

```ruby
      cmds = []
      fake_runner = ->(argv) { cmds << argv; ["", 0] }
```

A few lines later, find:

```ruby
      runtime_c = File.join(dir, "mylib_runtime", "sp_gc.c")
      cc_cmds = cmds.select { |c| c.start_with?("cc ") }
      assert cc_cmds.any? { |c| c.include?(c_path) && c.include?("-include #{prelude_path}") }
      assert cc_cmds.any? { |c| c.include?(runtime_c) && c.include?("-include #{prelude_path}") }

      ar_cmd = cmds.find { |c| c.start_with?("ar ") }
      assert_match(%r{ar rcs #{out_dir}/libmylib\.a}, ar_cmd)
      assert ar_cmd.include?(c_path.sub(/\.c\z/, ".o"))
      assert ar_cmd.include?(runtime_c.sub(/\.c\z/, ".o"))
      assert_equal File.join(out_dir, "libmylib.a"), out[:archive]
```

Replace with:

```ruby
      runtime_c = File.join(dir, "mylib_runtime", "sp_gc.c")
      cc_cmds = cmds.select { |c| c.first == "cc" }
      assert cc_cmds.any? { |c| c.include?(c_path) && c.include?("-include") && c.include?(prelude_path) }
      assert cc_cmds.any? { |c| c.include?(runtime_c) && c.include?("-include") && c.include?(prelude_path) }

      ar_cmd = cmds.find { |c| c.first == "ar" }
      assert_equal File.join(out_dir, "libmylib.a"), ar_cmd[2]
      assert ar_cmd.include?(c_path.sub(/\.c\z/, ".o"))
      assert ar_cmd.include?(runtime_c.sub(/\.c\z/, ".o"))
      assert_equal File.join(out_dir, "libmylib.a"), out[:archive]
```

In `test_cc_failure_raises`, find:

```ruby
    fake = ->(_cmd) { ["err", 1] }
```

Replace with:

```ruby
    fake = ->(_argv) { ["err", 1] }
```

- [ ] **Step 5: Run the full test suite**

Run: `bundle exec rake test`
Expected: `113 tests, 0 failures, 0 errors`.

- [ ] **Step 6: Commit**

```bash
git add lib/suppify/spinel_runner.rb lib/suppify/builder.rb \
        test/test_spinel_runner.rb test/test_builder.rb
git commit -m "$(cat <<'EOF'
refactor: run spinel/cc/ar via Open3 with array argv, not a shell

Both default runners built one interpolated command string and ran it
via backtick + \$?.exitstatus, justified in spinel_runner.rb by a
"kept subset-compatible for Plan 2" comment -- moot now that suppify
compiling itself under spinel isn't a direction. Array-form Open3.capture2e
also means a path containing shell metacharacters is never interpreted by
a shell, closing a latent injection surface as a side effect.
EOF
)"
```

---

### Task 7: Clean up `cli.rb` and root `suppify.rb`

**Files:**
- Modify: `lib/suppify/cli.rb`
- Modify: `suppify.rb` (repo-root entrypoint script — distinct from `lib/suppify.rb`)

`cli.rb`'s hand-rolled arg parser carries the comment "optparse-free so it
compiles under spinel too" — both moot (Plan 2 is off the table) and actually
false even on its own terms (`docs/superpowers/specs/2026-06-21-suppify-design.md`
says `optparse` *is* available under spinel via a stub). **Do not swap to
`OptionParser`** — verified empirically that a plain `OptionParser` swap
reintroduces the exact bug `flag_value!` fixed (a flag-shaped value silently
swallows the next flag), unless the same validation is reimplemented, so it
isn't a net simplification. Only the comment is wrong; the parser itself
stays. `cli.rb#run`'s `tmp_dir:` keyword is never called with a non-default
value anywhere. The root `suppify.rb` script has a stale "Plan 2" comment and
a redundant require.

- [ ] **Step 1: Rewrite the misleading comment on `CLI.parse` in `lib/suppify/cli.rb`**

Find:

```ruby
    # Minimal arg parsing (optparse-free so it compiles under spinel too).
    def parse(argv)
```

Replace with:

```ruby
    # Hand-rolled rather than OptionParser: flag_value! (below) must reject a
    # flag's value when it's missing or looks like another flag, which plain
    # OptionParser switches don't validate on their own.
    def parse(argv)
```

- [ ] **Step 2: Drop the unused `tmp_dir:` keyword from `CLI.run`**

Find:

```ruby
    def run(argv, tmp_dir: ".suppify-tmp")
      opts = parse(argv)
      require "fileutils"
      FileUtils.mkdir_p(tmp_dir)
```

Replace with:

```ruby
    def run(argv)
      opts = parse(argv)
      require "fileutils"
      tmp_dir = ".suppify-tmp"
      FileUtils.mkdir_p(tmp_dir)
```

- [ ] **Step 3: Update the root `suppify.rb` entrypoint script**

Replace the entire file with:

```ruby
# suppify.rb
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "suppify"
exit Suppify::CLI.run(ARGV)
```

(Removed: the "(compiled by spinel in Plan 2; runs under CRuby for dev)"
comment — Plan 2 is no longer a direction. Removed: the redundant
`require "suppify/cli"` — `require "suppify"` already transitively loads it,
since `lib/suppify.rb`'s own require list ends with `require "suppify/cli"`.)

- [ ] **Step 4: Run the full test suite**

Run: `bundle exec rake test`
Expected: `113 tests, 0 failures, 0 errors`. No test anywhere calls
`Suppify::CLI.run` with a `tmp_dir:` argument (confirmed by grep across
`lib/`, `test/`, and `suppify.rb`), so this is unaffected.

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/cli.rb suppify.rb
git commit -m "$(cat <<'EOF'
refactor: fix a misleading comment, drop an unused keyword and stale note

cli.rb's arg parser comment claimed it avoids optparse "so it compiles
under spinel too" -- both moot (Plan 2 is decided against) and wrong on
its own terms (the design doc says optparse is available under spinel).
The parser itself stays (flag_value!'s flag-shaped-value validation isn't
something OptionParser provides for free). CLI.run's tmp_dir: keyword is
never called with a non-default value anywhere. Root suppify.rb's "Plan 2"
comment and its redundant require "suppify/cli" (already loaded
transitively via require "suppify") are both dropped.
EOF
)"
```

---

### Task 8: Record the Plan-2 decision in HANDOFF.md

**Files:**
- Modify: `HANDOFF.md`

- [ ] **Step 1: Add a new section to `HANDOFF.md`**

Insert this new section immediately after the "symbol namespacing 実装の敵対的検証で発見・修正した5件" section's closing paragraph (after the line starting "**注記**: main には Plan 1..." and before the "## このリポジトリは何か" heading):

```markdown
## Plan 2（自己ホスト化）は不要と判断

`docs/superpowers/plans/2026-06-21-suppify-core.md` に記載されていた、suppify
自身をいずれ spinel でコンパイルするという未着手の構想（Plan 2）は不要と判断
された。これを見越して書かれていた投機的コード（自前 JSON パーサ、backtick
シェル実行、CLI の誤った根拠コメント）は簡素化パスで削除済み
（`docs/superpowers/specs/2026-07-05-suppify-code-simplification-design.md`）。
`docs/superpowers/plans/2026-06-21-suppify-core.md` 自体は Plan 1 の完了済み
計画書として履歴のまま残す。
```

- [ ] **Step 2: Commit**

```bash
git add HANDOFF.md
git commit -m "docs: record that Plan 2 (self-hosting) is decided against"
```

---

## Final verification

- [ ] Run the full suite once more from a clean shell to confirm the whole
  sequence composes correctly:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/suppify/.claude/worktrees/suppify-cross-compile
export PATH="$(pwd)/tmp/spinel/bin:$PATH"
export SPINEL_LIB="$(pwd)/tmp/spinel/lib"
export PICORUBY_ROOT=~/dev/src/github.com/picoruby/picoruby
bundle exec rake test
```

Expected: `113 tests, ... 0 failures, 0 errors` (117 minus 1 for Task 1's
deleted `test_kind`, minus 3 for Task 2's deleted `test_json_parser.rb`
methods), same omission count as before (environment-gated integration
tests, unaffected by this refactor).

- [ ] Confirm the working tree is clean and every change landed as its own
  commit:

```bash
git status --short
git log --oneline -8
```
