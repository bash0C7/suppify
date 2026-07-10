# HANDOFF — suppify

状態: **suppify 側完了 / picoruby-ot 側はファームウェアビルド・検証済みまで完了、実機フラッシュ待ち**。
otmeiwa AOT パイロットの実機 `NoMethodError` は根本原因が 3 つあり、全て修正済み。修正入りファームウェア
（`R2P2-ESP32.elf`）はビルド済みで、gem のシンボル・登録テーブル・メソッド名文字列が入っていることを
elf レベルで検証済み。**残りは実機フラッシュ → `NoMethodError` 解消確認 → スループット計測のみ**
（実機操作は user の接続明言が必要 — 下記「制約」）。あわせて suppify 本体を 1層=1ファイルへ
リファクタリング済み（挙動不変をゴールデン比較で証明、commit `3377f9e`）。

## 完了基準（user 発言そのまま、未達成）

> 完了基準はAOT版で実際に演奏できること。現行版と交互に入れ替えてスループット計測できることね。

## 実機 NoMethodError の根本原因 3 つ（全て修正済み）

1. **gem 登録機構の不一致**（suppify 側、commit `16fde85`）。mrubyc ファームウェアで gem の C メソッドを
   登録する唯一の経路は picoruby-require が生成する `prebuilt_gems[]` テーブル
   （`build/esp32/mrbgems/picogem_init.c`）で、`require '<lib>'` 時に `mrbc_<lib>_init(mrbc_vm*)` を呼ぶ。
   テーブルに載る条件は **gem に `mrblib/*.rb` があること**（`picoruby-require/mrbgem.rake` の
   `collect_gems`）。mruby 流の集約 `gem_init.c` はアーカイブに入るだけでファームウェアリンクには
   引き込まれない — つまり `mrb_*_gem_init` だけの binding は「コンパイル・リンクは通るが呼ばれない」。
   修正: `Binding::Mrubyc` が `mrbc_<lib>_init(mrbc_vm *vm)` を登録本体として生成し
   （`mrb_*_gem_init` は委譲で残置）、`Emitter::PicoRubyGem` が `mrblib/<lib>.rb` スタブを生成する。
   アプリ側は `require 'otmeiwa_aot'` が必要（`otmeiwa_aot.rb` に追加済み）。
2. **32bit での bit-pack 破綻**（picoruby-ot 側、commit `f73d8fb`）。spinel の `mrb_int` は `intptr_t`
   （Xtensa/ESP32 で 32bit）。旧設計の 3軸×16bit=48bit パックはネイティブ側で UB + 切り捨て。
   なお mrubyc VM の Ruby Integer は 64bit（`xtensa-esp.rb` の `PICORUBY_INT64` →
   `lib/picoruby/build.rb:84` で `MRBC_INT64`）なので Ruby 側は無関係 — 制約はネイティブ境界のみ。
   修正: `otmeiwa_accel_tick(ax_raw, ay_raw, bx_raw, by_raw)` → 2軸×15bit（bias 16384、bit 0/15、
   最大 bit 29 で int32 安全、±2G の ±4000mG に十分）+ `otmeiwa_accel_z_tick(az_raw, bz_raw)` →
   プレーン整数。`otmeiwa_core.rb`/`.rbs`/host テスト/`otmeiwa_aot.rb` のアンパック/設計ドキュメント
   すべて更新済み。
3. **gem が本当にリンクされると DRAM 超過 + 未定義参照**（picoruby-ot 側、同 `f73d8fb`）。
   従来は gem が参照ゼロで丸ごと dead-strip されていたため潜在していた。spinel GC のルート配列
   `sp_gc_roots` が既定 `SP_GC_STACK_MAX=65536`（=256KB static）で dram0 を単独で溢れさせる →
   `sp_gc.h` 文書化済みの embedded knob `-DSP_GC_STACK_MAX=4096` を mrbgem.rake パッチで指定
   （このgem の export は割り当てゼロの整数演算なので十分）。また除外済み `sp_fiber.c` の
   `sp_mark_fiber_root_storage` を `sp_runtime.h` の `sp_re_mark_globals` が呼ぶ → ESP32 ガード追加。

## ファームウェア検証済み事項（実機未接続のまま確認できる範囲は全部済み）

- `R2P2-ESP32.elf`（`components/R2P2-ESP32/build/`）に `mrbc_otmeiwa_aot_init`・`c_suppi_*` 3 関数・
  `otmeiwa_distance_tick` 等のメソッド名文字列が存在（xtensa-nm / strings で確認）。
- `picogem_init.c` に `{"otmeiwa_aot", picogem_otmeiwa_aot, mrbc_otmeiwa_aot_init, false}` エントリ。
- DRAM リンク成功（app partition 22% free）。`storage.bin` の `app.mrb` = 新 `otmeiwa_aot.rb`。
- 注意: ESP-IDF は `picoruby/build/esp32/lib/libmruby.a` を **prebuilt library**（ソース依存なしの
  custom command）として扱うため、gem ソース変更は自動では再ビルドされない。確実な手順:
  `rm -rf components/.../picoruby/build/esp32` してから `rake build`。

## suppify リファクタリング（commit `3377f9e`）

1層=1ファイル: `lib/suppify/core.rb`（`NeutralType`/`Signature`+`SignatureExtractor`/`Source`
[旧 Visibility+RbsSeed+RootInjector]/`SpinelRunner`/`Pipeline`[旧 Pipeline+SymbolMap+MainRenamer+
Trampoline+Header]）／`lib/suppify/bindings.rb`（`Binding::CRuby|Mruby|Mrubyc`、API 不変）／
`lib/suppify/package.rb`（`RuntimeSources`/`SymbolPrefix`/`Emitter::CArchive`[旧 Builder]/
`Emitter::CRubyGem`/`Emitter::PicoRubyGem`）／`lib/suppify/cli.rb`。テストも同じ区切り
（`test/test_{core,bindings,package,cli}.rb` + 統合テスト群）。

