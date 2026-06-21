# suppify Core (Plan 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build suppify's deterministic transform pipeline that turns a spinel-compiled Ruby file into a neutral C library (`.a` + header), exporting the source's public methods.

**Architecture:** Pure Ruby modules with single responsibilities, wired by a `Pipeline`. The transform is driven from three inputs — the Ruby source (visibility via prism), spinel's `--emit-symbol-map` JSON (name↔cname), and the generated `.c` (signatures) — and appends extern trampolines + `sp_lib_init` to the generated C, renames `main`, and emits a neutral header. spinel itself is never modified; suppify shells out to it. Unit tests are hermetic (handwritten fixtures, no spinel); one integration test runs real spinel when available.

**Tech Stack:** Ruby (subset kept spinel-compilable), test-unit, prism gem, bundler with repo-local `vendor/bundle`. External tools at runtime: `spinel`, `cc`, `ar`.

**Design note — module boundaries:**
- `Suppify::JSONParser` — hand-rolled JSON parse (no `JSON.parse`; subset-safe).
- `Suppify::SymbolMap` — wraps parsed symbol-map entries; `ruby` → entry lookup.
- `Suppify::Visibility` — prism-gem backend computing the public method-name set of a source. (Plan 2 adds a libprism-FFI backend; the `Pipeline` depends only on the resulting name set, so the core stays backend-agnostic.)
- `Suppify::Signature` + `Suppify::SignatureExtractor` — value object + extractor that reads a function's C signature out of generated C by cname.
- `Suppify::NeutralType` — maps spinel C types → neutral C types; raises on non-neutral.
- `Suppify::Trampoline` — emits trampolines + error funcs + `sp_lib_init`.
- `Suppify::MainRenamer` — renames `int main(...)` → `static int sp__main(...)`.
- `Suppify::Header` — emits the neutral `.h`.
- `Suppify::Pipeline` — orchestrates the in-memory transform (no external processes).
- `Suppify::SpinelRunner` / `Suppify::Builder` — external-process edges (run spinel; cc+ar), injected command runner for testability.
- `Suppify::CLI` — `suppify app.rb -o <name>`.

**Conventions locked here:**
- Exported public C symbol = the Ruby method name verbatim (e.g. `add`). (Collision avoidance is the author's concern, as with any C library; the spec's `LIBNAME_` prefix was illustrative.)
- Error API: `int suppi_error(void)`, `const char *suppi_error_message(void)`.
- Init: `void sp_lib_init(void)`.
- Neutral type map: `mrb_int`→`intptr_t`, `double`→`double`, `const char *`→`const char *`, `bool`/`_Bool`→`int`. Anything else → non-neutral (error).

---

## Task 1: Project scaffolding

**Files:**
- Create: `Gemfile`
- Create: `.bundle/config`
- Create: `Rakefile`
- Create: `lib/suppify.rb`
- Create: `test/test_helper.rb`

- [ ] **Step 1: Write the Gemfile**

```ruby
# Gemfile
source "https://rubygems.org"

gem "prism"

group :development, :test do
  gem "test-unit"
  gem "rake"
end
```

- [ ] **Step 2: Pin bundler to repo-local path**

```toml
# .bundle/config
---
BUNDLE_PATH: "vendor/bundle"
```

- [ ] **Step 3: Write the Rakefile**

```ruby
# Rakefile
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/test_*.rb"]
  t.warning = false
end

task default: :test
```

- [ ] **Step 4: Create the library entrypoint (empty requires for now)**

```ruby
# lib/suppify.rb
module Suppify
  class Error < StandardError; end
  class NonNeutralType < Error; end
end
```

- [ ] **Step 5: Create the test helper**

```ruby
# test/test_helper.rb
require "test/unit"
require "suppify"
```

- [ ] **Step 6: Install and verify the harness runs**

Run: `bundle install && bundle exec rake test`
Expected: Bundler installs into `vendor/bundle`; rake reports `0 tests, 0 assertions, 0 failures` (no test files yet — exit 0).

- [ ] **Step 7: Commit**

```bash
git add Gemfile Gemfile.lock .bundle/config Rakefile lib/suppify.rb test/test_helper.rb
git commit -m "chore: scaffold suppify with test-unit + prism (bundler vendor/bundle)"
```

---

## Task 2: JSONParser (hand-rolled, subset-safe)

**Files:**
- Create: `lib/suppify/json_parser.rb`
- Test: `test/test_json_parser.rb`
- Modify: `lib/suppify.rb` (add require)

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_json_parser.rb
require "test_helper"
require "suppify/json_parser"

