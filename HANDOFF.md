# HANDOFF — suppify / otmeiwa AOT パイロット

状態: **実機確認・スループット計測 完了、演奏確認は未実施**。`otmeiwa_aot`・`otmeiwa`（interpreted）
両方を実機フラッシュし、`NoMethodError` なしでフレームループ出力を確認、シリアルの frame/sec 実測も
取得済み。残るのは sound_on ボタン操作を伴う実演奏確認（user の耳と手が必要）のみ。

## ゴール（user 発言そのまま）

> 完了基準はAOT版で実際に演奏できること。現行版と交互に入れ替えてスループット計測できることね。

## 実機確認結果

- 両バージョンとも `NoMethodError` なし。`<D:…,AX:…,AY:…,AZ:…>` フレームが継続ループ出力
  （ボタン未操作時は AX/AY/AZ=0 で想定どおり）。
- スループット実測（シリアル frame/sec、`<D:` 出現待ち後の10秒窓で計測、同一手法2回）:
  - `otmeiwa_aot`（AOT版）: 約 20.1〜20.6 fps
  - `otmeiwa`（interpreted版）: 約 20.0 fps
  - 差はおよそ1〜3%で誤差範囲に近い。ループはネイティブ演算でなく固定 delay か I2C センサー読み取り
    等で律速されていると見られる。AOT化による大幅な高速化は確認されなかった。

## 残作業

1. sound_on ボタンを押した状態での実演奏確認（AX/AY/AZ が意味を持つ値になり、音が鳴ること）。
   ボタン操作と音の主観評価は user のみが行える。
2. 完了基準達成の確認は user が行う。merge の話題は user から出るまで待つ。

## 動作の前提となる現在の仕組み（操作に必要な事実）

- **mrubyc ファームウェアの gem 登録**: picoruby-require 生成の `prebuilt_gems[]` テーブル
  （`picoruby/build/esp32/mrbgems/picogem_init.c`）経由。`require '<lib>'` が
  `mrbc_<lib>_init(mrbc_vm*)` を呼び bytecode をロードする。テーブルに載る条件は gem に
  `mrblib/*.rb` があること。suppify の `-t picoruby` はこの両方（`mrbc_<lib>_init` 定義 +
  `mrblib/<lib>.rb` スタブ）を生成する。アプリは `require 'otmeiwa_aot'` 必須（記述済み）。
- **ネイティブ境界は 32bit**: spinel の `mrb_int` は `intptr_t`（Xtensa で 32bit）。AOT 関数を
  跨ぐ値・AOT 内部の演算は int32 に収めること。mrubyc VM 側の Ruby Integer は 64bit
  （`PICORUBY_INT64` → `MRBC_INT64`）なので Ruby 側は制約なし。現行の accel は
  `otmeiwa_accel_tick(ax,ay,bx,by)` = 2軸×15bit パック（bias 16384、bit 0/15）+
  `otmeiwa_accel_z_tick(az,bz)` = プレーン整数。
- **ESP-IDF は libmruby.a を prebuilt 扱い**（ソース依存なしの custom command）。gem ソースを
  変えたら `rm -rf components/R2P2-ESP32/components/picoruby-esp32/picoruby/build/esp32` してから
  `CFLAGS="-Wno-error=implicit-function-declaration" APP=otmeiwa_aot rake build`。
- **vendoring パッチ**（gem 再生成のたび再適用が必要）: POSIX 専用コードの ESP32 ガード 4 ファイル +
  `-DSP_GC_STACK_MAX=4096`（spinel GC ルート配列の既定 65536=256KB static は dram0 に収まらない。
  `sp_gc.h` 文書化済みの embedded knob）+ `sp_runtime.h` の `sp_mark_fiber_root_storage` ガード
  （`sp_fiber.c` はビルド除外のため）。

### gem 再生成の手順（picoruby-ot 側）

```bash
cd ~/dev/src/github.com/bash0C7/picoruby-ot
SUPPIFY_ROOT=~/dev/src/github.com/bash0C7/suppify \
SPINEL_LIB=/tmp/otmeiwa-aot-spinel/lib \
PATH="/tmp/otmeiwa-aot-spinel/bin:$PATH" \
  rake native:otmeiwa_aot
# 再生成はパッチを上書きするので再適用（パッチの正本は下記 2 コミット）:
GEM=src_components/R2P2-ESP32/components/picoruby-esp32/picoruby/mrbgems/picoruby-otmeiwa_aot
git show 6ce9141 -- "$GEM" | git apply
git show f73d8fb -- "$GEM/mrbgem.rake" "$GEM/src/sp_runtime.h" | git apply
git diff --stat -- "$GEM"   # suppify/otmeiwa_core が無変更なら空
```

spinel は `/tmp/otmeiwa-aot-spinel`（pin `9394f6e`、ビルド済み、ephemeral）。無ければ
`native/otmeiwa_core/README.md` の手順で再構築。

