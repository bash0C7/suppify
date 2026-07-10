# HANDOFF — suppify

状態: **完了（suppify 側）**。`picoruby-ot` の otmeiwa AOT パイロット（実機で `NoMethodError`）を起点に発見した「`suppify -t picoruby` が mruby/c (mrubyc) VM 向けの binding を生成できていない」不具合を修正し、実物ヘッダに対するスタンドアロンコンパイル検証・`rake test` とも green。commit 済み（`16a1e00`）。次はここから picoruby-ot 側（spinel ローカルビルド〜再ベンダリング〜実機再検証〜ベンチマーク）に進む。

以前の HANDOFF 内容（cross-compile ブランチ / symbol namespacing 話）は既に main へ統合済みの過去作業。本ドキュメントで完全に置き換える。

## これは何のための作業か（発端）

`picoruby-ot`（別リポジトリ、`~/dev/src/github.com/bash0C7/picoruby-ot`）で、ESP32 実機上の PicoRuby アプリ `otmeiwa.rb` の一部の数値計算（距離EMA平滑化・加速度差分スケーリング）を spinel/suppify で AOT ネイティブコンパイルし、**実際に楽器として演奏できる速度改善**を実証するパイロットを進めていた。

完了基準（user 発言そのまま）:
> 完了基準はAOT版で実際に演奏できること。現行版と交互に入れ替えてスループット計測できることね。

この基準は**まだ一度も達成されていない**（後述、次のフェーズ）。

## 発見した根本原因（確認済み）

`suppify -t picoruby` が生成する `binding.c` は **full mruby の C API**（`mrb_state`/`mrb_value`/`mrb_define_method(mrb, mrb->kernel_module, ...)`）だけを使っていた。しかし PicoRuby は組み込み向けでは **mruby/c (mrubyc) VM** を実行時に使うのが標準（R2P2-ESP32 は `conf.picoruby(alloc_libc: false)` でビルド、これは `PICORB_VM_MRUBYC` + `DISABLE_MRUBY` を設定する）。

`mrb_state` という型は mrubyc モードでは実行時には無関係な、コンパイラ側だけの型として存在するため、suppify 生成の `binding.c` は `mrb_define_method` で「実際に動いている mrubyc VM とは無関係な mrb_state」に登録していた。コンパイル・リンクは通り ESP32 実機で起動もするが、Ruby から該当メソッドを呼んだ瞬間に `NoMethodError` になっていた。

picoruby-ot 側の問題ではなく **suppify 自身の `-t picoruby` ターゲットの欠陥**（mrubyc 対応が最初から無かった）。

### 別に見つけた、おそらく無関係な既存バグ（未確認・未対応・user未報告）

`picoruby-irq`（picoruby-ot の既存 gem）は `mrbc_irq_init(mrbc_vm *vm)` という関数を定義しているが、`mrb_picoruby_irq_gem_init(mrb_state *mrb)` の定義がどこにも見当たらない。同様の調査中、`picoruby-crc`（`picoruby-shell` の依存経由で xtensa-esp.rb の `shell` gembox から実際に ESP32 ビルドに含まれる）も同じパターン ―― `mrubyc/crc.c` は `mrbc_crc_init(mrbc_vm*)` のみを定義し `mrb_picoruby_crc_gem_init(mrb_state*)` を定義していないが、aggregate の `gem_init.c` はこの後者を無条件に呼ぶ形で生成されている。`build/esp32` 配下には `.o`/`.a` はあるが最終 `.elf` が存在せず、この picoruby チェックアウト単体でフルリンクまで到達した形跡が無い（実際の R2P2-ESP32 ファームウェアは ESP-IDF 経由の別ビルドパイプラインで生成されるため、ここでのリンク未実施は异常ではない）。**suppify の今回の修正とは無関係の別問題**なので今は追わない。次にこの領域（`picoruby-irq`/`picoruby-crc` がmrubyc ESP32 ビルドで実際にリンク・動作するか）を触るときのために記録だけしておく。

