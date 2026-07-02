# HANDOFF — suppify Plan 1

状態: **blocked（実機 spinel E2E で設計前提を覆す非互換が判明。user の設計判断待ち）**。
branch `feat/suppify-core` に 16 commit、working tree clean、**45 テスト中 44 green + 1 omission**（CRuby 上）。
`https://github.com/matz/spinel` を ephemeral clone してビルドし実機で Task 14 を実行した結果、**spinel の whole-program dead-code elimination が「どこからも呼ばれないトップレベルメソッド」を可視性に関係なく除去する**ことが判明。suppify が exports しようとする public メソッドは定義上「プログラム内から呼ばれない」ため、この非互換は Plan 1 の中核設計と正面衝突する。回避策の選定は実装作業ではなく設計判断のため、次回セッションで user と合意してから実装を再開する。詳細は「実機 spinel で発覚した非互換（重大・要設計判断）」節。

## このリポジトリは何か

`suppify` = spinel でコンパイルした Ruby ファイルを、どこからでも呼べる**中立 C ライブラリ**（`.a` + ヘッダ）へ変換する外部ツール。spinel 本体は一切改変しない（stock フラグのみ）。正本ドキュメント:

- 設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`
- 実装計画: `docs/superpowers/plans/2026-06-21-suppify-core.md`（Plan 1、TDD 14 タスク）

## できていること（当セッションの tool 実行で検証済み）

`lib/suppify/` に 12 モジュール、`test/` に各ユニットテスト + gated integration test。`bundle exec rake test` → **45 tests / 74 assertions / 0 failures / 1 omission**（omission = spinel 不在での Task 14。spinel 在りでは下記の非互換により error になる）。

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

## 実機 spinel で発覚した非互換（重大・要設計判断）

spinel は `https://github.com/matz/spinel`（`master`、この検証時点で commit `9394f6e`）。`make deps && make` でビルド可能（依存: libc/libm のみ、ビルド時に prism gem を rubygems.org から取得）。`tmp/spinel/`（gitignore 済み、非 commit）に ephemeral clone してビルドし、これを使って初めて実機 Task 14 を走らせた。

### 検証手順（再現可能）
```
git clone --depth 1 https://github.com/matz/spinel.git tmp/spinel
cd tmp/spinel && make deps && make
export PATH="$(pwd)/tmp/spinel/bin:$PATH"
export SPINEL_LIB="$(pwd)/tmp/spinel/lib"
bundle exec ruby -Ilib -Itest test/test_integration.rb
```

### 見つけた問題（2 件、重大度が違う）

1. **（修正済み・commit `02f5132`）`-c` と `--emit-symbol-map` は排他モード**。実機 spinel の `src/main.c` は `emit_symbol_map` が立っていると `-c` の分岐に到達する前に early return する。`-o` を渡すとサフィックスも付かず、指定ファイルへ symbol-map JSON がそのまま書かれる（＝ suppify が期待する `.c` が消える）。設計書 §5 が根拠にしていた「PR #1345 で -c と --emit-symbol-map が組み合わせ可能になった」という前提はこの spinel には無い。`SpinelRunner#emit` を 2 回の個別呼び出し（`-c -o` → `--emit-symbol-map -o`）に修正、TDD で該当テストを書き直して commit 済み。

