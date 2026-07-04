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
- マルチ arch ビルド・xcframework・各ターゲットの glue（iOS Swift bridge / PicoRuby mrbgem / ESP32 CMake）。これらは suppify の出力（中立 `.a` + header）を消費する後続フェーズ。
- 完全な例外伝播（v1 はエラーフラグ方式で host を abort させないことを保証するに留める）。
- **prebuilt native バイナリの配布**（out of scope）。利用者が自分で spinel ビルドして使う（§12）。
- **CRuby ランタイムでの実行 fallback**（提供しない）。CRuby は §9 のテストでのみ使う。

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
  app.c + app.symbols.json + app.rb（prism で parse）
   → ① prism(app.rb) で public メソッドを判定し export 集合を決定
   → ② export 各々を symbols.json で cname 解決、app.c から signature 抽出
   → ③ public はトランポリン+header で公開 / private は static のまま隠蔽。sp_lib_init を app.c 末尾へ追記
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

## 5. export 対象の決定（Ruby 可視性ベース）

**export 対象 = ソースの public メソッド。private は隠蔽。** スコープを人手で宣言（`--export`）も型で自動推定もしない。Ruby が既に `public` / `private` で公開意図を宣言しているので、それに従う。

- **判定は prism で app.rb を静的 parse** して public メソッド集合を得る（prism は spinel 自身が parse に使う libprism。§12）。public → extern トランポリン＋header、private → 生成 C の `static` のまま `.a` 内に隠蔽。これは C の可視性そのもの（extern=公開 / static=内部）。
- **動的可視性操作の取りこぼしは実害なし**: runtime での可視性変更（`eval` / runtime `define_method` / `send` 経由）は spinel が AOT できない領域とほぼ一致するため、spinel でコンパイルできる subset 内では静的 parse が正確。
- **非 C 表現な public メソッドはエラー**: public と宣言された関数のシグネチャが中立 C で表現できない（Ruby オブジェクト / Array / Hash 返し、ユーザ定義クラスの opaque な self 等）場合、その export をエラーにする（黙って外さない）。これは scope line ではなく C 境界の物理（§7）に対する明示要求の検証。

### 5.1 spinel の whole-program DCE との非互換（実機検証で発覚・v1 で対処済み）

実機 spinel（`src/analyze.c: compute_reachable`）は **プログラム内のどこからも呼ばれないトップレベルメソッドを、可視性に関係なく生成 C から丸ごと消す**。root はトップレベルスコープ（`main` 相当）・`initialize`・一部の暗黙呼び出しメソッド名のみで、そこから呼び出しグラフを BFS した到達範囲だけが生き残る。suppify が export したい public メソッドは定義上「プログラム内から呼ばれない」ため、素の `spinel app.rb -c` ではそれらの C 定義自体が存在しなくなる（symbol map には載るが本体が無い）。`--rbs DIR` で型シグネチャだけ与えても reachability には影響しない（advisory な型ヒントであり root 判定には関与しない。実験で確認済み）。

**対処（`RootInjector` + `RbsSeed`、CLI から自動適用）**:

1. 各 public メソッドについて `<input>.rbs` サイドカー（`class Object; def name: (T1, T2) -> R; end` 形式 — spinel 自身が `--rbs` でトップレベルメソッドを型付けする際に使う規約と同じ）で C シグネチャを宣言する。宣言が無い public メソッドは明確にエラー（黙って外さない、§5 の既存方針の延長）。
2. spinel へ渡す直前に、ソースの末尾へ `if false; <method>(<RBS 型から作った literal 引数>); ...; end` を追記した「rooted」コピーを生成する。`if false` で括るのは、この呼び出しが **実行時には絶対に発火してはならない** ため（後述）。spinel の到達可能性判定（`cr_collect_calls`）は分岐の実行可能性を見ず、スコープ本体に呼び出しノードが構文的に存在するかだけを見るため、`if false` 内でも root 化の効果は変わらない（実験で確認済み）。
3. `spinel <rooted.rb> --rbs <dir> -c -o <c>` を実行し、`--rbs` は型推論の後押し（特に戻り値型）に使う。

**なぜ実行時に呼んではいけないか**: §6 の `sp_lib_init()` は renamed `main`（＝ソースのトップレベル全体）を **ライブラリロード時に 1 回そのまま実行**する。ダミー呼び出しが `if false` に包まれず素通しだと、`sp_lib_init()` 実行時に本物の副作用（例外送出等）が発火し、suppify のトランポリン例外バリア（§6 の `sp_exc_arm`）の外側で spinel ランタイムの素の unhandled-exception ハンドラに落ちてプロセスが壊れる（実機で実際に再現・修正済み）。`if false` で C 側も dead branch になるため `sp_lib_init()` 実行時は完全に無害。

