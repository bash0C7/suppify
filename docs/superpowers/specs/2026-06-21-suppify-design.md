# suppify — 設計ドキュメント

- 日付: 2026-06-21
- ステータス: 設計確定（実装前）
- 対象: spinel が出力した native コードを、呼び出し可能・組み込み可能な中立ライブラリ（`.a` + C header）へ変換する外部ツール

---

## 1. 名前と比喩

**suppify** = 「Suppi 化する」動詞。

- カードキャプターさくら（英国編）の守護獣 **スピネル・サン**＝コンパイラ `spinel`。
- その完璧で grand な「真の姿」＝ spinel が既定で吐く **executable**（スーパーセット）。
- 持ち運べて他に宿せる小さな「仮の姿」＝コミカルな **Suppi（すっぴー）**＝こちらが作る **中立ライブラリ**（サブセット）。
- ツールの動作 = 真の姿（executable）を Suppi の仮の姿（埋め込み可能ライブラリ）へ変換する＝ **suppify**。

`-ify` は「〜化する」の正統な英語動詞語尾（simplify / purify）であり、build ツール命名文化（browserify / babelify / uglify）にも乗る。

---

## 2. 目的・非目的

### 目的
- spinel の出力を、Swift（iOS / macOS）・PicoRuby/R2P2・ESP32 など**どこからでもリンクして呼べる中立な C ライブラリ**（`.a` + header）にする。
- **spinel 本体を一切改変しない**。stock フラグのみを入力に使う完全外部ツールとして成立させる。
- spinel のバージョンアップに対する耐性を **CI で保証**する。

### 非目的（v1 でやらないこと）
- spinel への PR / fork（将来 utility として上流提案する余地は残すが、依存しない）。
- インスタンスメソッド / クラスメソッドのエクスポート（`self` がクラス依存の C 型になるため v2 以降）。
- 非スカラー境界（poly / オブジェクト / ブロック `sp_Proc*`）のエクスポート。
- マルチ arch ビルド・xcframework・各ターゲットの glue（iOS Swift bridge / PicoRuby mrbgem / ESP32 CMake）。これらは suppify の出力（中立 `.a` + header）を消費する後続フェーズ。
- 完全な例外伝播（v1 はエラーフラグ方式で host を abort させないことを保証するに留める）。

---

## 3. 設計の中心思想

exe か lib かの**分岐をコンパイラ本体に持たせない**。spinel は executable 生成器のまま使い、その出力（`.c` ＋ symbol map）を suppify が外側で組み立て直す。分岐は suppify という driver 層にのみ存在する。

```
[spinel 本体 — 無改変・stock フラグのみ]
 app.rb
  └─ spinel app.rb -c -o app.c --emit-symbol-map
        ├─ app.c             （static 関数群 + int main(...) を含む単一 TU）
        └─ app.symbols.json  （C 名 ↔ Ruby 名 ↔ kind）

[suppify — 外部ツール（Ruby 実装）]
  app.c + app.symbols.json
   → ① signature 抽出（app.c をパース）
   → ② 中立スカラー関数のみ選別（kind=toplevel）
   → ③ トランポリン + sp_lib_init を app.c 末尾へ追記
   → ④ int main(...) を static int sp__main(...) へ rename
   → ⑤ header (libname.h) 生成
   → ⑥ cc -c → ar
        ├─ liblibname.a
        └─ libname.h          （中立成果物：以降どこからでもリンク可能）
```

入力フラグ `-c` と `--emit-symbol-map`（PR #1345 でマージ済み）はいずれも spinel の公開契約であり、改変ではない。

---

## 4. signature の入手方法（外部ツールの肝）

関数シグネチャ（戻り値型・各引数の C 型）は spinel の JSON 出力からは復元できない。確認済みの根拠:

- `--emit-types`（spinel `src/codegen.c:2112`）は式の位置（file:line:col）ごとの型で、関数単位に組み直せない。
- `--emit-symbol-map`（spinel `src/codegen.c:1857`）は C 名 ↔ Ruby 名 ↔ kind のみで型を持たない。
- self の C 型はクラス名から決まる（spinel `emit_method_signature`, `src/codegen.c:368`）。

しかしシグネチャは**生成 `app.c` の本文に完全な定義として存在する**:

```c
static mrb_int sp_add(mrb_int a, mrb_int b) { ... }
```