## 今回の修正（suppify 側、完了）

### やったこと

1. `lib/suppify/binding/mrubyc.rb`（新規）: mrubyc 向け binding 生成モジュール `Suppify::Binding::Mrubyc`。`Binding::Mruby`（既存）と同じ形の API（`render(header_name, init_func, exports)`）。
   - 各 wrapper 関数は `static void c_suppi_<name>(struct VM *vm, mrbc_value v[], int argc)` 形式。
   - `v[i].tt` を手動で型チェックして `mrbc_raise(vm, MRBC_CLASS(ArgumentError), ...)`（既存の手書き mrubyc gem `picoruby-irq/src/mrubyc/irq.c` と同じ書き方）。bool 引数は型チェックせず Ruby の truthy 判定のみ。
   - 戻り値は `SET_INT_RETURN`/`SET_FLOAT_RETURN`/`SET_BOOL_RETURN`/`SET_NIL_RETURN`、文字列は `mrbc_string_new(vm, r, <lib>_str_len(r))`（既存 mruby binding と同じ embedded-NUL 対策）。
   - gem 初期化関数は **`mrb_<lib_name>_gem_init(mrb_state *mrb)`**（aggregate gem 初期化テーブルが VM 種を問わずこのシグネチャで無条件に呼ぶため）。`mrb_state` は **`#define mrb_state void` をファイル冒頭でローカルに定義**（`#include <mruby.h>` はしない ―― 下記「中断していた検証で判明した追加の事実」参照）。関数内で `mrbc_define_method(0, 0, "<name>", c_suppi_<name>)` を呼ぶ（`0, 0` は vm/cls 省略で Object クラスに登録、`picoruby-mrubyc` 自身の `rrt0.c` と同じ convention）。
2. `test/test_binding_mrubyc.rb`（新規）: 上記の生成内容を検証する unit test。TDD で `mrb_state` ローカル定義のテストも追加。**全通過**（11 tests, 30 assertions）。
3. `lib/suppify/emitter/picoruby_gem.rb`（修正）: `binding.c` の生成を単一の `render_binding` メソッド経由にし、`#if defined(PICORB_VM_MRUBYC) ... #else ... #endif` という1ファイルにまとめた（consumer 側のビルドが `PICORB_VM_MRUBYC` を define しているかで自動的にどちらか一方だけがコンパイルされる）。
4. `test/test_emitter_picoruby_gem.rb`（修正）: mrubyc 分岐の生成内容（`#include <mrubyc.h>`・`mrbc_define_method`・`#else`）も assert するテストを追加。
5. `rake test`（suppify 全テスト）: **130 tests, 281 assertions, 0 failures**（spinel/picoruby 依存の統合テストは環境未整備で 11 件 omission、想定通り）。
6. commit 済み（ローカル、origin `bash0C7/suppify` につき自律 commit。push はしていない）。

### 中断していた検証で判明した追加の事実（今回で解決）

前回中断地点は「`Binding::Mrubyc.render` に `#include <mruby.h>` が無いため `mrb_state` が unknown type name になる」だった。素朴に `#include <mruby.h>` を足して実物ヘッダ（picoruby-ot が pin している `picoruby-mruby/lib/mruby/include/mruby.h`、`common()` メソッドが常にこのパスを include path に加えるため解決されるのはこちら＝本物の mruby.h）に対してスタンドアロンコンパイルしたところ、**新しいコンパイルエラーを発見した**: 本物の `mruby.h` と `mrubyc.h`（`picoruby-mrubyc/lib/mrubyc/src/value.h`）は両方とも `mrb_int`/`mrb_float`/`E_RUNTIME_ERROR` 等のレガシー互換 typedef・マクロを**非互換な型で**定義しており、同一 TU で両方 include すると `typedef redefinition with different types` 等のコンパイルエラーになる（`gcc -c` で実測・再現済み）。