---

## 6. 組み立て手順（すべて suppify 内・Ruby 実装、Python 不使用）

1. **prism で app.rb を parse** し public メソッド集合（= export 対象）を決定（§5）。public メソッドが 1 つ以上あれば `<app>.rbs` サイドカーを読み、§5.1 の rooted コピーを作る。
2. `spinel <rooted or original>.rb -c -o <tmp>/app.c`（rbs サイドカーがあれば `--rbs <dir>` を付与）と `spinel <同> --emit-symbol-map -o <tmp>/app.symbols.json` を **別々に**実行（実機 spinel は `-c` と `--emit-symbol-map` を排他モードとして扱うため。§付録）。
3. export 各々を `app.symbols.json` で `cname` 解決し、`app.c` から signature 抽出。中立 C で表現不能な public 関数はエラー（§5）。
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
- **中立 header は spinel 型を漏らさない**: 公開プロトタイプでは `mrb_int` を標準型（`intptr_t` / `long long`）に、bool を `int` に写し、`sp_*` 型を一切含めない。これにより consumer（Swift / PicoRuby）は spinel の header を一切 include せずに済む。
- 例外はホストを巻き込まず、`<name>_error()` / `<name>_error_message()` で問い合わせる方式に変換（v1）。完全な per-call 例外伝播は後続。
- **`<name>_init()` は呼び出しスレッドで、浅いフレームから 1 度だけ**呼ぶ規約（GC のスタック基準確定のため）。
- lifecycle/error API（`<name>_init` / `<name>_error` / `<name>_error_message`）と文字列長ブリッジ（`<name>_str_len`）はライブラリごとに `-o` 名で prefix される（§10・§13）。

---

## 8. バージョン耐性を保証する CI 設計

外部ツールが spinel の出力を解析する以上、脆さは「検知できる脆さ」へ変換する。

- **バージョンマトリクス**: pin した spinel の複数バージョン（最新安定 + 数世代）で「spinel ビルド → suppify 実行 → ハーネスをコンパイル → 期待出力をアサート」を回す。
- **カナリア**: `matz/spinel@master`（nightly）を非ブロッキングで回し、上流 codegen の整形変更を壊れる前に早期検知。
- **ゴールデン検査**: フィクスチャから抽出されるべきシグネチャ件数・内容を golden 比較し、パーサのサイレントな取りこぼしを検出。
- **スモークアサート**: `add(2,3)==5`、`boom` で `suppi_error()==1`。
- 失敗時は「どの spinel バージョンでパーサが壊れたか」が CI ログで一目で分かる。

---

## 9. テスト（TDD）

テストは 2 層。**Ruby レイヤーの unit test を主戦場**にし、**spinel ビルドの E2E** を usage 検証＋ spinel 適合性検証として回す。

### (1) Ruby レイヤー unit test（主）
- **test-unit** gem を **bundler で repo ローカル管理**（`vendor/bundle`、いつものパターン）。dev / CI とも CRuby で実行。
- 対象: prism による public 判定（export 集合決定）、自作 JSON パーサ、シグネチャ抽出（C 定義行のパース）、トランポリン / header / `sp_lib_init` 生成、main rename。suppify のロジックを CRuby 上で直接駆動して検証する。
- 注: suppify 本体ソースは spinel subset 準拠（§12）。CRuby はその superset なので subset 準拠コードはそのまま CRuby でも動き、unit test が成立する。

### (2) spinel ビルド E2E（usage ＋適合性）
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
- 手順: `spinel suppify.rb -o suppify`（＝利用者の usage そのもの）→ その `suppify` バイナリで `fixtures/add.rb` を処理 → 出てきた `.a` ＋ header を `harness.c` にリンク → `5` と `1` が出れば Phase 1 ゲート通過。
- この経路は同時に「**spinel が suppify を 1 バイナリに build できる**」適合性テストを兼ね、§8 の version matrix ＋ master カナリアがこれを駆動する。

実装は (1)(2) のテストを先に書く（TDD）。

---

## 10. 主なリスク