2. **（未修正・設計判断が必要）spinel の whole-program dead-code elimination がトップレベルメソッドの可視性を無視する**。`src/analyze.c: compute_reachable()` は「トップレベルスコープ（main 相当）」と `initialize`・一部の暗黙呼び出しメソッド名のみを root とし、そこから到達可能な呼び出しのみを BFS で生かす。**プログラム内のどこからも呼ばれないトップレベルメソッドは、public であっても生成 C から完全に消える**（symbol map には載るが、C の関数定義自体が無い）。加えて、消えなかったとしても **呼び出し箇所が無いメソッドは引数の型を推論する材料が無い**（`--rbs DIR` で型シグネチャだけ与えても reachability には影響しないことを実験で確認済み — 該当メソッドはやはり消える）。
   - 実証: `test/fixtures/add.rb`（`add` はどこからも未呼び出し、`boom` も同様）を実機コンパイルすると生成 C に `sp_add` / `sp_boom` の定義が一切現れない。`add` だけをトップレベルで呼び出す（`add(2, 3)`）と `add` は型付きで生き残るが、依然未呼び出しの `boom` は消えたまま。
   - **これは Plan 1 の核心と正面衝突する**: suppify は「public トップレベルメソッド＝外部から呼ぶための export」という設計だが、export 対象は定義上プログラム内から呼ばれない。spinel は非呼び出しメソッドを丸ごと消すため、現状のパイプライン（`spinel -c` → 生成 C から export を抜き出す）は**public メソッドがまさに exports すべき対象であるほど、その C 定義自体が存在しない**という構造的な矛盾を持つ。
   - 未検討の回避策（優先度・実現性は未評価、次回 user と合意してから着手）:
     a. suppify が spinel へ渡す直前に、public メソッドごとの合成呼び出し（ダミー引数）をソースへ注入し reachability を強制する。ただし引数の型をどう決めるか（RBS 必須にする？ヒューリスティック？）が新たな設計課題になる。
     b. spinel 側に「reachability root として扱うメソッド一覧」を渡す仕組みが無いか、upstream に issue を立てる（ただし CLAUDE.md により spinel への PR/fork は「将来 upstream 提案の余地は残すが依存しない」方針）。
     c. 設計を見直し、suppify が対象にできる入力形式を「明示的にエクスポートを宣言した Ruby」（例: 呼び出し箇所を伴う wrapper を利用者が書く）に限定する。
   - この判断は実装作業ではなく設計判断のため、着手前に user と合意する。

## まだ実証できていないこと（重要・正直に）

- 上記の非互換のため、`test/test_integration.rb` はこの環境の実機 spinel でもまだ **一度も PASS していない**（`assert_equal 0, Suppify::CLI.run(...)` の手前、シグネチャ抽出で `Suppify::Error: definition not found for sp_add` を投げて止まる）。「spinel 出力 → suppify → cc/ar → C ハーネスから呼べる」ことの経験的証明はまだ未達。
- Plan 2（未着手）: suppify 自身を spinel で 1 バイナリ化する自己ホスティング。最大の未検証点は「spinel-compiled バイナリが libprism を FFI で叩けるか」。これは Plan 2 冒頭の spike で判定する。Plan 1 はこれに依存しない。

## 再開手順

1. 上記「実機 spinel で発覚した非互換」の回避策 a/b/c（または他案）を user と合意する。
2. 合意した方針で `test/fixtures/add.rb`（必要なら差し替え）と pipeline を調整し、`export PATH="$(pwd)/tmp/spinel/bin:$PATH"; export SPINEL_LIB="$(pwd)/tmp/spinel/lib"; bundle exec ruby -Ilib -Itest test/test_integration.rb` を PASS させる。`tmp/spinel/` は既に ephemeral clone 済みでビルド済み（gitignore 対象、再ビルド不要）。
3. PASS を確認したら HANDOFF を更新。Plan 1 完了。`feat/suppify-core` を main へマージ（push は user 承認後）。

## 実装中に見つけた計画のバグ（修正済み）

`044d208 fix(trampoline)`: Plan の Task 7 テストが `return sp_call(args);`（成功パスで `sp_exc_disarm()` を飛ばす形）を要求していた。これは setjmp バリアを armed のまま return し、ローカル `jmp_buf` が dead frame になる **correctness バグ**。テスト側を正し、impl を spec の正しい順序（arm → call → disarm → return r）へ戻した。Plan doc の Task 7 はこの修正を反映していない（次回 Plan を正本として扱う際は修正版コードを参照）。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel への依存は外部ツール参照のみ（submodule/vendor 禁止）。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり。
