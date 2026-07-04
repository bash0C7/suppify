# HANDOFF — suppify

状態: **進行中（branch `feat/cross-compile`）。cruby / picoruby ターゲットエミッタを実装し、両方とも実機 E2E で実証済み。fresh-context 敵対的検証で見つかった文字列引数のメモリ安全性バグを修正済み。さらに、複数 suppify ライブラリの同居（symbol namespacing）・文字列戻り値の embedded-NUL 切り詰め・GC-root リーク・gem メタデータを一通り仕上げ、その仕上げ自体も fresh-context 敵対的検証にかけて3件の実バグを発見・修正済み**。
worktree `.claude/worktrees/suppify-cross-compile`、working tree clean。**116 テスト**：spinel + picoruby ローカルチェックアウトが揃う環境で全 116 green（omission 0、警告 0）。前提が無い環境では gated 統合テストが自動 omit され、それでも green。
次にやること: `feat/cross-compile` を main へ統合する方針を user と確認（push/PR は承認必須）。

## symbol namespacing 実装の敵対的検証で発見・修正した3件

1. **gemspec/mrbgem.rake の `--gem-version` 未エスケープ**（重大）: `license` は `.inspect` で正しくエスケープされていたが `version` は生の文字列補間だった。`"` を含む version 値でエスケープを脱出でき、`gem build`/`bundle`/picoruby の Rake ビルドが読み込んだ瞬間に任意 Ruby が実行されうる。実際に `system("touch ...")` を注入して再現確認 → `.inspect` に統一して修正。
2. **`lib_name` が C 識別子として未検証**（重大）: `SymbolPrefix.prelude` は `#define sym lib_name_sym` を生成するが、`lib_name` にハイフン等が入ると（`-o my-lib` は自然な命名）プリプロセッサのトークン化が壊れ、リネーム済み全シンボルが不正な式になる。実際に `-o my-lib` で20件以上のコンパイルエラーを再現 → CLI で C 識別子検証を追加（不正なら明確なエラー）。あわせて spinel 自身のランタイムソースのベース名（`sp_gc` 等）との衝突も拒否するようにした。
3. **CLI 引数パーサがフラグの値を無検証で消費**（中）: `--license -o mylib` のような取り違えで `-o` の値が silently 消える・エラーメッセージが的外れになる問題を確認 → 値が欠落しているか別のフラグに見える場合は明確なエラーを出すよう修正。

**ドーマントな既知の制限として文書化のみ（修正せず）**: `SymbolPrefix.discover_runtime_symbols` は `SP_THREADS` 無しでランタイムをコンパイルするため、spinel のスレッド版ランタイムにのみ存在するグローバル（`sp_heap_lock`/`sp_sched_sleep`/`sp_sched_wait_io`）は未リネームのまま残る。現状 suppify のどのターゲットも `SP_THREADS` を有効化しないため今は無害。

**注記**: main には Plan 1（コア: spinel→中立 C `.a`+ヘッダ、CRuby ネイティブ拡張から呼べることまで実証）がマージ済み。本 branch はその上に「ターゲットエミッタ層」＋「複数ライブラリ同居対応」を足したもの。

## このリポジトリは何か

`suppify` = spinel でコンパイルした Ruby を、どこからでも呼べる中立 C ライブラリへ変換する外部ツール。spinel 本体は無改変。正本ドキュメント:

- 設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`（§13 にターゲットエミッタ層を追記済み）
- README.md（利用者向け。`--target`・`--gem-version`・`--license` と各ターゲットの使い方）

## 3層構造 + ターゲットエミッタ

**発想**: suppify 自身がクロスコンパイルするのをやめ、「どのツールチェーンでもビルドできるソース一式＋ビルド指示書」を吐く。コンパイルは consumer のビルドが自分の正しいフラグ（`-mlongcalls`・`MRB_NO_BOXING` 等）で行う。ゆえに ABI 一致が構造的に保証され、新ターゲットは「そのビルドが対応する arch」に自動追従する。

- **コア**: Ruby + `.rbs` → 中立 C（`.c` + ヘッダ + トランポリン）。
- **バインディング**: `lib/suppify/binding/{cruby,mruby}.rb`。中立 C 関数をホスト言語のメソッドに包む（`rb_*` / `mrb_*` マーシャリング）。型分類は `NeutralType.kind`（:int/:float/:string/:bool/:void）。
- **エミッタ**: `lib/suppify/emitter/{cruby_gem,picoruby_gem}.rb`。ビルド可能な gem 一式を組み立てる。ランタイムソースは `lib/suppify/runtime_sources.rb` が spinel の 25 本の `.c` ＋ヘッダを src にフラット同梱（quoted include が同一 dir で解決）。

CLI: `-t/--target c|cruby|picoruby`（既定 `c`）、`--gem-version <ver>`（既定 `0.1.0`）、`--license <name>`（既定未設定。picoruby は build 上必須なので内部で `MIT` にフォールバック）。`cruby`/`picoruby` は `SPINEL_LIB` 必須（ランタイムソース同梱のため）。

## 複数 suppify ライブラリの同居（本セッションの主題）

以前は「1バイナリにつき suppify ライブラリは1つまで」という制約があった。spinel のランタイム（`sp_gc_alloc`/`sp_str_heap` など約600個のグローバルシンボル。25本の `lib/*.c` に加え、`sp_runtime.h` 自体にも約200個が非 static 関数本体として直接埋め込まれている）と suppify 自身の固定名シンボル（`sp_lib_init`/`suppi_error`/`suppi_error_message`）が、spinel の「1バイナリ1プログラム」前提のプロセス全体グローバルだったため。

**修正**: 新モジュール `lib/suppify/symbol_prefix.rb`。
1. `discover_runtime_symbols(spinel_lib)` — フラット化したランタイムソース一式 + 「生成プログラム TU が普通提供する3つの static stub 関数 + `#include "sp_runtime.h"`」を模したスタブを実際にコンパイルし、`nm` で外部リンケージのシンボルを全列挙（Mach-O の先頭 `_` は剥がす）。`sp_ctx_swap`（spinel の Fiber コンテキストスイッチ）だけは除外——`sp_fiber.c` 内で `#define` した文字列をそのまま `__asm__` ブロックのシンボル名に使っており、プリプロセッサの文字列置換が届かないため。ステートレスでライブラリ間で内容が完全に同一なので、共有のままでも実害はない。
2. `prelude(lib_name, symbols)` — 発見した各シンボルを `#define sym lib_name_sym` する C ヘッダを生成。あわせて vendored runtime 由来の無害な警告（`-Wunused-function` 等）を `#pragma` で抑制（clang 固有のものは `#if defined(__clang__)` で保護し、ESP32 のような素の gcc クロスツールチェーンに未知 pragma 警告を出さない）。
3. このヘッダを `-include` で、そのライブラリのために compile する全 `.c` に強制インクルード:
   - **`c` target**（`Builder`）: 従来はビルド済み `libspinel_rt.a` をコピーするだけだったが、**ライブラリごとにランタイムを再コンパイル**し、生成 TU と合わせて **1つの自己完結 `lib<name>.a`** にマージ（`libspinel_rt.a` を別途リンクする必要が無くなった）。
   - **`cruby`/`picoruby`**: prelude をバンドルディレクトリに書き出し、`extconf.rb`/`mrbgem.rake` に `-include` で配線。

suppify 自身の3固定シンボル（`sp_lib_init`/`suppi_error`/`suppi_error_message`）は macro ではなく **Ruby の文字列補間で直接** `<lib_name>_init`/`<lib_name>_error`/`<lib_name>_error_message` に改名（`trampoline.rb`/`header.rb`/両 binding/`pipeline.rb`）。

**実機実証（複数ライブラリ同居）**:
- **CRuby**: `addlib`/`mullib` 相当の2つの gem を実ビルドし、同一 Ruby プロセスで両方 `require`。両方の関数が正しく動作し、エラー状態も独立していることを確認。
- **PicoRuby**: 同様に2つの mrbgem を実 picoruby ホストビルドに組み込み（`conf.gem gemdir:` を2回）、1つの `picoruby` バイナリの中で両方の関数を実行。エラー状態の独立性も確認。
- **`c` target の既知の制限**: 2つの `.a` を直接 `cc ... -laddlib -lmullib` でリンクすると、**`sp_ctx_swap` の重複シンボルで依然リンクエラーになる**（両ライブラリの生成 TU が GC のフィボナ根マーキング経由で無条件に自分の `sp_fiber.o` を要求するため）。CRuby（dlopen/RTLD_LOCAL による分離）・PicoRuby（実ビルドで確認済み、理由は完全には特定できていないが再現された事実として確認）では発生しない。`c` target で複数ライブラリを1バイナリに直接リンクしたい場合のみ残る制限として明記。

## 文字列引数のメモリ安全性バグ（発見・修正済み）

fresh-context 敵対的検証ワークフローが1件の確定バグを発見: `trampoline.rb` が文字列引数を spinel にホスト VM のバッファポインタのまま渡していた。spinel の文字列は `sp_str_hdr`（24byte ヘッダ）+ `ptr[-1]` のマーカーバイトを前提とするため、生ポインタを渡すと毎回 1byte の境界外読み取り（UB）、約 3/256 の確率でマーカーバイト誤認による巨大 over-read（クラッシュ/ヒープ漏洩）が起きる。ホスト（macOS arm64）ターゲットでも発生する、cross-compile 固有ではない一般バグだった。

修正（`lib/suppify/trampoline.rb`）:
1. 各 `:string` 種別の引数を `sp_str_dup_external(name)` で dup してから渡す（spinel 自身が argv/getenv に対して行うのと同じ扱い）。
2. **複数文字列引数の GC 窓**: dup した文字列は callee に渡るまでただの C 一時変数で、GC からは見えない。2つ目の dup が内部で GC を誘発すると、1つ目の（まだ unrooted な）dup 済み文字列が sweep されうる。実際に string heap のバイト数を意図的に閾値直前まで積んで実証（`SPINEL_GC_STRESS=1` で threshold=2048）。修正: 各 dup 済み文字列を named local に代入し、`SP_GC_ROOT`（spinel 自身のコード生成がローカル変数に使うのと同じマクロ）で直後に root する。
3. **GC-root カウントのリーク**: `SP_GC_ROOT` の cleanup attribute による自動 pop は、longjmp で自分の setjmp に戻る経路では発火しない（cleanup は通常の C スコープ終了時にしか動かない）。修正: 各トランポリン関数の入口で `sp_gc_nroots` をスナップショットし、例外捕捉パスで復元する。これにより、dup+root 済みの文字列引数呼び出し中に例外が起きても GC ルートカウントは正しく戻る（spinel 自身の未配線な `sp_exc_rootmark` 機構に依存しない、suppify 側だけで完結する対策）。
4. **文字列戻り値の embedded-NUL 切り詰め**: `rb_str_new_cstr`/`mrb_str_new_cstr` は strlen 依存で埋め込み NUL より後ろを切り捨てる。spinel 自身の `sp_str_byte_len` を `<lib_name>_str_len` として中立境界越しに公開し、両 binding で `rb_str_new`/`mrb_str_new`（明示的長さ）に切り替え。実 spinel で `"a\0b"` が bytesize 3 のまま往復することを確認済み。
5. 回帰テスト: `test/fixtures/add.rb` に `cat`（2引数文字列）・`nully`（embedded-NUL を含む文字列）を追加。`test_cruby_target_integration.rb`/`test_picoruby_target_integration.rb` の両方で実ビルド確認。

## 生成コードの警告 — ゼロ達成

`sp_lib_init` の `char *av[] = { "lib", 0 };` が strict なコンパイラで qualifier 破棄警告を出していた（suppify 自身のバグ）→ `(char *)` キャストで解消。vendored runtime 由来の警告（約330件あった `-Wunused-function` 等）は `SymbolPrefix.prelude` の `#pragma` で一括抑制。3ターゲットすべて（c/cruby/picoruby）で実ビルドの警告数がゼロであることを確認済み。

## gem/mrbgem メタデータ

- `--gem-version`（既定 `0.1.0`、旧 `0.0.0` プレースホルダから変更）、`--license`（既定未設定）を CLI に追加。
- CRuby gemspec は `license` 未指定時は行ごと省略（rubygems は必須ではないため、憶測でライセンスを書くより省略の方が安全）。
- PicoRuby の `MRuby::Gem::Specification#setup` は license/author が無いとビルド自体が失敗する（実ビルドで確認）ため、`picoruby_gem.rb` 側は既定 `MIT` を維持しつつ上書き可能にした。CLI 側では `opts[:license] || "MIT"` で明示的にフォールバック。

## 実機で実証したこと（重要）

`tmp/spinel`（main チェックアウトの実ビルドへの symlink、gitignore 済み）を使用。

- **CRuby ターゲット**（`test_cruby_target_integration`, gated on spinel）: `suppify -t cruby` → `mkmf` で拡張ビルド → `require` → `add/half/greet/even/truthy/cat/nully` 往復、`boom` が `RuntimeError: "x"` を送出、**boom の後の `add(10,20)=30`**（per-call リセット実証）。`gem build` でパッケージ化も確認。複数ライブラリ同居も確認（上記）。
- **PicoRuby ターゲット**（`test_picoruby_target_integration`, gated on spinel + `PICORUBY_ROOT`）: `suppify -t picoruby` → `conf.gem gemdir:` → 実 picoruby ホストビルドが生成 C ＋ spinel ランタイムソースを `libmruby.a` にコンパイル → ビルドした `picoruby` バイナリがスクリプトから同メソッド群を実行。複数 mrbgem 同居も確認（上記）。
  - picoruby は生成 gem_init.c で `mrb_<gem>_gem_final` も参照するため、バインディングが空の gem_final も出す。
  - `MRuby::Gem::Specification#setup` が license/author 必須であることも実ビルドで発覚・対応済み。

## まだ手を付けていないこと

- **on-device / on-iPhone の実行検証**: 現状の実証はホストビルドまで（M3 mac 上の CRuby 拡張と picoruby ホストバイナリ）。ESP32 実機・iOS 実機での実行は未。ただし picoruby のクロスビルド機構（xtensa/iOS build_config）に gem を渡す口は同じなので、機構としては通るはず。R2P2-ESP32 / R2P2-iOS への実配線は次の実弾。
- **非スカラー境界**（Array/Hash/インスタンスを持つクラス）。現状 export できるのはスカラー（Integer/Float/String/Symbol/bool/void）を扱うトップレベルメソッドのみ。stackchan の `FrameParser`（stateful）等は opaque handle 設計が要る後続。
- **Swift/他言語エミッタ**: 継ぎ目（`binding/` + `emitter/`）は用意済み。Swift は中立ヘッダを module map で直接 import できるため薄い。未実装。
- **`c` target の複数ライブラリ直接リンク**: 上記の `sp_ctx_swap` 重複シンボルが既知の制限として残る。

## 再開手順

1. `export PATH="$(pwd)/tmp/spinel/bin:$PATH"; export SPINEL_LIB="$(pwd)/tmp/spinel/lib"; export PICORUBY_ROOT=/Users/bash/dev/src/github.com/picoruby/picoruby`（`tmp/spinel` は symlink 済み。無ければ main チェックアウトで `tmp/spinel` を再ビルド）。
2. `bundle exec rake test` — spinel + picoruby 有りで unit + gated 全実行（picoruby 統合は実ホストビルドを含むため合計60秒程度）。
3. main への統合方針を user 確認。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel 依存は外部ツール参照のみ（`tmp/spinel` は ephemeral、非 commit）。picoruby/picoruby には絶対 commit しない（ビルドは `MRUBY_BUILD_DIR` を temp に逃がす）。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり。