- **生成 C 整形のバージョン差**: signature 抽出・main rename が将来の spinel で壊れ得る → §8 の CI（特に master カナリア + ゴールデン検査）で検知。
- **GC スタック基準**: `sp_lib_init()` のフレームより深い所からトランポリンを呼ぶ前提。init を浅いフレームで 1 度だけ呼ぶ規約を文書化し、ハーネスで検証。
- **例外バリアと runtime の結合**: `sp_exc_arm`/`disarm` のグローバル stack 前提が将来変わる可能性 → CI のスモークアサート（`boom`）で検知。
- **複数 suppify ライブラリの同時リンク（対処済み、§13）**: `sp_lib_init` / `sp__main` / `suppi_error` / spinel ランタイムのシンボルは元々共通名で、1 つの実行ファイルに 2 つ以上の suppify 製ライブラリをリンクすると衝突していた。`SymbolPrefix`（`nm` によるシンボル実発見 + `-include` prelude での `#define` リネーム）でライブラリごとに namespace 化し解決。CRuby（複数 gem を同一プロセスに `require`）・PicoRuby（複数 mrbgem を同一 picoruby バイナリにリンク）の両方で実機実証済み。唯一の既知の残存制限は `c` target で2つの `.a` を直接リンクするケース（`sp_ctx_swap` が生アセンブリのシンボル名でハードコードされておりリネーム不可、spinel 自身の GC フィボナ根マーキングが無条件にこれを要求するため衝突）。

---

## 11. spinel への依存ポリシー

suppify は spinel に対して **git レベルの依存を持たない**（submodule / subtree / vendoring いずれも禁止）。spinel は `cc` と同じ「インストール済み外部ツール」として扱う。

- **実行時**: `spinel` バイナリと spinel の `lib/`（`sp_runtime.h` / `libspinel_rt.a`）を PATH / 環境変数 / `--spinel-bin` `--spinel-lib` で発見する。suppify は spinel のコピーを一切同梱しない。
- **テスト / CI**: spinel ソースは **ephemeral な pinned clone**（gitignore した tmp ディレクトリへ tag 指定で clone → `make` → PATH に配置）でのみ用意する。§8 の version matrix ＋ master カナリアがこれを駆動する。suppify repo の依存ではなく CI のプロビジョニング手順。
- **生成物（consumer 向け）は自己完結**: 出力バンドル = `lib<name>.a` ＋ **コピーした `libspinel_rt.a`** ＋ 中立 header。生成物を使う側（Swift / PicoRuby / ESP32）は spinel インストール不要。
- **バージョン結合の明示**: suppify は parse によって spinel の出力形式に結合するため、「動作確認済み spinel バージョン一覧」をデータとして保持し、実行時に `spinel --version` を soft check して未検証バージョンなら warn する（git 依存ではなくデータ）。

## 12. 実装言語・ビルド・配布方針

- **実装言語: Ruby、spinel supported subset 準拠**。suppify 自身を spinel でコンパイルして 1 つの native バイナリにするため、suppify ソースは spinel が AOT できる subset に収める。
- **避ける機能**（spinel 非対応・`docs/limitations.md`）: `eval` / reflection / `method_missing` / runtime `define_method` / `ObjectSpace` / `Marshal`。`JSON.parse` も無いため、**symbols.json 用の最小 JSON パーサを subset 準拠で自作**する（`JSON.generate` は組み込みで使える）。subprocess は backtick `` `cmd` `` ＋ `$?`、stderr は `2>&1` リダイレクトで捕捉。`require "optparse"` / `require "set"` は spinel の stub が使える。
- **prism 依存**: app.rb の可視性判定に prism を使う（§5）。CRuby テスト層は `prism` gem、spinel-native バイナリは **libprism を C リンク**（spinel 自身が parse に使う C ライブラリ。Ruby インタプリタは不要、parser を 1 本リンクするだけ）。
- **CLI**: `suppify app.rb -o <name>` のみ。公開面を指定するフラグ（`--export` 等）は持たない — 公開面はソースの可視性（§5）で決まる。
- **配布方針**: prebuilt バイナリは配らない（out of scope）。**usage = 利用者が `spinel suppify.rb -o suppify` でビルドし、その native バイナリを使う**。CRuby ランタイムでの実行 fallback は提供しない（CRuby は §9 のテストのみ）。
- **テスト依存**: test-unit を bundler で repo ローカル（`vendor/bundle`）管理。テストコード自体は CRuby 上で動けばよく subset 制約を受けないが、被テストの suppify 本体ソースは subset 準拠を保つ（§9(2) の spinel ビルド E2E がこれを CI で強制する）。

## 13. ターゲットエミッタ（中立コア上のパッケージング層）