`symbols.json` が「`sp_add` ↔ Ruby `add` ↔ kind=toplevel」を与えるので、その `cname` の定義を `app.c` から特定し、戻り値型と引数リストを読み取る。これが唯一の「機械生成 C のテキスト解析」であり、§8 の CI で守る対象。

---

## 5. v1 スコープの絞り込み

**エクスポート対象 = `kind == "toplevel"` かつ全引数・戻り値がスカラー**の関数のみ。

- スカラー型: `mrb_int`（= intptr_t）/ `double` / `const char *` / bool。Swift とも PicoRuby/C とも素直に橋渡しできる。
- トップレベル関数なら `self` もブロックも無く、`static <scalar> sp_<name>(<scalar...>) {` という規則的な形に揃う → パーサが単純かつ壊れにくい。
- 非スカラー・インスタンスメソッド・クラスメソッドは警告して対象外（リンクはされるが header に出さない）。
- 利用側の規約: **エクスポートしたい関数はトップレベルでスカラー入出力にする**。

---

## 6. 組み立て手順（すべて suppify 内・Ruby 実装、Python 不使用）

1. `spinel app.rb -c -o <tmp>/app.c --emit-symbol-map` を実行。
2. `app.symbols.json` から `kind=toplevel` を列挙し、`app.c` から各 `cname` 定義のシグネチャを抽出。
3. スカラーのみの関数を選別（非スカラーは警告ログ）。
4. **`app.c` 末尾にトランポリンを追記**（同一翻訳単位なので `static` 関数を呼べる）。例外バリアは spinel runtime に既存の `sp_exc_arm` / `sp_exc_disarm`（`lib/sp_runtime.h:5214`）を使用 → **runtime も無改変**。

   ```c
   /* === suppify appended trampolines === */
   static int g_suppi_err = 0;
   static const char *g_suppi_msg = 0;
   mrb_int LIBNAME_add(mrb_int a, mrb_int b) {
       jmp_buf jb;
       if (setjmp(jb)) { sp_exc_disarm(); g_suppi_err = 1; return 0; }
       sp_exc_arm(jb);
       mrb_int r = sp_add(a, b);   /* 同 TU 内の static 関数を呼ぶ */
       sp_exc_disarm();
       return r;
   }
   int         suppi_error(void)         { return g_suppi_err; }
   const char *suppi_error_message(void) { return g_suppi_msg; }
   ```

5. **`int main(int argc, char **argv)` を `static int sp__main(int argc, char **argv)` へ rename**（空白に寛容な正規表現で 1 行置換）し、初期化を 1 度だけ駆動する `sp_lib_init()` を追記。これで初期化ロジックの再実装はゼロ、`main` シンボル衝突も解消。

   ```c
   void sp_lib_init(void) {
       static int done = 0; if (done) return; done = 1;
       char *av[] = { "lib", 0 };
       sp__main(1, av);   /* 生成済みの初期化 + トップレベルをそのまま 1 回実行 */
   }
   ```

6. `symbols.json` ＋ 抽出シグネチャから `libname.h` を生成（トランポリンのプロトタイプ ＋ `void sp_lib_init(void);` ＋ `int suppi_error(void);` ＋ `const char *suppi_error_message(void);`）。
7. `cc -c <tmp>/app.c -I<spinel>/lib -o <tmp>/app.o` → `ar rcs liblibname.a <tmp>/app.o`。利用側は `liblibname.a` ＋ `libspinel_rt.a` をリンク（macOS では `libtool -static` で 1 本化する利便化も将来検討）。

テキスト処理に依存するのは **(2) signature 抽出** と **(5) main rename** の 2 点のみ。CI の監視対象。

---

## 7. 中立 ABI 契約

- 境界に出してよい型はスカラーのみ（`mrb_int` / `double` / `const char *` / bool）。
- 例外はホストを巻き込まず、`suppi_error()` / `suppi_error_message()` で問い合わせる方式に変換（v1）。完全な per-call 例外伝播は後続。
- **`sp_lib_init()` は呼び出しスレッドで、浅いフレームから 1 度だけ**呼ぶ規約（GC のスタック基準確定のため）。

---

## 8. バージョン耐性を保証する CI 設計

外部ツールが spinel の出力を解析する以上、脆さは「検知できる脆さ」へ変換する。

