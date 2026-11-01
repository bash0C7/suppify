# CLAUDE.md — suppify

suppify = spinel のライブラリ出力（`--ext-init` / `--ext-entry`）で compile した Ruby kernel を、
自己完結した PicoRuby mrbgem（mruby VM / mruby/c VM 両対応）に包む外部ツール。
kernel の plain C 契約（型付き entry / MessagePack entry / kernel table）も同じ gem に入る。
使い方と picoruby-aot との使い分けは `README.md`。

構成は 1関心=1ファイル:

- `lib/suppify/spinel.rb` — spinel を呼び、`Entry` / `Library` を組み立てる
- `lib/suppify/glue.rb` — C 契約: 公開 header（`include/<n>.h`）と glue TU
- `lib/suppify/binding.rb` — mruby / mruby/c の module method（`binding.c`）
- `lib/suppify/mrbgem.rb` — gem ディレクトリと `mrbgem.rake` の書き出し、runtime の同梱
- `lib/suppify/cli.rb` — コマンドライン

テストも同じ区切り（`test/test_{glue,binding,mrbgem,cli}.rb` + `test/test_*_integration.rb`）。

> グローバル / 親ディレクトリの CLAUDE.md の規律はすべて継承する。

## この repo の規約

- **コミットメッセージは英語で書く**（本文・subject ともに）。
- **実装は Ruby**（No Python）。
- **コメントは rbs-inline の型（`#:`）と、クラス・メソッドの説明のみ**。理由・経緯は commit message に書く。
- **spinel への依存は「外部ツール参照」に限る** — git submodule / vendoring / subtree は禁止。
  spinel バイナリは `SPINEL` / `PATH` で発見し、runtime の場所は `spinel --print-build` から得る。
  spinel ソースはテスト時の ephemeral な pinned clone でのみ用意する。
- **生成 gem は自己完結させる** — spinel の runtime を gem の `src/` に同梱する。consumer 側は spinel 不要。
- **spinel の VM 非依存な仕事は spinel に任せる** — suppify は PicoRuby 向けの binding、C 契約、
  build 設定の受け渡しのみ持つ。ボード向け runtime 層は spinel の `lib/newlib`。
- **spinelは常に1コミットへpinする**（`spinel.pin`）。pin 先は matz/spinel に `lib/newlib` を足した
  fork（bash0C7/spinel）のコミット。追従は `spinel:latest` / `spinel:check_pin` /
  `spinel:bump_pin`（`rakelib/spinel.rake`）で行う — `check_pin` は検証のみ、`bump_pin` は
  検証green時のみ `spinel.pin` を書く。手順は `spinel-tracking` skill（`.claude/skills/spinel-tracking/`）。
  downstream consumer への pin 伝播は consumer 側の責務。