中立 C ライブラリを土台に、consumer エコシステム向けの成果物を出す層。`--target` で選ぶ。全ターゲットは spinel→中立 C のコア（同じ `.rbs`・対応型・エラー規約）を共有し、違うのは生成するバインディングとパッケージング形式のみ。設計の要は **suppify がクロスコンパイルしない**こと: gem ターゲットは「生成 C ＋ spinel ランタイムの**ソース** ＋ 言語バインディング」を同梱し、consumer 自身のビルドがそのツールチェーン・フラグでコンパイルする。ゆえに ABI が常に一致し、ESP32/iOS などへのクロスは consumer のビルドが対応する範囲で自動的に効く。

実装済み・実機実証済みのターゲット:

1. **`c`（既定）**: 自己完結の `lib<name>.a`（spinel ランタイムを再コンパイルして同梱、namespace 化済み）＋ 中立ヘッダを、ここでホスト `cc`/`ar` でコンパイル。ホスト arch 専用。
2. **`cruby`**: CRuby ネイティブ拡張 gem（`extconf.rb` + `.gemspec`）。`gem build` / `require` で、AOT 化されたメソッドが通常の Ruby メソッドとして呼べる。`test_cruby_target_integration` で mkmf ビルド→呼び出しを実証。
3. **`picoruby`**: PicoRuby/mruby mrbgem（`mrbgem.rake` + `src/`）。`conf.gem gemdir:` で組み込む。`test_picoruby_target_integration` で実 picoruby ホストビルド→`picoruby` バイナリからの呼び出しを実証。

各ターゲットで、export したトップレベルメソッドは書いたとおりの呼び出し（`add(2, 3)`）で C / CRuby / PicoRuby から呼べる。

**複数ライブラリ同居**: `SymbolPrefix`（§10）が spinel ランタイムの全シンボル（`nm` で実発見、約600個）と suppify 自身の固定名 API（`sp_lib_init` 等 → `<name>_init` 等に Ruby 側で直接改名）をライブラリごとに namespace 化。CRuby・PicoRuby の両方で複数ライブラリ同居を実機実証済み（`c` target の直接2アーカイブリンクのみ `sp_ctx_swap` の既知の制限が残る）。

後続（未実装）:

- インスタンス/クラスメソッド・非スカラー境界のエクスポート（opaque handle 設計が必要）。
- Swift ターゲット: 中立ヘッダを module map で直接 import（Swift は C を直接呼べるため薄い）。他言語（Python 等）も同じ継ぎ目に追加可能。
- ESP32/iOS 実機（on-device）での実行検証。現状の実証はホストビルドまで。

---

## 付録: 確認済みの spinel 事実（根拠）

- 生成関数は本番ビルドで `static`（`src/codegen.c:360`）。同一 TU 内からは呼べる → トランポリンを app.c に追記する根拠。
- C シンボル命名は決定論的: `sp_<name>` / `sp_<Class>_<name>` / `sp_<Class>_s_<name>`（`src/codegen.c:344`）。
- `main()` は init（`SP_GC_SAVE` / `sp_re_init` / srand / トップレベル文）を内包（`src/codegen.c:2918`）→ rename で再利用。
- 例外機構: `sp_exc_stack` グローバル + `sp_exc_arm`/`sp_exc_disarm`（`lib/sp_runtime.h:5214`）で per-call setjmp バリアが runtime 無改変で可能。
- runtime 依存: libc + malloc。ucontext は Fiber のみ（aarch64/x86_64 は register-save asm で ucontext 不要、`lib/sp_fiber_ctx.h:26`）。iOS arm64 は素直、ESP32 は Fiber 不使用なら可。
- 既存 metadata 出力フラグ: `--emit-symbol-map`（PR #1345 merged）/ `--emit-rbs`（#1276）/ `--emit-types`。`--emit-lib` 系 PR は存在しない。
- Issue #1367（OPEN）: "library consumption needs a stable package identity" — 上流もライブラリ消費を未解決論点として認識。

### 付録の訂正（実機 `https://github.com/matz/spinel`（master）で検証・上記の一部を上書き）

- **`-c` と `--emit-symbol-map` は組み合わせ不可（排他モード）**: 上記「PR #1345 merged」は `--emit-symbol-map` 単体の存在は正しいが、`-c -o X --emit-symbol-map` は `X` に symbol-map JSON が書かれ **C ソースは生成されない**（`src/main.c`: emit モードが `-c` 分岐より先に early return する）。suppify は `-c` と `--emit-symbol-map` を別々に呼ぶ（§6 手順 2）。
- **whole-program DCE は可視性を見ない**: `src/analyze.c: compute_reachable` はトップレベルスコープ・`initialize`・一部暗黙呼び出し名のみを root とし、呼ばれないトップレベルメソッドは public でも生成 C から消える。§5.1 の対処（RBS シード付きダミー呼び出し注入）が必要。