挙動不変の証明: (a) 実 spinel でフルスイート 129 tests/326 assertions/0 failures/0 omissions
（spinel を PATH に載せると統合テストが実走する）、(b) fixture から 3 ターゲットの生成物を
リファクタ前後で比較し製品ファイル全 byte 一致（`.a` はメンバー・シンボル一致）、
(c) picoruby-ot の vendored gem を再生成 → commit 済み内容と byte 一致。
旧テスト 102 メソッド全てに対応先あり（機械監査済み）。
なお fresh-context の adversarial review workflow は subagent session limit で未完走
（docs-consistency のみ完走）— インライン監査 + ゴールデンで代替した。気になるなら後で
`/workflows` の `suppify-refactor-review` を再実行してよい。

## 再開手順（次にやること）

1. **user に実機接続の明言をもらう**（制約参照）。もらえたら picoruby-ot で
   `rake flash`（Rakefile タスク、要 ESP-IDF 環境）→ `rake monitor` またはシリアル直読み。
2. `NoMethodError` が出ず `<D:…,AX:…,AY:…,AZ:…>` フレームがループ出力されることを確認
   （AOT 経路は `require 'otmeiwa_aot'` 成功 + sound_on 時の accel 値が正であることまで見る）。
3. ベンチマーク: `APP=otmeiwa_aot` と `APP=otmeiwa` で `rake build && rake flash` を交互に行い、
   user の `/dev --debug` fps ツールで比較（シリアルの frame/sec を直接数える補助測定も可）。
4. 完了基準（演奏可能 + 計測）達成を user が確認したら、picoruby-ot 側の merge 話は **user から
   切り出すまで待つ**。

### gem 再生成の手順（picoruby-ot 側、パッチ再適用込み）

```bash
cd ~/dev/src/github.com/bash0C7/picoruby-ot
SUPPIFY_ROOT=~/dev/src/github.com/bash0C7/suppify \
SPINEL_LIB=/tmp/otmeiwa-aot-spinel/lib \
PATH="/tmp/otmeiwa-aot-spinel/bin:$PATH" \
  rake native:otmeiwa_aot
# 再生成は vendoring パッチを上書きするので再適用（2 コミットに分かれている）:
GEM=src_components/R2P2-ESP32/components/picoruby-esp32/picoruby/mrbgems/picoruby-otmeiwa_aot
git show 6ce9141 -- "$GEM" | git apply                                   # POSIX ガード 4 ファイル
git show f73d8fb -- "$GEM/mrbgem.rake" "$GEM/src/sp_runtime.h" | git apply # SP_GC_STACK_MAX + fiber guard
git diff --stat -- "$GEM"   # suppify/otmeiwa_core が無変更なら空になるはず
```

spinel は `/tmp/otmeiwa-aot-spinel`（pin `9394f6e`、ビルド済み）。消えていたら
`native/otmeiwa_core/README.md` の手順で再構築。

## 記録しておく検討事項（未着手・約束ではない）

- `SP_GC_STACK_MAX` の縮小は `-t picoruby` の全 consumer が必ず踏む壁（256KB static は
  どの MCU にも収まらない）なので、picoruby-ot 側パッチでなく suppify の emitter 既定に
  昇格させる価値がある。サイズはプログラム依存（root 溢れは silent UAF）なので既定値の選定は慎重に。
- `picoruby-irq`/`picoruby-crc` は `mrbc_*_init` のみで `mrb_*_gem_init` を定義しない（集約
  `gem_init.c` は参照するが mrubyc リンクに引き込まれないため無害）。mruby(microruby) ビルドを
  通す時に顕在化し得る。今回のスコープ外、記録のみ。
- ESP-IDF 側 `CMakeLists.txt` の `ADDITIONAL_DEFINITIONS` に `MRBC_INT64` が無い（libmruby.a 側は
  `PICORUBY_INT64` 経由で有効）。ports が `mrbc_value` を値渡しする場合 ABI 不一致になり得るが、
  現行ファームウェアは実機で動作しており今回は触らない。記録のみ。

## picoruby-ot 側の現在の状態

- リポジトリ: `~/dev/src/github.com/bash0C7/picoruby-ot`、branch `joyful_meiwa_2026`、
  HEAD `ece3e20`（`f73d8fb` = 本修正、`ece3e20` = .gitignore）。working tree clean。push 未実施。
- ビルド成果物: `components/R2P2-ESP32/build/{R2P2-ESP32.elf,R2P2-ESP32.bin,storage.bin}`（検証済み）。

## このリポジトリ（suppify）は何か

`suppify` = spinel でコンパイルした Ruby を、どこからでも呼べる中立 C ライブラリ／gem へ変換する
外部ツール。spinel 本体は無改変。設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`。
構造は上記リファクタリング節のとおり（コア／バインディング／エミッタ／CLI、1層=1ファイル）。
CLI: `-t/--target c|cruby|picoruby`。`cruby`/`picoruby` は `SPINEL_LIB` 必須。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel 依存は外部ツール参照のみ。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり（origin が `bash0C7/*`）。
- picoruby-ot の実機フラッシュ・転送は **user がこのセッション（または当該作業セッション）で
  実機接続を明言した場合のみ**実行可。
- **merge は実機動作確認完了後のみ、提案も禁止**（`~/dev/src/CLAUDE.md` 規律）— user から
  切り出すまで待つ。