- **バージョンマトリクス**: pin した spinel の複数バージョン（最新安定 + 数世代）で「spinel ビルド → suppify 実行 → ハーネスをコンパイル → 期待出力をアサート」を回す。
- **カナリア**: `matz/spinel@master`（nightly）を非ブロッキングで回し、上流 codegen の整形変更を壊れる前に早期検知。
- **ゴールデン検査**: フィクスチャから抽出されるべきシグネチャ件数・内容を golden 比較し、パーサのサイレントな取りこぼしを検出。
- **スモークアサート**: `add(2,3)==5`、`boom` で `suppi_error()==1`。
- 失敗時は「どの spinel バージョンでパーサが壊れたか」が CI ログで一目で分かる。

---

## 9. テスト（TDD・ハーネス先行）

```ruby
# fixtures/add.rb
def add(a, b) = a + b
def boom     = raise "x"
```

```c
/* harness.c */
#include "libname.h"
int main(void){
    sp_lib_init();
    printf("%ld\n", LIBNAME_add(2, 3));            /* => 5 */
    LIBNAME_boom(); printf("%d\n", suppi_error());  /* => 1 */
}
```

`5` と `1` が出れば Phase 1 のゲート通過。実装はこのハーネステストを先に書く。

---

## 10. 主なリスク

- **生成 C 整形のバージョン差**: signature 抽出・main rename が将来の spinel で壊れ得る → §8 の CI（特に master カナリア + ゴールデン検査）で検知。
- **GC スタック基準**: `sp_lib_init()` のフレームより深い所からトランポリンを呼ぶ前提。init を浅いフレームで 1 度だけ呼ぶ規約を文書化し、ハーネスで検証。
- **例外バリアと runtime の結合**: `sp_exc_arm`/`disarm` のグローバル stack 前提が将来変わる可能性 → CI のスモークアサート（`boom`）で検知。
- **複数 suppify ライブラリの同時リンク**: `sp_lib_init` / `sp__main` / `suppi_error` / `libspinel_rt.a` のシンボルが共通名のため、1 つの実行ファイルに 2 つ以上の suppify 製 `.a` をリンクすると衝突する。v1 は「1 バイナリにつき suppify ライブラリ 1 つ」を制約とする。複数同居は将来フェーズで lib 名 prefix のシンボル名前空間化（`sp_lib_init` → `<libname>_lib_init` 等）で解く。

---

## 11. 後続フェーズ（v1 の中立成果物を消費する）

1. インスタンス/クラスメソッド・非スカラー境界のエクスポート。
2. マルチ arch ビルド（macOS arm64 / iOS device arm64 / iOS sim / ESP32 xtensa・riscv32）→ Apple 向け xcframework。
3. 各ターゲット glue:
   - Swift: bridging header / module map でリンク。
   - PicoRuby/R2P2: 中立 C API を Ruby メソッドに包む C mrbgem。
   - ESP32: CMake `target_link_libraries()` または mrbgem `spec.objs`。

---

## 付録: 確認済みの spinel 事実（根拠）

- 生成関数は本番ビルドで `static`（`src/codegen.c:360`）。同一 TU 内からは呼べる → トランポリンを app.c に追記する根拠。
- C シンボル命名は決定論的: `sp_<name>` / `sp_<Class>_<name>` / `sp_<Class>_s_<name>`（`src/codegen.c:344`）。
- `main()` は init（`SP_GC_SAVE` / `sp_re_init` / srand / トップレベル文）を内包（`src/codegen.c:2918`）→ rename で再利用。
- 例外機構: `sp_exc_stack` グローバル + `sp_exc_arm`/`sp_exc_disarm`（`lib/sp_runtime.h:5214`）で per-call setjmp バリアが runtime 無改変で可能。
- runtime 依存: libc + malloc。ucontext は Fiber のみ（aarch64/x86_64 は register-save asm で ucontext 不要、`lib/sp_fiber_ctx.h:26`）。iOS arm64 は素直、ESP32 は Fiber 不使用なら可。
- 既存 metadata 出力フラグ: `--emit-symbol-map`（PR #1345 merged）/ `--emit-rbs`（#1276）/ `--emit-types`。`--emit-lib` 系 PR は存在しない。
- Issue #1367（OPEN）: "library consumption needs a stable package identity" — 上流もライブラリ消費を未解決論点として認識。