class TestJSONParser < Test::Unit::TestCase
  def parse(s) = Suppify::JSONParser.parse(s)

  def test_object_array_of_objects
    json = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"}]}'
    result = parse(json)
    assert_equal "sp_add", result["symbols"][0]["c"]
    assert_equal "add",    result["symbols"][0]["ruby"]
  end

  def test_scalars_and_nesting
    assert_equal({"a" => 1, "b" => [true, false, nil], "c" => "x\"y"},
                 parse('{"a":1,"b":[true,false,null],"c":"x\"y"}'))
  end

  def test_empty_containers
    assert_equal({"a" => [], "b" => {}}, parse('{"a":[],"b":{}}'))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_json_parser.rb`
Expected: FAIL — cannot load `suppify/json_parser`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/json_parser.rb
module Suppify
  # Minimal recursive-descent JSON parser. No JSON.parse (unavailable under
  # spinel). Handles the subset spinel emits: objects, arrays, strings,
  # integers, floats, true/false/null.
  module JSONParser
    module_function

    def parse(str)
      @s = str
      @i = 0
      v = parse_value
      skip_ws
      raise Error, "trailing data at #{@i}" if @i < @s.length
      v
    end

    def parse_value
      skip_ws
      c = @s[@i]
      case c
      when "{" then parse_object
      when "[" then parse_array
      when '"' then parse_string
      when "t" then expect("true");  true
      when "f" then expect("false"); false
      when "n" then expect("null");  nil
      else parse_number
      end
    end

    def parse_object
      @i += 1 # {
      obj = {}
      skip_ws
      if @s[@i] == "}" then @i += 1; return obj end
      loop do
        skip_ws
        key = parse_string
        skip_ws
        raise Error, "expected ':'" unless @s[@i] == ":"
        @i += 1
        obj[key] = parse_value
        skip_ws
        ch = @s[@i]; @i += 1
        break if ch == "}"
        raise Error, "expected ',' or '}'" unless ch == ","
      end
      obj
    end

    def parse_array
      @i += 1 # [
      arr = []
      skip_ws
      if @s[@i] == "]" then @i += 1; return arr end
      loop do
        arr << parse_value
        skip_ws
        ch = @s[@i]; @i += 1
        break if ch == "]"
        raise Error, "expected ',' or ']'" unless ch == ","
      end
      arr
    end

    def parse_string
      raise Error, "expected string" unless @s[@i] == '"'
      @i += 1
      out = +""
      while (c = @s[@i])
        @i += 1
        case c
        when '"' then return out
        when "\\"
          e = @s[@i]; @i += 1
          out << case e
                 when '"' then '"'
                 when "\\" then "\\"
                 when "/" then "/"
                 when "n" then "\n"
                 when "t" then "\t"
                 when "r" then "\r"
                 when "b" then "\b"
                 when "f" then "\f"
                 else e
                 end
        else out << c
        end
      end
      raise Error, "unterminated string"
    end

    def parse_number
      start = @i
      @i += 1 while @s[@i] && "+-0123456789.eE".include?(@s[@i])
      tok = @s[start...@i]
      raise Error, "bad number at #{start}" if tok.empty?
      tok.include?(".") || tok.include?("e") || tok.include?("E") ? tok.to_f : tok.to_i
    end

    def expect(word)
      raise Error, "expected #{word}" unless @s[@i, word.length] == word
      @i += word.length
    end

    def skip_ws
      @i += 1 while @s[@i] && " \t\n\r".include?(@s[@i])
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb` after the module body: `require "suppify/json_parser"`.
Run: `bundle exec ruby -Ilib -Itest test/test_json_parser.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/json_parser.rb test/test_json_parser.rb lib/suppify.rb
git commit -m "feat: hand-rolled subset-safe JSON parser"
```

---

## Task 3: SymbolMap

**Files:**
- Create: `lib/suppify/symbol_map.rb`
- Test: `test/test_symbol_map.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

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

  def test_kind
    assert_equal "toplevel", @map.kind_for("add")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_symbol_map.rb`
Expected: FAIL — cannot load `suppify/symbol_map`.

- [ ] **Step 3: Write minimal implementation**

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

    def kind_for(ruby_name)
      e = @by_ruby[ruby_name]
      e && e["kind"]
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/symbol_map"`.
Run: `bundle exec ruby -Ilib -Itest test/test_symbol_map.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/symbol_map.rb test/test_symbol_map.rb lib/suppify.rb
git commit -m "feat: SymbolMap (ruby name -> cname/kind)"
```

---

## Task 4: Visibility (prism backend)

**Files:**
- Create: `lib/suppify/visibility.rb`
- Test: `test/test_visibility.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_visibility.rb
require "test_helper"
require "suppify/visibility"

class TestVisibility < Test::Unit::TestCase
  def pub(src) = Suppify::Visibility.public_methods(src).sort

  def test_toplevel_defs_are_public
    assert_equal ["add", "greet"], pub("def add(a,b)=a+b\ndef greet(n)=\"hi\#{n}\"\n")
  end

  def test_private_keyword_marks_following_defs
    src = <<~RUBY
      def a; end
      private
      def b; end
    RUBY
    assert_equal ["a"], pub(src)
  end

  def test_private_def_marks_single
    src = <<~RUBY
      def a; end
      private def b; end
      def c; end
    RUBY
    assert_equal ["a", "c"], pub(src)
  end

  def test_private_symbol_marks_named
    src = <<~RUBY
      def a; end
      def b; end
      private :b
    RUBY
    assert_equal ["a"], pub(src)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_visibility.rb`
Expected: FAIL — cannot load `suppify/visibility`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/visibility.rb
require "prism"