### シリアル出力の読み方（TTY 非対話環境）

`rake monitor`（`idf.py monitor`）は標準入力が TTY であることを要求するため、非対話シェルからは
`Error: Monitor requires standard input to be attached to TTY` で失敗する。代わりに pyserial で
直接読む。macOS では serial port を開いた瞬間 DTR/RTS がデフォルトで assert され ESP32 が reset
保持されたままになる個体があるため、open 前後で明示的に `dtr = False` / `rts = False` を設定する。

```bash
/Users/bash/.espressif/python_env/idf5.4_py3.12_env/bin/python - <<'PYEOF'
import serial, time
ser = serial.Serial()
ser.port = '/dev/cu.usbserial-59525718F0'  # 実機ごとに変わる、ls /dev/cu.* で確認
ser.baudrate = 115200
ser.timeout = 1
ser.dtr = False
ser.rts = False
ser.open()
ser.dtr = False
ser.rts = False
end = time.time() + 20
while time.time() < end:
    data = ser.read(4096)
    if data:
        import sys; sys.stdout.buffer.write(data); sys.stdout.flush()
ser.close()
PYEOF
```

## 静的検証済み事項（実機なしで確認できる範囲は完了）

- `components/R2P2-ESP32/build/R2P2-ESP32.elf` に `mrbc_otmeiwa_aot_init`・`c_suppi_*` 3 関数・
  メソッド名文字列が存在（xtensa-nm / strings）。`picogem_init.c` に otmeiwa_aot エントリ。
  DRAM リンク成功（app partition 22% free）。`storage.bin` の `app.mrb` = `otmeiwa_aot.rb`。
- suppify: 実 spinel でフルスイート green（spinel を PATH + `SPINEL_LIB` で与えると統合テストが
  omission でなく実走する）。fixture 3 ターゲット生成物および picoruby-ot vendored gem の
  再生成結果が commit 済み内容と byte 一致。
- host: `native/otmeiwa_core/test_otmeiwa_core.rb` 全通過。

## リポジトリの現在地

- **suppify**（このリポジトリ、`main`）: 1層=1ファイル構成。`lib/suppify/core.rb`
  （`NeutralType`/`Signature`+`SignatureExtractor`/`Source`/`SpinelRunner`/`Pipeline`）／
  `lib/suppify/bindings.rb`（`Binding::CRuby|Mruby|Mrubyc`）／`lib/suppify/package.rb`
  （`RuntimeSources`/`SymbolPrefix`/`Emitter::CArchive|CRubyGem|PicoRubyGem`）／
  `lib/suppify/cli.rb`。テストは `test/test_{core,bindings,package,cli}.rb` + 統合テスト群。
  設計: `docs/superpowers/specs/2026-06-21-suppify-design.md`。push 未実施。
- **picoruby-ot**（`~/dev/src/github.com/bash0C7/picoruby-ot`、branch `joyful_meiwa_2026`）:
  working tree clean、push 未実施。AOT 入力は `native/otmeiwa_core/`、アプリは
  `src_components/R2P2-ESP32/storage/home/otmeiwa_aot.rb`（interpreted 版 `otmeiwa.rb` は無改変）。

## 検討事項（未着手・約束ではない）

- `SP_GC_STACK_MAX` 縮小は `-t picoruby` の全 consumer が踏む壁のため、picoruby-ot 側パッチから
  suppify emitter の既定へ昇格する価値がある。root 溢れは silent UAF なので既定値選定は慎重に。
- `picoruby-irq`/`picoruby-crc` は `mrbc_*_init` のみ定義（`mrb_*_gem_init` なし）。mrubyc リンク
  では無害、mruby(microruby) ビルドを通す時に顕在化し得る。
- R2P2-ESP32 の `CMakeLists.txt` は ESP-IDF 側定義に `MRBC_INT64` を含まない（libmruby.a 側のみ
  有効）。ports が `mrbc_value` を値渡しすると ABI 不一致になり得る。現行実機は動作しており対象外。
- `conf.picoruby` が選ぶ VM は picoruby のバージョンで異なる（upstream master: `PICORB_VM_MRUBY` /
  R2P2-ESP32 pin: `PICORB_VM_MRUBYC`）。ドキュメントや検証は conf メソッド名でなく
  `PICORB_VM_MRUBYC` define を基準にする。

## 制約（厳守）

- commit message は英語。Ruby のみ（No Python）。spinel 依存は外部ツール参照のみ
  （submodule/vendoring 禁止、ephemeral pinned clone のみ）。
- push / PR / amend は user 承認必須。ローカル commit は autonomy あり（origin が `bash0C7/*`）。
- picoruby-ot の実機フラッシュ・転送は user が当該セッションで実機接続を明言した場合のみ実行可。
- merge は実機動作確認完了後のみ、提案も禁止 — user から切り出すまで待つ。
