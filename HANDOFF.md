# HANDOFF — suppify Plan 1

状態: **進行中（Plan 1 の 14 タスク全て実装済み、Task 14 は実機 spinel 未実行のため omit のまま）**。
branch `feat/suppify-core` に 15 commit、working tree clean、**44 テスト中 43 green + 1 omission**（CRuby + prism gem 上。spinel が PATH に無いため `test/test_integration.rb` が自動 omit）。
次にやること: spinel をインストールできる環境を用意し `bundle exec ruby -Ilib -Itest test/test_integration.rb` を実行 → PASS すれば Plan 1 完了 → `feat/suppify-core` を main へマージ。

## このリポジトリは何か

`suppify` = spinel でコンパイルした Ruby ファイルを、どこからでも呼べる**中立 C ライブラリ**（`.a` + ヘッダ）へ変換する外部ツール。spinel 本体は一切改変しない（stock フラグのみ）。正本ドキュメント:

- 設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`
- 実装計画: `docs/superpowers/plans/2026-06-21-suppify-core.md`（Plan 1、TDD 14 タスク）

## できていること（当セッションの tool 実行で検証済み）

`lib/suppify/` に 12 モジュール、`test/` に各ユニットテスト + gated integration test。`bundle exec rake test` → **44 tests / 72 assertions / 0 failures / 1 omission**（omission = spinel 不在での Task 14）。

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
| `spinel_runner.rb` | spinel 呼び出し（injectable runner でテスト可能） |
| `builder.rb` | `cc -c` + `ar` + `libspinel_rt.a` 同梱（injectable） |
| `cli.rb` + 直下 `suppify.rb` | `suppify app.rb -o name` の口と dev エントリ |

## まだ実証できていないこと（重要・正直に）

- **実機 spinel での E2E は未実行**。`test/fixtures/add.rb` と `test/test_integration.rb`（Task 14 の実体）はこのセッションで作成・commit 済みだが、この環境にも spinel が PATH に無いため実行できず自動 omit のまま。**「spinel 出力 → suppify → cc/ar → C ハーネスから呼べる」ことの経験的証明は未達**。証明済みなのは Ruby 変換層のロジックのみ。
- spinel の入手元（clone URL・配布方法）は本 repo のどのドキュメントにも記載が無い。次回再開時は user に確認が必要。
- Plan 2（未着手）: suppify 自身を spinel で 1 バイナリ化する自己ホスティング。最大の未検証点は「spinel-compiled バイナリが libprism を FFI で叩けるか」。これは Plan 2 冒頭の spike で判定する。Plan 1 はこれに依存しない。

## 再開手順

1. spinel の入手元を user に確認し、インストールして PATH に通す（`SPINEL_LIB` も `libspinel_rt.a` / `sp_runtime.h` のあるディレクトリに設定可）。
2. `cd suppify && bundle install`（gem は `vendor/bundle` に入る）。
3. `bundle exec ruby -Ilib -Itest test/test_integration.rb` で Task 14 を実行。期待: ハーネスが `5`（`add(2,3)`）と `1`（`boom` 例外で `suppi_error()==1`）を出力。
4. PASS を確認したら HANDOFF を更新。Plan 1 完了。`feat/suppify-core` を main へマージ（push は user 承認後）。

## 実装中に見つけた計画のバグ（修正済み）

`044d208 fix(trampoline)`: Plan の Task 7 テストが `return sp_call(args);`（成功パスで `sp_exc_disarm()` を飛ばす形）を要求していた。これは setjmp バリアを armed のまま return し、ローカル `jmp_buf` が dead frame になる **correctness バグ**。テスト側を正し、impl を spec の正しい順序（arm → call → disarm → return r）へ戻した。Plan doc の Task 7 はこの修正を反映していない（次回 Plan を正本として扱う際は修正版コードを参照）。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel への依存は外部ツール参照のみ（submodule/vendor 禁止）。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり。