module Suppify
  # Computes the set of public top-level method names from Ruby source via
  # prism's static AST. Handles: bare `private`/`public` (flips subsequent
  # defs), `private def foo`, and `private :foo` / `public :foo`.
  module Visibility
    module_function

    def public_methods(source)
      program = Prism.parse(source).value
      body = program.statements.body
      mode = :public          # current default visibility
      vis  = {}               # name(String) => :public/:private (explicit wins)
      order = []

      body.each do |node|
        case node
        when Prism::DefNode
          name = node.name.to_s
          order << name unless vis.key?(name) || order.include?(name)
          vis[name] ||= mode
        when Prism::CallNode
          handle_call(node, mode_setter: ->(m) { mode = m }, vis: vis, order: order)
        end
      end

      order.select { |n| (vis[n] || :public) == :public }
    end

    # @api private
    def handle_call(node, mode_setter:, vis:, order:)
      mname = node.name
      return unless mname == :private || mname == :public
      args = node.arguments&.arguments || []

      if args.empty?
        mode_setter.call(mname)                 # bare `private` / `public`
        return
      end

      args.each do |arg|
        case arg
        when Prism::DefNode                      # `private def foo`
          n = arg.name.to_s
          order << n unless order.include?(n)
          vis[n] = mname
        when Prism::SymbolNode                   # `private :foo`
          n = arg.unescaped
          order << n unless order.include?(n)
          vis[n] = mname
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/visibility"`.
Run: `bundle exec ruby -Ilib -Itest test/test_visibility.rb`
Expected: PASS (4 tests). If a prism node accessor name differs in the installed prism version, fix the accessor to match `bundle exec ruby -e 'require "prism"; pp Prism.parse("private def x; end").value'` and re-run.

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/visibility.rb test/test_visibility.rb lib/suppify.rb
git commit -m "feat: Visibility analyzer (prism) -> public top-level method set"
```

---

## Task 5: Signature + SignatureExtractor

**Files:**
- Create: `lib/suppify/signature.rb`
- Test: `test/test_signature.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_signature.rb
require "test_helper"
require "suppify/signature"

