# HANDOFF — suppify Plan 1

状態: **Plan 1 の実装タスクは完了、かつ user が指定した「使い物になる」基準3点も満たした**。
branch `feat/suppify-core` に 21 commit、working tree clean、**53 テスト中 53 green + 0 omission**（実機 spinel を PATH に通した状態で `bundle exec rake test` を実行して確認。spinel が PATH に無い環境ではゲート付き integration test 2本のみ自動 omit され、それでも green）。
次にやること: `feat/suppify-core` を main へマージする方針を user と確認する（push/PR は承認必須）。

**重要な注記（誤解の経緯）**: このセッションの前半で「Plan 1 完了＝main へマージ可能＝リリース水準に達した」と報告したが、これは誤り。README も無く、実証は Integer 型1メソッドのみ、CI も無い状態だった。user から指摘を受け、「使い物になる」の一般的な定義（README・複数型での実証・実際の consumer からの呼び出し実証）を明示してもらい、それを満たす作業を追加で行った。CI とバージョンマトリクスは user が明示的に「不要」と判断し、Swift/PicoRuby/ESP32 個別ターゲットの検証も「今の責務外」と明示された（Ruby ネイティブエクステンションからの呼び出しで C ABI としての一般性は示せるため）。**main マージ自体は「プロダクションで広く使える」ことの証明ではなく、Plan 1 スコープの開発をブランチから本線へ統合するという内部的な区切りに過ぎない**——この区別を再度明確にしておく。

## このリポジトリは何か

`suppify` = spinel でコンパイルした Ruby ファイルを、どこからでも呼べる**中立 C ライブラリ**（`.a` + ヘッダ）へ変換する外部ツール。spinel 本体は一切改変しない（stock フラグのみ）。正本ドキュメント:

