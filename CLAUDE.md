# CLAUDE.md — suppify

suppify = spinel が出力した native コードを、呼び出し可能・組み込み可能な中立ライブラリ
（`.a` + C header）へ変換する外部ツール。設計は `docs/superpowers/specs/2026-06-21-suppify-design.md`。

> グローバル / 親ディレクトリの CLAUDE.md の規律はすべて継承する。

## この repo の規約

- **コミットメッセージは英語で書く**（本文・subject ともに）。
- **実装は Ruby**（No Python）。
- **spinel への依存は「外部ツール参照」に限る** — git submodule / vendoring / subtree は禁止。
  spinel バイナリと `lib/`（`sp_runtime.h` / `libspinel_rt.a`）は PATH / 環境変数 /
  `--spinel-bin` `--spinel-lib` で発見する（`cc` を呼ぶのと同じ扱い）。
  spinel ソースは CI / テスト時の **ephemeral な pinned clone**（gitignore した tmp）でのみ用意する。
- **生成物は自己完結させる** — 出力バンドルは `lib<name>.a` + コピーした `libspinel_rt.a`
  + 中立 header。consumer 側は spinel インストール不要。