対処: `#include <mruby.h>` はせず、**`#define mrb_state void` をファイル冒頭でローカルに定義**する方式に変更した。これは `picoruby-mrubyc/include/mruby.h` という薄いシムがまさに同じことをしている（`#define mrb_state void`）のと同じ発想で、外部ヘッダの include path 解決順（`common()` が本物の mruby.h を先に登録するため実際にはこのシムは通常勝てない）に依存せず、`gem_init` が `mrb_state` を never-dereference のポインタとしてしか使わない（`(void)mrb;`）という事実だけを使って自己完結させた。

再検証結果:
- mrubyc 側 (`PICORB_VM_MRUBYC` 定義): 実物 `picoruby-mrubyc`/`picoruby-mruby` ヘッダに対して `gcc -c` **エラー無く通過**。
- mruby 側 (`#else` 分岐、`Binding::Mruby` 既存): 実物 `picoruby-mruby` ヘッダに対して `gcc -c` **エラー無く通過**（regression 無し）。

再現コマンド（`/tmp` 配下は ephemeral、必要なら再生成）:
```bash
# 1. binding.c を実際の export 定義から生成（mrubyc 側）
ruby -Ilib -e '
require "suppify/binding/mrubyc"
require "suppify/signature"
exports = [
  {"public"=>"otmeiwa_distance_tick","cname"=>"sp_otmeiwa_distance_tick",
   "sig"=>Suppify::Signature.new("mrb_int",[["mrb_int","raw_distance"],["mrb_int","prev_distance"]])},
  {"public"=>"otmeiwa_accel_tick","cname"=>"sp_otmeiwa_accel_tick",
   "sig"=>Suppify::Signature.new("mrb_int",[["mrb_int","ax"],["mrb_int","ay"],["mrb_int","az"],["mrb_int","bx"],["mrb_int","by"],["mrb_int","bz"]])},
]
puts Suppify::Binding::Mrubyc.render("otmeiwa_aot", "mrb_picoruby_otmeiwa_aot_gem_init", exports)
' > /tmp/mrubyc_binding.c

# 2. 実物の picoruby-mrubyc ヘッダに対してスタンドアロンコンパイル
GEM=/Users/bash/dev/src/github.com/bash0C7/picoruby-ot/src_components/R2P2-ESP32/components/picoruby-esp32/picoruby/mrbgems/picoruby-otmeiwa_aot
OLD=/Users/bash/dev/src/github.com/bash0C7/picoruby-ot/components/R2P2-ESP32/components/picoruby-esp32/picoruby
gcc -c -std=gnu99 -Wall \
  -DPICORB_VM_MRUBYC -DDISABLE_MRUBY -DMRBC_ALLOC_LIBC -DMRBC_TICK_UNIT=10 -DMRBC_TIMESLICE_TICK_COUNT=1 \
  -DMRBC_USE_FLOAT=2 -DMAX_SYMBOLS_COUNT=1000 -DMAX_VM_COUNT=255 -DMAX_REGS_SIZE=255 -DMRBC_USE_MATH=1 \
  -I"$OLD/mrbgems/picoruby-mruby/lib/mruby/include" \
  -I"$OLD/mrbgems/picoruby-mrubyc/include" \
  -I"$OLD/mrbgems/picoruby-mrubyc/lib/mrubyc/src" \
  -I"$OLD/mrbgems/picoruby-mrubyc/lib/mrubyc/hal/posix" \
  -I"$GEM/include" \
  -o /tmp/mrubyc_binding.o /tmp/mrubyc_binding.c
```

## その先（次にやること — picoruby-ot 側）

