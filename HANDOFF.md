# HANDOFF — suppify

状態: **進行中（branch `feat/cross-compile`）。cruby / picoruby ターゲットエミッタを実装、両方とも実機 E2E で実証済み**。
worktree `.claude/worktrees/suppify-cross-compile`、working tree clean。**89 テスト**：spinel + picoruby ローカルチェックアウトが揃う環境で全 89 green（omission 0）。前提が無い環境では gated 統合テスト 5 本が自動 omit され、それでも green。
次にやること: `feat/cross-compile` を main へ統合する方針を user と確認（push/PR は承認必須）。

**注記**: main には Plan 1（コア: spinel→中立 C `.a`+ヘッダ、CRuby ネイティブ拡張から呼べることまで実証）がマージ済み。本 branch はその上に「ターゲットエミッタ層」を足したもの。

## このリポジトリは何か

`suppify` = spinel でコンパイルした Ruby を、どこからでも呼べる中立 C ライブラリへ変換する外部ツール。spinel 本体は無改変。正本ドキュメント:

- 設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`（§13 にターゲットエミッタ層を追記済み）
- README.md（利用者向け。`--target` と各ターゲットの使い方）

## この branch で足したもの（当セッションの tool 実行で検証済み）

**発想**: suppify 自身がクロスコンパイルするのをやめ、「どのツールチェーンでもビルドできるソース一式＋ビルド指示書」を吐く。コンパイルは consumer のビルドが自分の正しいフラグ（`-mlongcalls`・`MRB_NO_BOXING` 等）で行う。ゆえに ABI 一致が構造的に保証され、新ターゲットは「そのビルドが対応する arch」に自動追従する。

3層構造:
- **コア（既存）**: Ruby + `.rbs` → 中立 C（`.c` + ヘッダ + トランポリン）。
- **バインディング（新）**: `lib/suppify/binding/{cruby,mruby}.rb`。中立 C 関数をホスト言語のメソッドに包む（`rb_*` / `mrb_*` マーシャリング）。型分類は `NeutralType.kind`（:int/:float/:string/:bool/:void）。
- **エミッタ（新）**: `lib/suppify/emitter/{cruby_gem,picoruby_gem}.rb`。ビルド可能な gem 一式を組み立てる。ランタイムソースは `lib/suppify/runtime_sources.rb` が spinel の 25 本の `.c` ＋ヘッダを src にフラット同梱（quoted include が同一 dir で解決）。

CLI: `-t/--target c|cruby|picoruby`（既定 `c` = 従来の `.a`+ヘッダ）。`cruby`/`picoruby` は `SPINEL_LIB` 必須（ランタイムソース同梱のため）。

トランポリン改良（バインディングが要求した本物の修正）:
- 各呼び出しの入口で `g_suppi_err` を 0 リセット → `suppi_error()` は「直近の呼び出し」を反映。無いと「一度 raise すると以降ずっと raise」になる。
- 例外メッセージ捕捉: longjmp 着地時に `sp_exc_msg[sp_exc_top-1]`（同一 TU の static）を static バッファへコピー → `suppi_error_message()` が NULL でなく実メッセージ（`raise "x"` → `"x"`）を返す。

## 実機で実証したこと（重要）

`tmp/spinel`（main チェックアウトの実ビルドへの symlink、gitignore 済み）を使用。

- **CRuby ターゲット**（`test_cruby_target_integration`, gated on spinel）: `suppify -t cruby` → `mkmf` で拡張ビルド → `require` → `add/half/greet/even/truthy` 往復、`boom` が `RuntimeError: "x"` を送出、**boom の後の `add(10,20)=30`**（per-call リセット実証）。`gem build` でパッケージ化も確認。
- **PicoRuby ターゲット**（`test_picoruby_target_integration`, gated on spinel + `PICORUBY_ROOT`）: `suppify -t picoruby` → `conf.gem gemdir:` → 実 picoruby ホストビルド（master `de55b0a9`）が生成 C ＋ spinel ランタイムソースを `libmruby.a` にコンパイル → ビルドした `picoruby` バイナリがスクリプトから同メソッド群を実行。同じ出力を確認。
  - picoruby は生成 gem_init.c で `mrb_<gem>_gem_final` も参照するため、バインディングが空の gem_final も出す（実 picoruby ビルドで検出・修正済み）。

## まだ手を付けていないこと

- **on-device / on-iPhone の実行検証**: 現状の実証はホストビルドまで（M3 mac 上の CRuby 拡張と picoruby ホストバイナリ）。ESP32 実機・iOS 実機での実行は未。ただし picoruby のクロスビルド機構（xtensa/iOS build_config）に gem を渡す口は同じなので、機構としては通るはず。R2P2-ESP32 / R2P2-iOS への実配線は次の実弾。
- **非スカラー境界**（Array/Hash/インスタンスを持つクラス）。現状 export できるのはスカラー（Integer/Float/String/Symbol/bool/void）を扱うトップレベルメソッドのみ。stackchan の `FrameParser`（stateful）等は opaque handle 設計が要る後続。
- **Swift/他言語エミッタ**: 継ぎ目（`binding/` + `emitter/`）は用意済み。Swift は中立ヘッダを module map で直接 import できるため薄い。未実装。
- 複数 suppify ライブラリ同居のシンボル衝突（`sp_lib_init` 等の共通名）。1 バイナリ 1 ライブラリ制約は据え置き。

## 再開手順

1. `export PATH="$(pwd)/tmp/spinel/bin:$PATH"; export SPINEL_LIB="$(pwd)/tmp/spinel/lib"`（`tmp/spinel` は symlink 済み。無ければ main チェックアウトで `tmp/spinel` を再ビルド）。
2. `bundle exec rake test` — spinel 有りで unit + gated（picoruby は `PICORUBY_ROOT` があれば実行、約 30s のホストビルドを含む）。
3. main への統合方針を user 確認。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel 依存は外部ツール参照のみ（`tmp/spinel` は ephemeral、非 commit）。picoruby/picoruby には絶対 commit しない（ビルドは `MRUBY_BUILD_DIR` を temp に逃がす）。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり。