class TestSignature < Test::Unit::TestCase
  C = <<~C
    static mrb_int sp_add(mrb_int a, mrb_int b) {
      return a + b;
    }
    static const char *sp_greet(const char *name) {
      return name;
    }
    static void sp_noop(void) { }
  C

  def test_extract_scalar_two_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_add")
    assert_equal "mrb_int", sig.return_type
    assert_equal [["mrb_int", "a"], ["mrb_int", "b"]], sig.params
  end

  def test_extract_pointer_return_and_arg
    sig = Suppify::SignatureExtractor.extract(C, "sp_greet")
    assert_equal "const char *", sig.return_type
    assert_equal [["const char *", "name"]], sig.params
  end

  def test_extract_void_args
    sig = Suppify::SignatureExtractor.extract(C, "sp_noop")
    assert_equal "void", sig.return_type
    assert_equal [], sig.params
  end

  def test_missing_definition_raises
    assert_raise(Suppify::Error) { Suppify::SignatureExtractor.extract(C, "sp_absent") }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_signature.rb`
Expected: FAIL — cannot load `suppify/signature`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/signature.rb
module Suppify
  Signature = Struct.new(:return_type, :params) # params: [[c_type, name], ...]

  # Extracts a function's C signature from generated C text by its cname.
  # Generated definitions are regular: `[static ]<ret> <cname>(<params>) {`.
  module SignatureExtractor
    module_function

    def extract(c_source, cname)
      # Match the definition line: capture return type (everything before the
      # cname) and the parenthesized parameter list.
      re = /(?<ret>[A-Za-z_][\w \*]*?)\s*\b#{Regexp.escape(cname)}\s*\((?<params>[^)]*)\)\s*\{/
      m = c_source.match(re)
      raise Error, "definition not found for #{cname}" unless m
      ret = m[:ret].sub(/\Astatic\s+/, "").strip
      Signature.new(ret, parse_params(m[:params]))
    end

    def parse_params(text)
      text = text.strip
      return [] if text.empty? || text == "void"
      text.split(",").map do |p|
        p = p.strip
        # split trailing identifier (the param name) from its type
        md = p.match(/\A(?<type>.*?)(?<name>[A-Za-z_]\w*)\z/)
        type = md[:type].strip
        # re-attach pointer star to type if the name grabbed it (e.g. "char *x")
        [type, md[:name]]
      end
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/signature"`.
Run: `bundle exec ruby -Ilib -Itest test/test_signature.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/signature.rb test/test_signature.rb lib/suppify.rb
git commit -m "feat: SignatureExtractor (cname -> C return type + params)"
```

---

## Task 6: NeutralType

**Files:**
- Create: `lib/suppify/neutral_type.rb`
- Test: `test/test_neutral_type.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

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

  def test_const_char_ptr_passthrough
    assert_equal "const char *", map("const char *")
  end

  def test_bool_to_int
    assert_equal "int", map("bool")
    assert_equal "int", map("_Bool")
  end

  def test_void_passthrough
    assert_equal "void", map("void")
  end

  def test_non_neutral_raises
    assert_raise(Suppify::NonNeutralType) { map("sp_RbVal") }
    assert_raise(Suppify::NonNeutralType) { map("sp_Proc *") }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_neutral_type.rb`
Expected: FAIL — cannot load `suppify/neutral_type`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/neutral_type.rb
module Suppify
  # Maps spinel C types to neutral C types usable across a plain-C boundary.
  # Anything not in the table is non-neutral and raises.
  module NeutralType
    TABLE = {
      "mrb_int"       => "intptr_t",
      "double"        => "double",
      "const char *"  => "const char *",
      "char *"        => "char *",
      "bool"          => "int",
      "_Bool"         => "int",
      "void"          => "void",
    }.freeze

    module_function

    def map(c_type)
      key = c_type.strip.gsub(/\s+/, " ")
      TABLE[key] or raise NonNeutralType, "non-neutral C type: #{c_type.inspect}"
    end

    def neutral?(c_type)
      map(c_type)
      true
    rescue NonNeutralType
      false
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/neutral_type"`.
Run: `bundle exec ruby -Ilib -Itest test/test_neutral_type.rb`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/neutral_type.rb test/test_neutral_type.rb lib/suppify.rb
git commit -m "feat: NeutralType mapping (spinel C types -> neutral, error on others)"
```

---

## Task 7: Trampoline generator

**Files:**
- Create: `lib/suppify/trampoline.rb`
- Test: `test/test_trampoline.rb`
- Modify: `lib/suppify.rb`

An "export" is a Hash: `{ "public" => "add", "cname" => "sp_add", "sig" => Signature }`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_trampoline.rb
require "test_helper"
require "suppify/trampoline"
require "suppify/signature"

class TestTrampoline < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add",   "cname" => "sp_add",
        "sig" => Suppify::Signature.new("mrb_int", [["mrb_int","a"],["mrb_int","b"]]) },
      { "public" => "boom",  "cname" => "sp_boom",
        "sig" => Suppify::Signature.new("void", []) },
    ]
    @c = Suppify::Trampoline.render(@exports)
  end

  def test_emits_extern_trampoline_calling_static
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\)/, @c)
    assert_match(/return sp_add\(a, b\);/, @c)
  end

  def test_void_trampoline_has_no_return_value
    assert_match(/void boom\(void\)/, @c)
    assert_match(/sp_boom\(\);/, @c)
  end

  def test_includes_exception_barrier_and_error_api
    assert_match(/setjmp/, @c)
    assert_match(/sp_exc_arm/, @c)
    assert_match(/int suppi_error\(void\)/, @c)
    assert_match(/const char \*suppi_error_message\(void\)/, @c)
  end

  def test_includes_sp_lib_init
    assert_match(/void sp_lib_init\(void\)/, @c)
    assert_match(/sp__main\(1, av\);/, @c)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_trampoline.rb`
Expected: FAIL — cannot load `suppify/trampoline`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/trampoline.rb
require "suppify/neutral_type"

module Suppify
  # Renders the C block appended to the generated translation unit:
  # extern trampolines (with a per-call setjmp exception barrier), the error
  # query API, and sp_lib_init.
  module Trampoline
    module_function

    def render(exports)
      out = +"\n/* === suppify appended trampolines === */\n"
      out << "static int g_suppi_err = 0;\n"
      out << "static const char *g_suppi_msg = 0;\n\n"
      exports.each { |e| out << one(e) << "\n" }
      out << "int         suppi_error(void)         { return g_suppi_err; }\n"
      out << "const char *suppi_error_message(void) { return g_suppi_msg; }\n\n"
      out << lib_init
      out
    end

    def one(e)
      sig  = e["sig"]
      ret  = NeutralType.map(sig.return_type)
      ps   = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n}" }
      plist = ps.empty? ? "void" : ps.join(", ")
      args  = sig.params.map { |_, n| n }.join(", ")
      body = +"#{ret} #{e['public']}(#{plist}) {\n"
      body << "    jmp_buf jb;\n"
      if ret == "void"
        body << "    if (setjmp(jb)) { sp_exc_disarm(); g_suppi_err = 1; return; }\n"
        body << "    sp_exc_arm(jb);\n"
        body << "    #{e['cname']}(#{args});\n"
        body << "    sp_exc_disarm();\n"
      else
        body << "    if (setjmp(jb)) { sp_exc_disarm(); g_suppi_err = 1; return 0; }\n"
        body << "    sp_exc_arm(jb);\n"
        body << "    #{ret} r = #{e['cname']}(#{args});\n"
        body << "    sp_exc_disarm();\n"
        body << "    return r;\n"
      end
      body << "}\n"
      body
    end

    def lib_init
      <<~C
        void sp_lib_init(void) {
            static int done = 0; if (done) return; done = 1;
            char *av[] = { "lib", 0 };
            sp__main(1, av);
        }
      C
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/trampoline"`.
Run: `bundle exec ruby -Ilib -Itest test/test_trampoline.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/trampoline.rb test/test_trampoline.rb lib/suppify.rb
git commit -m "feat: trampoline generator (extern wrappers + exc barrier + sp_lib_init)"
```

---

## Task 8: MainRenamer

**Files:**
- Create: `lib/suppify/main_renamer.rb`
- Test: `test/test_main_renamer.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_main_renamer.rb
require "test_helper"
require "suppify/main_renamer"

class TestMainRenamer < Test::Unit::TestCase
  def test_renames_standard_main
    src = "int main(int argc, char **argv) {\n  return 0;\n}\n"
    out = Suppify::MainRenamer.rename(src)
    assert_match(/static int sp__main\(int argc, char \*\*argv\)/, out)
    assert_no_match(/\bint main\b/, out)
  end

  def test_tolerates_spacing_variants
    src = "int  main ( int argc , char** argv )\n{\nreturn 0;\n}\n"
    out = Suppify::MainRenamer.rename(src)
    assert_match(/static int sp__main\s*\(/, out)
  end

  def test_raises_when_no_main
    assert_raise(Suppify::Error) { Suppify::MainRenamer.rename("int foo(void){return 0;}") }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_main_renamer.rb`