1. 実際に spinel をローカルビルドし、`suppify -t picoruby` で otmeiwa_core.rb から `picoruby-otmeiwa_aot` gem を再生成（既存の `native/otmeiwa_core/README.md`／`rake native:otmeiwa_aot` タスクが picoruby-ot 側にある）。
2. 再生成した gem を picoruby-ot の `src_components/.../mrbgems/picoruby-otmeiwa_aot/` に再ベンダリング。**このとき、Xtensa/ESP32 ポータビリティ対応で入れた4パッチ（`mrbgem.rake`/`sp_fiber_ctx.h`/`sp_io.c`/`sp_runtime.h`、picoruby-ot commit `6ce9141` で既にコミット済み）を再度当て直す必要がある**（gem 再生成で上書きされるため）。
3. ESP32 向けにビルド（`CFLAGS="-Wno-error=implicit-function-declaration"` が必要、newer clang の `-Wimplicit-function-declaration` エラー化対策。picoruby-ot 側の別問題、suppify とは無関係）。
4. 実機に転送し、`otmeiwa_aot.rb` が `NoMethodError` を出さず最後まで実行できることを確認。
5. **まだ一度も実施していない、本来の完了基準**: `otmeiwa.rb`（現行/interpreted 版）と `otmeiwa_aot.rb`（AOT 版）を実機で交互に入れ替え、`/dev --debug` の fps 計測ツールでスループットを比較する。

## picoruby-ot 側の現在の状態（このリポジトリではないが、一連の作業の一部）

- リポジトリ: `~/dev/src/github.com/bash0C7/picoruby-ot`、branch `joyful_meiwa_2026`、working tree clean（HEAD `6ce9141`）。
- 実装済み・レビュー済み: `native/otmeiwa_core/`（TDD済みのプレーン Ruby 実装 + host validation）、`otmeiwa_aot.rb`（`otmeiwa.rb` は一切未変更）、vendoring、rake タスク、dev tooling docs。
- Xtensa/ESP32 クロスコンパイル自体は実証済み（4パッチ、上記2参照）。フルリンク（`.elf` 生成）まではこのチェックアウト単体では未実施（ESP-IDF 経由のビルドパイプラインで別途行う想定）。
- 実機で `NoMethodError`（本 HANDOFF の主題、suppify 側修正済み）。ベンチマークは未達成。

## このリポジトリ（suppify）は何か

`suppify` = spinel でコンパイルした Ruby を、どこからでも呼べる中立 C ライブラリ／mrbgem へ変換する外部ツール。spinel 本体は無改変。正本ドキュメント:

- 設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`
- README.md（利用者向け。`--target`・`--gem-version`・`--license` と各ターゲットの使い方）

3層構造: コア（Ruby+`.rbs` → 中立C）／バインディング（`lib/suppify/binding/{cruby,mruby,mrubyc}.rb`）／エミッタ（`lib/suppify/emitter/{cruby_gem,picoruby_gem}.rb`）。CLI: `-t/--target c|cruby|picoruby`。`cruby`/`picoruby` は `SPINEL_LIB` 必須。

## 再開手順

1. picoruby-ot 側で spinel ローカルビルド〜 `suppify -t picoruby` での gem 再生成〜再ベンダリング（上記「その先」1-2）。
2. ESP32 向けビルド（上記3）。実機転送・書き込みは user が実機接続を明言した場合のみ実施可（下記「制約」参照）。
3. 実機で `NoMethodError` が解消していることを確認（上記4）。
4. `otmeiwa.rb`/`otmeiwa_aot.rb` の交互切り替えでスループット計測、完了基準達成を確認（上記5）。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel 依存は外部ツール参照のみ。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり（origin が `bash0C7/*` の場合）。
- picoruby-ot 側のビルド／転送は user が実機接続を明言した場合のみ Claude が実行してよい（前セッションで承認済み — "マイコンデバイスはUSB接続しているので、準備がととのったらbuildして転送してね"。ただし実機操作を伴う具体的な作業に着手する前には、この承認が今回のセッションでも有効か再確認すること）。
- **merge は実機動作確認完了後のみ、提案も禁止**（`~/dev/src/CLAUDE.md` 規律）。