- 設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`（実機検証で見つかった非互換と対処を §5.1・§6・付録に追記済み）
- 実装計画: `docs/superpowers/plans/2026-06-21-suppify-core.md`（Plan 1、TDD 14 タスク）
- **README.md**（このセッションで新規作成。利用者向けの唯一の入口——設計書は「なぜ」、README は「どう使うか」）

## できていること（当セッションの tool 実行で検証済み）

`lib/suppify/` に 14 モジュール、`test/` に各ユニットテスト + gated integration test 2本。`bundle exec rake test` → **53 tests / 107 assertions / 0 failures / 0 omissions**（実機 spinel あり）。

| モジュール | 役割 |
|---|---|
| `json_parser.rb` | 自作の subset-safe JSON パーサ（`JSON.parse` 非依存） |
| `symbol_map.rb` | `--emit-symbol-map` JSON を ruby名↔cname にマップ |
| `visibility.rb` | prism で Ruby ソースを静的解析し public トップレベルメソッド集合を算出 |
| `signature.rb` | 生成 C から cname の戻り型・引数を抽出 |
| `neutral_type.rb` | spinel C 型 → 中立 C 型（`mrb_int`→`intptr_t`、`mrb_float`→`double`、`mrb_bool`→`int` 等）、非中立は raise |
| `trampoline.rb` | extern トランポリン + setjmp 例外バリア + error API + `sp_lib_init` を生成 |
| `main_renamer.rb` | `int main(` → `static int sp__main(` |
| `header.rb` | 中立ヘッダ（spinel 型を漏らさない） |
| `pipeline.rb` | 上記をまとめた純メモリ変換（外部プロセス無し） |
| `spinel_runner.rb` | spinel 呼び出し（`-c` と `--emit-symbol-map` を別invocationで発行。injectable） |
| `rbs_seed.rb` | `.rbs` サイドカー（`class Object; def name: (T1,T2) -> R; end`）をパースし literal 引数へ変換 |
| `root_injector.rb` | public メソッドごとに `if false` で括ったダミー呼び出しを注入（spinel の DCE 対策、§5.1） |
| `builder.rb` | `cc -c` + `ar` + `libspinel_rt.a` 同梱（injectable） |
| `cli.rb` + 直下 `suppify.rb` | `suppify app.rb -o name` の口と dev エントリ。public メソッドがあれば `.rbs` サイドカー必須 |

## 実機 spinel で見つけて解決した非互換（前セッションからの持ち越し + 今回追加）

spinel は `https://github.com/matz/spinel`（`master`、検証時点で commit `9394f6e`）。`tmp/spinel/`（gitignore 済み、非 commit）に ephemeral clone してビルド済み——再ビルド不要、`export PATH="$(pwd)/tmp/spinel/bin:$PATH"; export SPINEL_LIB="$(pwd)/tmp/spinel/lib"` するだけで使える。

1. **`-c` と `--emit-symbol-map` は排他モード**（`SpinelRunner` を 2 回の個別 invocation に変更。commit `02f5132`）。
2. **spinel の whole-program DCE がトップレベルメソッドの可視性を無視する** — `.rbs` サイドカー + `RootInjector` の `if false` ダミー呼び出しで対処（commit `f69b4c7`）。詳細は設計書 §5.1。
3. **（今回発見・修正）`NeutralType` のテーブル漏れ**: 実機 spinel は Float を `mrb_float`、bool を `mrb_bool` として出力するが、旧テーブルには無く、Float/bool を返す public メソッドは `NonNeutralType` で必ず落ちていた（＝ Integer 以外事実上使えなかった）。`mrb_float→double` / `mrb_bool→int` を追加し、`add`(Integer)/`half`(Float)/`greet`(String)/`even`(bool)/`boom`(例外) を1フィクスチャで実機通過させて実証（commit `d71b165`）。

## 今回追加した「使い物になる」ための3点（user 指定の基準）

1. **README.md**（新規）: セットアップ・CLI 使用法・`.rbs` サイドカー要件と対応型一覧・エラー規約・1バイナリ1ライブラリ制約・具体例・テスト実行法を記載。
2. **型カバレッジの実証**: 上記「実機 spinel で見つけて解決した非互換」3番。Integer だけでなく Float/String/bool を実機で通した。Array/Hash/独自クラスは明示的に未対応（`Suppify::Error` で raise、黙って外さない）。
3. **Ruby ネイティブエクステンションからの呼び出し実証**（`test/test_ruby_ext_integration.rb`、commit `009aa2b`）: `mkmf` で実際に `.so`/`.bundle` をビルドし、`require` して `ExtSuppify.add` 等を Ruby から呼び出せることを確認。suppify 生成物が中立ヘッダのみ（spinel ヘッダ不要）で C ABI として消費可能なことの、C ハーネスとは独立した二つ目の証拠。Swift/PicoRuby/ESP32 個別の検証は今回のスコープ外（user 判断）。

CI・バージョンマトリクスは user 判断により**実装しない**（既存の手動 ephemeral clone 手順で十分、との判断）。

## まだ手を付けていないこと（範囲外と明示された／将来課題）

- Swift/PicoRuby/ESP32 での実ターゲット検証（user が「今の責務外」と明示）。
- CI（user が「不要」と明示）。
- Plan 2（未着手）: suppify 自身を spinel で 1 バイナリ化する自己ホスティング。最大の未検証点は「spinel-compiled バイナリが libprism を FFI で叩けるか」。Plan 2 冒頭の spike で判定する。Plan 1 はこれに依存しない。
- `RbsSeed`/`NeutralType` の対応型は Integer/Float/String/Symbol/bool/nil のみ（Array/Hash/オブジェクト型は未実装、使うと明確に raise）。

## 再開手順

1. `feat/suppify-core` を main へマージする方針を user と確認する（push/PR は user 承認必須）。念のため：これは「Plan 1 スコープの開発を本線に統合する」ことであり、「プロダクションで広く使える」という別の主張ではない。
2. マージ後、Plan 2 に着手するなら `docs/superpowers/plans/2026-06-21-suppify-core.md` の「後続フェーズ」節と spike 計画を確認する。
3. Array/Hash/オブジェクト型の export が必要になったら `RbsSeed::LITERALS` / `NeutralType::TABLE` の拡張から着手する。

## 実装中に見つけた計画のバグ（修正済み）

- `044d208 fix(trampoline)`: Plan の Task 7 テストが `return sp_call(args);`（成功パスで `sp_exc_disarm()` を飛ばす形）を要求していた。setjmp バリアを armed のまま return し、ローカル `jmp_buf` が dead frame になる **correctness バグ**。テスト側を正し、impl を spec の正しい順序（arm → call → disarm → return r）へ戻した。Plan doc の Task 7 はこの修正を反映していない。
- `02f5132` / `f69b4c7` / `d71b165`: 上記「実機 spinel で見つけて解決した非互換」参照。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel への依存は外部ツール参照のみ（submodule/vendor 禁止、`tmp/spinel/` は gitignore 済みの ephemeral clone）。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり。
