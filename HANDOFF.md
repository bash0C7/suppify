# HANDOFF — suppify Plan 1

状態: **完了（Plan 1 の 14 タスク全て実装済み、Task 14 が実機 spinel で PASS 済み）**。
branch `feat/suppify-core` に 18 commit、working tree clean、**51 テスト中 51 green + 0 omission**（実機 spinel を PATH に通した状態で `bundle exec rake test` を実行して確認。spinel が PATH に無い環境では Task 14 のみ自動 omit され、それでも green）。
次にやること: `feat/suppify-core` を main へマージする（push は user 承認後）。

## このリポジトリは何か

`suppify` = spinel でコンパイルした Ruby ファイルを、どこからでも呼べる**中立 C ライブラリ**（`.a` + ヘッダ）へ変換する外部ツール。spinel 本体は一切改変しない（stock フラグのみ）。正本ドキュメント:

- 設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`（実機検証で見つかった非互換と対処を §5.1・§6・付録に追記済み）
- 実装計画: `docs/superpowers/plans/2026-06-21-suppify-core.md`（Plan 1、TDD 14 タスク）

## できていること（当セッションの tool 実行で検証済み）

`lib/suppify/` に 14 モジュール、`test/` に各ユニットテスト + gated integration test。`bundle exec rake test` → **51 tests / 91 assertions / 0 failures / 0 omissions**（実機 spinel あり）。

| モジュール | 役割 |
|---|---|
| `json_parser.rb` | 自作の subset-safe JSON パーサ（`JSON.parse` 非依存） |
| `symbol_map.rb` | `--emit-symbol-map` JSON を ruby名↔cname にマップ |
| `visibility.rb` | prism で Ruby ソースを静的解析し public トップレベルメソッド集合を算出 |
| `signature.rb` | 生成 C から cname の戻り型・引数を抽出 |
| `neutral_type.rb` | spinel C 型 → 中立 C 型（`mrb_int`→`intptr_t` 等）、非中立は raise |
| `trampoline.rb` | extern トランポリン + setjmp 例外バリア + error API + `sp_lib_init` を生成 |
| `main_renamer.rb` | `int main(` → `static int sp__main(` |
| `header.rb` | 中立ヘッダ（spinel 型を漏らさない） |
| `pipeline.rb` | 上記をまとめた純メモリ変換（外部プロセス無し） |
| `spinel_runner.rb` | spinel 呼び出し（`-c` と `--emit-symbol-map` を別invocationで発行。injectable） |
| `rbs_seed.rb` | `.rbs` サイドカー（`class Object; def name: (T1,T2) -> R; end`）をパースし literal 引数へ変換 |
| `root_injector.rb` | public メソッドごとに `if false` で括ったダミー呼び出しを注入（spinel の DCE 対策、§5.1） |
| `builder.rb` | `cc -c` + `ar` + `libspinel_rt.a` 同梱（injectable） |
| `cli.rb` + 直下 `suppify.rb` | `suppify app.rb -o name` の口と dev エントリ。public メソッドがあれば `.rbs` サイドカー必須 |

## 実機 spinel で見つけて解決した非互換（このセッションの主な作業）

spinel は `https://github.com/matz/spinel`（`master`、検証時点で commit `9394f6e`）。`make deps && make` でビルド可能。`tmp/spinel/`（gitignore 済み、非 commit）に ephemeral clone してビルド済み——再ビルド不要、次回は `export PATH="$(pwd)/tmp/spinel/bin:$PATH"; export SPINEL_LIB="$(pwd)/tmp/spinel/lib"` するだけで使える。

見つかった非互換は 2 件、いずれも修正済み：

1. **`-c` と `--emit-symbol-map` は排他モード**（`SpinelRunner` を 2 回の個別 invocation に変更。commit `02f5132`）。
2. **spinel の whole-program DCE がトップレベルメソッドの可視性を無視する** — プログラム内から一度も呼ばれないメソッドは public でも生成 C から消える。suppify の export 対象（＝定義上プログラム内から呼ばれない public メソッド）と正面衝突していた。対処: `.rbs` サイドカーで型を宣言させ、`RootInjector` が `if false` で括ったダミー呼び出しを注入して reachability を強制する（spinel の到達可能性判定は構文的な呼び出しノードの有無だけを見て分岐の実行可能性を見ないため有効）。`if false` で括る理由は、`sp_lib_init()` が renamed main を**ロード時に 1 回実際に実行する**ため、括らないとダミー呼び出しの副作用（`boom` の raise 等）がトランポリンの例外バリア外で発火し実機で実際にクラッシュした（`f69b4c7` で修正）。

詳細・再現手順は `docs/superpowers/specs/2026-06-21-suppify-design.md` §5.1 と付録の訂正節を参照。

### 利用者への影響（新しい制約）

public トップレベルメソッドを 1 つでも持つ `app.rb` を `suppify` する場合、**同ディレクトリに `<basename>.rbs` サイドカーが必須**（例: `add.rb` → `add.rbs`）。書式:

```
class Object
  def add: (Integer, Integer) -> Integer
  def boom: () -> void
end
```

対応型（`RbsSeed::LITERALS`）: `Integer` / `Float` / `String` / `Symbol` / `bool` / `TrueClass` / `FalseClass` / `NilClass` / `nil`。Array/Hash/独自クラスは未対応（該当型を使うと `Suppify::Error` で明確に落ちる — 黙って外さない）。宣言漏れの public メソッドがあれば起動時にエラーで列挙される。

## まだ手を付けていないこと

- Plan 2（未着手）: suppify 自身を spinel で 1 バイナリ化する自己ホスティング。最大の未検証点は「spinel-compiled バイナリが libprism を FFI で叩けるか」。Plan 2 冒頭の spike で判定する。Plan 1 はこれに依存しない。
- `RbsSeed` の対応型は Integer/Float/String/Symbol/bool/nil のみ（spinel の RBS 語彙のうち Array/Hash/オブジェクト型は未実装）。実用上ほとんどのケースをカバーするが、将来これらの型を export したい場合は `RbsSeed::LITERALS` の拡張が必要。

## 再開手順（Plan 1 完了後）

1. `feat/suppify-core` を main へマージする方針を user と確認する（push/PR は user 承認必須）。
2. マージ後、Plan 2 に着手するなら `docs/superpowers/plans/2026-06-21-suppify-core.md` の「後続フェーズ」節と spike 計画を確認する。

## 実装中に見つけた計画のバグ（修正済み）

- `044d208 fix(trampoline)`: Plan の Task 7 テストが `return sp_call(args);`（成功パスで `sp_exc_disarm()` を飛ばす形）を要求していた。setjmp バリアを armed のまま return し、ローカル `jmp_buf` が dead frame になる **correctness バグ**。テスト側を正し、impl を spec の正しい順序（arm → call → disarm → return r）へ戻した。Plan doc の Task 7 はこの修正を反映していない。
- `02f5132` / `f69b4c7`: 上記「実機 spinel で見つけて解決した非互換」参照。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel への依存は外部ツール参照のみ（submodule/vendor 禁止、`tmp/spinel/` は gitignore 済みの ephemeral clone）。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり。