Expected: FAIL — cannot load `suppify/main_renamer`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/main_renamer.rb
module Suppify
  # Renames the generated `int main(...)` entry to `static int sp__main(...)`
  # so sp_lib_init can drive it and the library carries no `main` symbol.
  module MainRenamer
    RE = /\bint\s+main\s*\(/

    module_function

    def rename(c_source)
      raise Error, "no `int main(` found" unless c_source.match?(RE)
      c_source.sub(RE, "static int sp__main(")
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/main_renamer"`.
Run: `bundle exec ruby -Ilib -Itest test/test_main_renamer.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/main_renamer.rb test/test_main_renamer.rb lib/suppify.rb
git commit -m "feat: MainRenamer (int main -> static int sp__main)"
```

---

## Task 9: Header generator

**Files:**
- Create: `lib/suppify/header.rb`
- Test: `test/test_header.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_header.rb
require "test_helper"
require "suppify/header"
require "suppify/signature"

class TestHeader < Test::Unit::TestCase
  def setup
    @exports = [
      { "public" => "add", "cname" => "sp_add",
        "sig" => Suppify::Signature.new("mrb_int", [["mrb_int","a"],["mrb_int","b"]]) },
    ]
    @h = Suppify::Header.render("mylib", @exports)
  end

  def test_include_guard
    assert_match(/#ifndef MYLIB_H/, @h)
    assert_match(/#define MYLIB_H/, @h)
    assert_match(/#endif/, @h)
  end

  def test_includes_stdint_for_intptr
    assert_match(/#include <stdint.h>/, @h)
  end

  def test_neutral_prototype_no_spinel_types
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @h)
    assert_no_match(/mrb_int/, @h)
  end

  def test_lifecycle_and_error_api
    assert_match(/void sp_lib_init\(void\);/, @h)
    assert_match(/int suppi_error\(void\);/, @h)
    assert_match(/const char \*suppi_error_message\(void\);/, @h)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_header.rb`
Expected: FAIL — cannot load `suppify/header`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/header.rb
require "suppify/neutral_type"

module Suppify
  module Header
    module_function

    def render(lib_name, exports)
      guard = "#{lib_name.upcase}_H"
      out = +"#ifndef #{guard}\n#define #{guard}\n\n#include <stdint.h>\n\n"
      out << "void sp_lib_init(void);\n"
      out << "int suppi_error(void);\n"
      out << "const char *suppi_error_message(void);\n\n"
      exports.each do |e|
        sig = e["sig"]
        ret = NeutralType.map(sig.return_type)
        ps  = sig.params.map { |t, n| "#{NeutralType.map(t)} #{n}" }
        plist = ps.empty? ? "void" : ps.join(", ")
        out << "#{ret} #{e['public']}(#{plist});\n"
      end
      out << "\n#endif\n"
      out
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/header"`.
Run: `bundle exec ruby -Ilib -Itest test/test_header.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/header.rb test/test_header.rb lib/suppify.rb
git commit -m "feat: neutral header generator"
```

---

## Task 10: Pipeline (in-memory transform)

**Files:**
- Create: `lib/suppify/pipeline.rb`
- Test: `test/test_pipeline.rb`
- Modify: `lib/suppify.rb`

Pipeline takes already-obtained inputs (no external processes) and returns the transformed C + header + export list. Inputs: `ruby_source`, `c_source`, `symbol_map`, `lib_name`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_pipeline.rb
require "test_helper"
require "suppify/pipeline"

class TestPipeline < Test::Unit::TestCase
  RUBY = <<~RUBY
    def add(a, b) = a + b
    private
    def helper(x) = x
  RUBY

  C = <<~C
    static mrb_int sp_add(mrb_int a, mrb_int b) { return a + b; }
    static mrb_int sp_helper(mrb_int x) { return x; }
    int main(int argc, char **argv) { return 0; }
  C

  SYMS = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"},' \
         '{"c":"sp_helper","ruby":"helper","kind":"toplevel"}]}'

  def setup
    @r = Suppify::Pipeline.new(ruby_source: RUBY, c_source: C,
                               symbols_json: SYMS, lib_name: "mylib").run
  end

  def test_exports_only_public_methods
    names = @r[:exports].map { |e| e["public"] }
    assert_equal ["add"], names
  end

  def test_c_output_has_trampoline_and_renamed_main
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\)/, @r[:c_source])
    assert_match(/static int sp__main\(/, @r[:c_source])
    assert_no_match(/\bint main\b/, @r[:c_source])
  end

  def test_private_method_not_exported_but_still_static_in_c
    assert_no_match(/intptr_t helper\(/, @r[:c_source])  # not a public trampoline
    assert_match(/static mrb_int sp_helper/, @r[:c_source]) # still present + hidden
  end

  def test_header_present
    assert_match(/intptr_t add\(intptr_t a, intptr_t b\);/, @r[:header])
  end

  def test_public_method_with_non_neutral_signature_raises
    bad_c = "static sp_RbVal sp_add(sp_RbVal a) { return a; }\nint main(int c,char**v){return 0;}\n"
    bad_syms = '{"symbols":[{"c":"sp_add","ruby":"add","kind":"toplevel"}]}'
    assert_raise(Suppify::NonNeutralType) do
      Suppify::Pipeline.new(ruby_source: "def add(a)=a", c_source: bad_c,
                            symbols_json: bad_syms, lib_name: "x").run
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_pipeline.rb`
Expected: FAIL — cannot load `suppify/pipeline`.

- [ ] **Step 3: Write minimal implementation**

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
      c = c + Trampoline.render(exports)
      header = Header.render(@lib_name, exports)
      { exports: exports, c_source: c, header: header }
    end

    def build_exports
      Visibility.public_methods(@ruby_source).map do |ruby_name|
        cname = @symbols.cname_for(ruby_name)
        next nil unless cname # public method spinel did not emit (e.g. unused) — skip
        sig = SignatureExtractor.extract(@c_source, cname)
        # Force neutral-type validation now so a non-neutral public method errors.
        NeutralType.map(sig.return_type)
        sig.params.each { |t, _| NeutralType.map(t) }
        { "public" => ruby_name, "cname" => cname, "sig" => sig }
      end.compact
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/pipeline"`.
Run: `bundle exec ruby -Ilib -Itest test/test_pipeline.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/pipeline.rb test/test_pipeline.rb lib/suppify.rb
git commit -m "feat: Pipeline (visibility+symbols+signatures -> transformed C + header)"
```

---

## Task 11: SpinelRunner (locate + invoke spinel, capture output)

**Files:**
- Create: `lib/suppify/spinel_runner.rb`
- Test: `test/test_spinel_runner.rb`
- Modify: `lib/suppify.rb`

The runner takes an injectable `runner` callable (`->(cmd) { [stdout, status] }`) so tests don't need spinel. Default runner uses backtick (subset-compatible) so the same code compiles under spinel in Plan 2.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_spinel_runner.rb
require "test_helper"
require "suppify/spinel_runner"

class TestSpinelRunner < Test::Unit::TestCase
  def test_builds_command_and_returns_paths
    captured = nil
    fake = ->(cmd) { captured = cmd; ["", 0] }
    r = Suppify::SpinelRunner.new(spinel_bin: "/opt/spinel", runner: fake)
    out = r.emit("/work/app.rb", "/tmp/app.c")
    assert_match(%r{/opt/spinel /work/app.rb -c -o /tmp/app.c --emit-symbol-map}, captured)
    assert_equal "/tmp/app.c", out[:c_path]
    assert_equal "/tmp/app.symbols.json", out[:symbols_path]
  end

  def test_nonzero_status_raises
    fake = ->(_cmd) { ["boom", 1] }
    r = Suppify::SpinelRunner.new(spinel_bin: "spinel", runner: fake)
    assert_raise(Suppify::Error) { r.emit("/work/app.rb", "/tmp/app.c") }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_spinel_runner.rb`
Expected: FAIL — cannot load `suppify/spinel_runner`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/spinel_runner.rb
module Suppify
  class SpinelRunner
    # runner: callable(cmd_string) -> [stdout_string, exit_status_int]
    def initialize(spinel_bin: ENV["SPINEL"] || "spinel", runner: method(:shell))
      @spinel_bin = spinel_bin
      @runner = runner
    end

    # spinel writes <basename>.symbols.json next to the -c output's basename.
    def emit(rb_path, c_path)
      symbols_path = c_path.sub(/\.c\z/, "") + ".symbols.json"
      cmd = "#{@spinel_bin} #{rb_path} -c -o #{c_path} --emit-symbol-map"
      out, status = @runner.call(cmd)
      raise Error, "spinel failed (#{status}): #{out}" unless status == 0
      { c_path: c_path, symbols_path: symbols_path }
    end

    # Default backtick runner (kept subset-compatible for Plan 2).
    def shell(cmd)
      out = `#{cmd} 2>&1`
      [out, $?.exitstatus]
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/spinel_runner"`.
Run: `bundle exec ruby -Ilib -Itest test/test_spinel_runner.rb`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/spinel_runner.rb test/test_spinel_runner.rb lib/suppify.rb
git commit -m "feat: SpinelRunner (invoke spinel -c --emit-symbol-map, capture status)"
```

---

## Task 12: Builder (cc + ar + bundle libspinel_rt.a)

**Files:**
- Create: `lib/suppify/builder.rb`
- Test: `test/test_builder.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_builder.rb
require "test_helper"
require "suppify/builder"

class TestBuilder < Test::Unit::TestCase
  def test_runs_cc_then_ar_and_copies_runtime
    cmds = []
    copies = []
    fake = ->(cmd) { cmds << cmd; ["", 0] }
    copy = ->(src, dst) { copies << [src, dst] }
    b = Suppify::Builder.new(spinel_lib: "/opt/spinel/lib", runner: fake, copier: copy)
    out = b.build(c_path: "/tmp/app.c", lib_name: "mylib", out_dir: "/out")

    assert_match(%r{cc -c /tmp/app.c -I/opt/spinel/lib -o /tmp/app.o}, cmds[0])
    assert_match(%r{ar rcs /out/libmylib.a /tmp/app.o}, cmds[1])
    assert_equal ["/opt/spinel/lib/libspinel_rt.a", "/out/libspinel_rt.a"], copies[0]
    assert_equal "/out/libmylib.a", out[:archive]
  end

  def test_cc_failure_raises
    fake = ->(_cmd) { ["err", 1] }
    b = Suppify::Builder.new(spinel_lib: "/l", runner: fake, copier: ->(_a,_b){})
    assert_raise(Suppify::Error) { b.build(c_path: "/tmp/a.c", lib_name: "x", out_dir: "/o") }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_builder.rb`
Expected: FAIL — cannot load `suppify/builder`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/builder.rb
require "fileutils"

module Suppify
  class Builder
    def initialize(spinel_lib: ENV["SPINEL_LIB"] || default_lib,
                   runner: method(:shell), copier: FileUtils.method(:cp))
      @spinel_lib = spinel_lib
      @runner = runner
      @copier = copier
    end

    def build(c_path:, lib_name:, out_dir:)
      o_path  = c_path.sub(/\.c\z/, ".o")
      archive = File.join(out_dir, "lib#{lib_name}.a")
      run! "cc -c #{c_path} -I#{@spinel_lib} -o #{o_path}"
      run! "ar rcs #{archive} #{o_path}"
      @copier.call(File.join(@spinel_lib, "libspinel_rt.a"),
                   File.join(out_dir, "libspinel_rt.a"))
      { archive: archive, runtime: File.join(out_dir, "libspinel_rt.a") }
    end

    def run!(cmd)
      out, status = @runner.call(cmd)
      raise Error, "command failed (#{status}): #{cmd}\n#{out}" unless status == 0
    end

    def shell(cmd)
      out = `#{cmd} 2>&1`
      [out, $?.exitstatus]
    end

    def default_lib
      ""
    end
  end
end
```

- [ ] **Step 4: Wire require and run tests**

Add to `lib/suppify.rb`: `require "suppify/builder"`.
Run: `bundle exec ruby -Ilib -Itest test/test_builder.rb`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/suppify/builder.rb test/test_builder.rb lib/suppify.rb
git commit -m "feat: Builder (cc -c + ar + bundle libspinel_rt.a)"
```

---

## Task 13: CLI

**Files:**
- Create: `lib/suppify/cli.rb`
- Create: `suppify.rb` (the spinel-compile entrypoint / dev runner)
- Test: `test/test_cli.rb`
- Modify: `lib/suppify.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_cli.rb
require "test_helper"
require "suppify/cli"

class TestCLI < Test::Unit::TestCase
  def test_parses_input_and_output
    opts = Suppify::CLI.parse(["app.rb", "-o", "mylib"])
    assert_equal "app.rb", opts[:input]
    assert_equal "mylib",  opts[:lib_name]
  end

  def test_defaults_lib_name_from_input
    opts = Suppify::CLI.parse(["foo/bar.rb"])
    assert_equal "bar", opts[:lib_name]
  end

  def test_missing_input_raises
    assert_raise(Suppify::Error) { Suppify::CLI.parse(["-o", "x"]) }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_cli.rb`
Expected: FAIL — cannot load `suppify/cli`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/suppify/cli.rb
require "suppify/spinel_runner"
require "suppify/builder"
require "suppify/pipeline"

module Suppify
  module CLI
    module_function

    # Minimal arg parsing (optparse-free so it compiles under spinel too).
    def parse(argv)
      input = nil
      lib_name = nil
      out_dir = "."
      i = 0
      while i < argv.length
        case argv[i]
        when "-o" then lib_name = argv[i + 1]; i += 2
        when "-d", "--out-dir" then out_dir = argv[i + 1]; i += 2
        else input = argv[i]; i += 1
        end
      end
      raise Error, "usage: suppify <app.rb> [-o name] [-d out_dir]" unless input
      lib_name ||= File.basename(input, ".rb")
      { input: input, lib_name: lib_name, out_dir: out_dir }
    end

    def run(argv, tmp_dir: ".suppify-tmp")
      opts = parse(argv)
      require "fileutils"
      FileUtils.mkdir_p(tmp_dir)
      c_path = File.join(tmp_dir, "#{opts[:lib_name]}.c")

      emitted = SpinelRunner.new.emit(opts[:input], c_path)
      result = Pipeline.new(
        ruby_source: File.read(opts[:input]),
        c_source: File.read(emitted[:c_path]),
        symbols_json: File.read(emitted[:symbols_path]),
        lib_name: opts[:lib_name],
      ).run

      File.write(emitted[:c_path], result[:c_source])
      File.write(File.join(opts[:out_dir], "#{opts[:lib_name]}.h"), result[:header])
      built = Builder.new.build(c_path: emitted[:c_path],
                                lib_name: opts[:lib_name], out_dir: opts[:out_dir])
      $stdout.puts "wrote #{built[:archive]} and #{opts[:lib_name]}.h " \
                   "(#{result[:exports].length} exports)"
      0
    end
  end
end
```

- [ ] **Step 4: Create the entrypoint**

```ruby
# suppify.rb  (compiled by spinel in Plan 2; runs under CRuby for dev)
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "suppify"
require "suppify/cli"
exit Suppify::CLI.run(ARGV)
```

- [ ] **Step 5: Wire require, run unit tests, and the full suite**

Add to `lib/suppify.rb`: `require "suppify/cli"`.
Run: `bundle exec ruby -Ilib -Itest test/test_cli.rb`
Expected: PASS (3 tests).
Run: `bundle exec rake test`
Expected: all tests pass (Tasks 2–13).

- [ ] **Step 6: Commit**

```bash
git add lib/suppify/cli.rb suppify.rb test/test_cli.rb lib/suppify.rb
git commit -m "feat: CLI (suppify app.rb -o name) wiring spinel + pipeline + builder"
```

---

## Task 14: Integration test (gated on real spinel)

**Files:**
- Create: `test/fixtures/add.rb`
- Create: `test/test_integration.rb`

This is the spec's Phase-1 gate: real spinel → suppify → cc/ar → run a C harness. Skipped automatically when spinel is not on PATH, so the unit suite stays hermetic.

- [ ] **Step 1: Write the fixture**

```ruby
# test/fixtures/add.rb
def add(a, b) = a + b
def boom = raise "x"
```

- [ ] **Step 2: Write the gated integration test**

```ruby
# test/test_integration.rb
require "test_helper"
require "suppify/cli"
require "fileutils"
require "tmpdir"

class TestIntegration < Test::Unit::TestCase
  def spinel_available?
    !`which spinel`.strip.empty?
  rescue StandardError
    false
  end

  def test_end_to_end_build_and_call
    omit("spinel not on PATH") unless spinel_available?

    Dir.mktmpdir do |dir|
      rb = File.join(dir, "add.rb")
      FileUtils.cp(File.expand_path("fixtures/add.rb", __dir__), rb)

      Dir.chdir(dir) do
        assert_equal 0, Suppify::CLI.run([rb, "-o", "addlib"])

        File.write("harness.c", <<~C)
          #include "addlib.h"
          #include <stdio.h>
          int main(void){
              sp_lib_init();
              printf("%ld\\n", (long)add(2, 3));
              boom();
              printf("%d\\n", suppi_error());
              return 0;
          }
        C
        spinel_lib = ENV["SPINEL_LIB"] || `dirname $(dirname $(which spinel))`.strip + "/lib"
        ok = system("cc harness.c -I. -I#{spinel_lib} -L. -laddlib -lspinel_rt -lm -o harness")
        assert ok, "harness failed to compile/link"
        out = `./harness`.strip.split("\n")
        assert_equal "5", out[0]
        assert_equal "1", out[1]
      end
    end
  end
end
```

- [ ] **Step 3: Run it**

Run: `bundle exec ruby -Ilib -Itest test/test_integration.rb`
Expected: If spinel is installed, PASS with the harness printing `5` then `1`. If not installed, the test is **omitted** (counts as skip, suite stays green). Record which outcome occurred.

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/add.rb test/test_integration.rb
git commit -m "test: gated end-to-end integration (real spinel -> .a -> harness)"
```

---

## Self-Review

**Spec coverage:**
- Zero-mod, stock flags only → Task 11 (`-c --emit-symbol-map`), no spinel edits anywhere. ✓
- Signature from generated C → Task 5. ✓
- Export = public visibility via prism → Task 4 + Task 10. ✓
- Neutral header, no spinel types → Task 6 + Task 9. ✓
- Trampolines + exception barrier (existing `sp_exc_arm`) + `sp_lib_init` → Task 7. ✓
- main rename → Task 8. ✓
- Self-contained output bundle (copy `libspinel_rt.a`) → Task 12. ✓
- CLI `app.rb -o name`, no `--export` → Task 13. ✓
- Ruby-layer unit tests via test-unit + bundler vendor/bundle → Tasks 1–13. ✓
- spinel-build E2E gate (`add`→5, `boom`→error) → Task 14. ✓
- Hand-rolled JSON (no JSON.parse) → Task 2. ✓
- Subprocess via backtick + `2>&1` → Tasks 11, 12. ✓

**Deferred to Plan 2 (out of this plan's scope, by design):**
- Making suppify itself compile under spinel (whole-program assembly of `lib/*.rb`, single-file concerns).
- **libprism FFI backend** for `Visibility` so the native binary determines visibility without the prism gem. ← needs a feasibility spike first (can a spinel-compiled binary call libprism's C API via spinel FFI?).
- CI version matrix + master canary + golden checks (§8).
- `spinel --version` soft-check + supported-versions data (§11).

**Type consistency:** `Signature.new(return_type, params)` with `params: [[c_type, name], ...]` is used identically in Tasks 5, 7, 9, 10. Export hash keys `"public"/"cname"/"sig"` consistent in Tasks 7, 9, 10. `NeutralType.map` raises `NonNeutralType` (Tasks 6, 10). ✓

**Placeholder scan:** none — every step has concrete code/commands.

---

## Plan 2 outline (to be written after the libprism spike)

1. **Spike:** prove a spinel-compiled Ruby program can call libprism's parse API via spinel FFI (or decide the fallback: a shallow subset-safe visibility scanner). Time-boxed; result decides Plan 2's visibility task.
2. Whole-program assembly: produce a single spinel-compilable entry (inline/concat `lib/suppify/*.rb`, or confirm spinel resolves local `require`).
3. `Visibility` libprism-FFI backend selected for the native build.
4. `spinel suppify.rb -o suppify` build task + run the resulting native binary through Task 14's harness.
5. CI: spinel version matrix + `@master` canary + golden signature/visibility checks; `spinel --version` soft-check.
