---
title: プロジェクト形式の設計（View / .qgs / 共有単位）
tags: [technical, design, qgis, geopackage, drive, 設計思想]
---

# プロジェクト形式の設計

2026-08-21 の設計討議の結論。段1〜4は実装済み（[[#実装順序]] 参照）。
経緯は Vault の 決定事項_2026-08-21 / 競合調査_2026-08-21。

## 設計思想

### 1. 正典は dir 構造と `.kmeta.json`。それ以外は生成物

> [!WARNING] 2026-09-06 に方針転換。容器は `.kmeta.json` から `<dir名>.qgs` へ移す
> 設計は下の「正典を `.qgs` に移す」。この節の「`.qgs` は生成物」は移行完了までの現状説明として残す。

```
正典（authoritative）        生成物（derived）
  実在のディレクトリ構造        project.qgs
  .kmeta.json                  gpkg内の layer_styles（採るなら）
  .gpkg のデータ
```

> [!IMPORTANT] `.qgs` は生成物であって、正典ではない
> いつでも dir 構造 + `.kmeta.json` から**再生成できる**。この性質があるから、
> QGISプロジェクト形式という他人のフォーマットを書いても重さを負わない。
> ビルド成果物として扱う。
>
> ⚠ **QGIS側で `.qgs` を編集しても、次の生成で上書きされる。**
> QGIS側の変更を取り込みたい場合はインポータの仕事（別経路・別ルール）。

### 2. こかげマップ が提供する価値は「実在のdir構造に準拠した拘束条件」

QGISのレイヤツリーは**ファイルシステムから独立**していて、任意の階層に任意の場所の
レイヤを並べられる。その自由度が「同じテーブルを指すレイヤが5枚並ぶ」ような
散らかりを生む。

こかげマップ は自由度を捨てて**dir構造に縛る**。これが提供価値。

### 3. 書くときは厳格に、読むときは寛容に

- **書く**: こかげマップ が出すものは規格に厳密に沿わせる（QGISでそのまま開ける）
- **読む**: 他人が作ったファイルは多少崩れていても読む
  （旧形式の `id` 主キー、ST_トリガー付きのgpkg 等）

⚠ 「アプリのためにデータ制約を多くする」方向は、**開けるファイルを選り好みする**
アプリに近づく＝[[../features/concept|コンセプト]]の「前提条件の少なさ」と逆を向く。
厳格さは**変換の入口（インポート）と出口（エクスポート）**に置き、
「開けるかどうか」には持ち込まない。

### 4. 一方向は簡単、逆は規則で潰す

> **こかげマップ → QGIS は無損失。QGIS → こかげマップ は飲み込めるぶんだけ取り込み、
> 飲めなかったものは必ず報告する。**

## View の導入

### いま

```
Folder → GeoPackage → Layer → Feature
```

`Layer` が「データソースへの参照」と「見せ方（フィルタ＋スタイル＋ラベル）」を
兼ねている。QGISの「レイヤ」も同じ混同を持っており、それが散らかりの原因。

### これから

```
Folder → GeoPackage → Layer → View → (Feature は Layer に属する)
```

**View = 親 Layer に対する「フィルタ＋スタイル」の集合体。**

- 同じ Layer に対して**複数の View を作り、同時に表示できる**
- View ごとに show/hide を持つ
- **同一 Layer 内でのみ**並べ替えできる
- View は自分の Layer の下から動けない（＝dir構造の拘束が保たれる）
- Feature は Layer に属する。View は見せ方であってデータではない

> [!NOTE] z順のルール
> **(dir由来の Layer 順) → (Layer 内の View 順)**。
> View の並べ替えを同一 Layer 内に限ることで、z順は常に dir 構造から決定できる。

### なぜ View が必要か

**QGISプロジェクトのインポートで、最大のロスが消える。**

QGISでは同じgpkgレイヤを別スタイル・別フィルタで何枚も置くのが普通。
View が無いと「1枚選んで残りを捨てる」しかないが、View があれば
**N枚のQGISレイヤ → N個の View** で無損失に受けられる。

## こかげマップ ↔ QGIS の対応

| こかげマップ | QGIS (`.qgs`) |
|---|---|
| dir | レイヤグループ |
| GeoPackage | レイヤグループ |
| Layer | レイヤグループ |
| **View** | **レイヤ**（`maplayer` + `layer-tree-layer`） |

View だけが QGIS のレイヤになり、それ以外は全てグループ。**1:1 対応**が成立するので、
`.qgs` を書いても破綻しない。

書く範囲は使う部分だけでよい（レイヤツリーのグループ、gpkgデータソース参照、
subset string、レンダラ）。QGISプロジェクトXMLは巨大だが、部分だけでもQGISは開ける。

## View の実装（2026-08-26）

### 置き場所

`ViewNode` は**親 Layer の `children` に入れていない。** `LayerNode.views` という
別のリストに持ち、`parent` だけ Layer を指す。

理由は実務的なもので、`LayerNode.children` がコードベース全体で
「FeatureNode の集まり」として扱われているため（`children.cast<FeatureNode>()` を
書いている箇所すらある）。そこに別種を混ぜると踏み抜く。
「View は見せ方であってデータではない」という設計とも、この置き方は合う。

可視性の再帰（`isVisibleRecursive()`）は `parent` を辿るので、`children` に
居なくても正しく効く。

### 既定View

View定義を持たないレイヤは、**「既定」という名前の View を1枚だけ暗黙に持つ**。
これは `.kmeta.json` には書かない。書くと全プロジェクトに差分が出て
Drive同期が無駄に動くため。UI も「既定1枚だけ」のレイヤには View 行を出さない
（View 導入前と同じ見た目になる）。

View を2枚目以降にした時点で、既定View も含めてファイルに書かれる。

### フィルタの効き方

表示中の View のフィルタを **OR で束ねて** `SELECT ... WHERE` に渡す
（`LayerNode.activeViewFilter`）。

- View は「同じレイヤを別の条件で何枚も見せる」ものなので、見えているぶんの**和**が出る
- フィルタを持たない View が1枚でも見えていれば、全件が出る（WHERE無し）
- View を全部消灯したレイヤは、レイヤ自体が可視でも何も描かない

> [!WARNING] フィルタは文字列としてSQLに埋め込まれる
> 条件式そのものなのでバインド変数にはできない。ユーザーが書いたものを
> そのまま通す QGIS と同じ設計だが、**`.kmeta.json` は Drive経由で他人から
> 届きうる**。文の切り替え（`;`）だけは弾いてある
> （`FeatureRepository.sanitizeFilter`）。

### スタイルの効かせ方（段4b・2026-08-26）

**ソースは共有したまま、スタイルレイヤだけを増やす。** データ転送は増えない。

1. `LayerNode.refreshStyleGroups()` が「どのフィーチャがどのスタイルの
   ものか」を決める。表示中の View を上から見て、**最初に当たった View が勝つ**
   （フィーチャは1つのスタイルでしか描けないので、z順の考え方と揃えた）。
   フィルタ付き View の所属は `SELECT <pk> ... WHERE <filter>` で引く
   （ジオメトリを読まないので軽い）
2. 各フィーチャの GeoJSON に `k-style` 属性としてグループのキーを載せる
3. `MapSourceManager` がグループごとに
   `filter: ['==', ['get','k-style'], key]` のスタイルレイヤを積む。
   既定スタイルのレイヤには「どのグループにも属さない」フィルタが付く

> [!IMPORTANT] 固有スタイルが1つも無ければ、この仕組みは丸ごと眠る
> `styleGroups` が空なら `k-style` 属性も載せず、フィルタも付けない。
> 描画経路は View 導入前とまったく同じになる。
> 既存プロジェクトの見え方を変えないための保険。

> [!WARNING] クラスタリング経路は属性を手で写している
> `k-points` はクラスタリングが有効なとき
> `MapSourceManager.clusterPointJson()` の出力で作り直される。
> ここに属性を写し忘れると、**クラスタリングが有効なときだけ
> View のスタイルが効かない**という分かりにくい壊れ方をする
> （2026-08-26 に実際に踏んだ。回帰テストあり）。

副産物として、**レイヤ単位のスタイル設定が初めて描画に効くようになった**。
UIは前からあったが、描画側が見ていなかった。

### まだできていないこと

- **z順が dir 構造どおりにならない。** 共有ソース1本という作りの制約で、
  レイヤ間の前後は表現できない。保証できるのは「固有スタイルのフィーチャは
  既定スタイルより前面」まで。View の並べ替えも保存だけで描画には出ない
- 選択・頂点・クラスタの見た目はグループ別にできない（全体で1組のまま）

## 共有の単位は「dir」

> [!IMPORTANT] Drive連携は**プロジェクト単位ではなくフォルダ単位**
> `KMetaSync` が `driveId` / `driveUrl` をフォルダごとに持つ。
> ツリー内の任意のフォルダを個別に連携できる。

この性質と `.qgs` が噛み合う。**Drive連携dirは、それ自体が自己完結した共有可能な単位**になる。

```
Drive連携dir/            ← 共有の単位。QRで配れる
  project.qgs            ← こかげマップが生成。QGISでそのまま開ける
  .kmeta.json            ← アプリ限定設定（正典）
  林小班.gpkg
  路網.gpkg
  写真/
```

このdirを同期した人は、データ・スタイル・プロジェクトファイルを全部受け取る。**サーバ不要。**

- **web →（QR）→ Android**: 現場に渡す
- **Drive dir → QGIS**: 事務所で `.qgs` を開く
- 逆方向は `.kmeta.json` と dir 構造が正典なので崩れない

⚠ `.qgs` の置き場所は**連携dirごと**が筋（連携dirを単体で渡された人が、そのdirだけで開けるべき）。
生成タイミングは Drive push の直前が自然。

### QRによる受け渡し

**受け側は既に実装済み。** `mobile_scanner` が依存に入っており、
「DriveフォルダのURLを入力するか、QRコードをスキャン」というUI文言もある。
`SyncEngine.cloneFromDrive()` も実装済み。

出す側も 2026-08-26 に実装した（`lib/widgets/dialogs/drive_qr_dialog.dart`、
`qr_flutter`）。Drive連携フォルダの行にQRボタンが出る。**web でも出る**。

> [!NOTE] 2026-08-28 に web 版の Drive 連携は完成した（`supportsDriveSync` は web OAuth クライアントがあれば真）。下の警告は当時の記録

> [!WARNING] ただし web版はDrive連携を「作れない」
> `PlatformCapabilities.supportsDriveSync` はモバイル限定のまま。
> いま web でQRを出せるのは「モバイルで連携済みのフォルダを開いたとき」だけで、
> 「事務所（web）で一から作って現場に渡す」には web版のGoogle認証が要る。
> ここが段7の残り。

## QGISプロジェクトのインポート（寛容側）

一度読んで変換して捨てる **インポータ**。`.qgs` を正典として持たない。
既存の `lib/services/import_export/importers/` に1本追加する形。

ルール:

1. **root外への参照は丸ごと捨てる。** `C:\work\data.shp` やPostGIS接続を指すレイヤは
   山の中のスマホでは開けない。残すと「レイヤはあるが表示されない」最悪の状態になる
   - ⚠相対パスで root 外を指すケース（`../shared/kyoyu.gpkg`）は林業では現実にありそう。
     判定は**正規化した絶対パス**で行う
2. **レイヤ構造は dir 構造に置き換える。** QGISのグループ階層は採らない
   - 選択肢: グループ階層を**dirとして実体化**する（gpkgをグループ構造に沿ったdirへ配置）。
     ルールを保ったまま意図も保てるが破壊的。第1版は「捨てる」でよい
3. **生き残った参照のスタイルは View として再利用する**
4. **捨てたものは必ず報告する。** `NotificationCenter` に出す

> [!WARNING] 捨てるのはいい。黙って捨てるのがまずい
> ```
> 林小班.gpkg / rinshoban に3つのQGISレイヤが対応していました。
> 「林小班（現況）」を採用し、2つを破棄しました。
>   - 林小班（伐採予定）  root外を参照
>   - 林小班（ラベルのみ） 重複
> ```

## 実装順序

> [!IMPORTANT] web版が全ての前提
> ここで設計したものは**事務所側＝web版**を前提にしている。
> `.qgs` を Windows版で書いてもQGISで開けるだけで、共有の絵にならない。
>
> さらに、`File`/`Directory` 173箇所をファイルシステム抽象に通す作業は
> `.kmeta.json` もGeoPackageアクセスも通る。**View を足してから抽象化すると
> 対象が増えて手戻りになる。**

| 段 | 内容 | 状態 |
|---|---|---|
| 1 | **web: 起動して地図が出るまで**（`Platform.is` 30箇所を capability に集約 / TileServer を web で起動しない） | **完了**（2026-08-24） |
| 2 | **web: ファイルシステム抽象** + File System Access API | **完了**（2026-08-25） |
| 3 | **web: GeoPackage を WASM SQLite に** | **完了**（2026-08-25） |
| 4 | **View の導入** | **完了**（2026-08-26）。スタイル・フィルタとも描画に効く。⚠ z順は未対応 |
| 5 | **`.qgs` ライター** | **完了**（2026-08-26）。⚠ QGISでの実開封は未検証 |
| 6 | `.qgs` インポータ（寛容・root外破棄） | **完了**（2026-08-26）。⚠ QGIS製ファイルでは未検証 |
| 7 | web側のQR発行（受け側は実装済み） | QRを出す口は完了。⚠ web版のDrive連携が残り |

⚠ **`layer_styles`（gpkg内スタイル）の優先度は下がった。**
`.qgs` にレンダラを書けばQGISはそれで読むので冗長。
「gpkg単体を渡された場合」の保険としてのみ意味がある。

## 検討中の論点

- **View の名前。** GeoPackage/SQLite には本物のSQLビューがある。
  各Viewをgpkgの**SQLビューとして登録**する案（QGISから独立レイヤとして同時表示できる）を
  採る可能性があるなら、アプリ側の概念は別名にしたほうがよい（`表示` / `スタイルセット` / `レンズ`）
  - ⚠SQLビュー経由はQGIS/GDALで**編集不可**になる。またユーザーのgpkgに構造物を追加する
- **性能。** View が増えるとスタイルレイヤが倍える。
  **同じGeoJSONソースを共有してスタイルレイヤだけ増やす**設計にすればデータ転送は増えない。
  `integration_test/benchmark/` で測れる
- 影響範囲: `map_source_manager.dart`（1086行）が本丸。
  `.kmeta.json` のキーが `layerName` → `layerName/viewName` になる

## 正典を `.qgs` に移す（2026-09-06 決定・設計）

> [!IMPORTANT] 上の「正典は dir 構造と `.kmeta.json`」を置き換える
> `.kmeta.json` をやめ、**dir ごとの `<dir名>.qgs` を正典**にする。
> 「変換器を内部に持つ手間」より「QGIS とシームレスに行き来できる」ほうが
> [[../features/concept|コンセプト]]（前提条件の少なさ）に沿う。プラグインも変換操作も要らない。
> クローズドテスト中で `.kmeta.json` の利用者がほぼ居ない今が、切り替えの最安値。
>
> 「dir 構造が正典」「書くときは厳格に、読むときは寛容に」「一方向は簡単、逆は規則で潰す」の
> 3原則は**そのまま生きる**。変わるのは容器だけ。

### 配置: dir 分散のまま、容器を `.qgs` にする

```
Kitayama-2026/
  Kitayama-2026.qgs      ← この dir の正典。自分のレイヤ＋子 dir の埋め込み
  林小班.gpkg
  写真/
    写真.qgs             ← 子 dir の正典。単体で持ち出しても QGIS で開ける
    IMG_0001.jpg
```

- **ファイル名は `<dir名>.qgs`**。`.kmeta.json` と同じ場所・同じ粒度（設定を持つ dir にだけ置く）
- **子 dir は QGIS の埋め込み機能で親に載せる**。`layer-tree-group` に `embedded="1"`
  `embedded_project="./写真/写真.qgs"` を書くと、QGIS は親を開いたとき子プロジェクトの
  グループを読み込んで表示する（`QgsLayerTreeUtils` が読み書きする正規の属性。
  パスは相対で書く）。これで「root を開けば全部見える」と「サブ dir 単体で開ける」が
  **1種類のファイルで両立**する。統合版を別に生成して二重化しない
  - ⚠ 埋め込まれたグループは QGIS 側で**読み取り専用**（スタイルを変えるには子の `.qgs` を開く）。
    dir の所有権と一致するので、これは仕様として受け入れる
  - 一枚に平坦化した編集用 `.qgs` が欲しい人向けに、**派生物として書き出す口**だけ残す
    （メニューから。読み戻しは datasource のパスで所属 dir が決まるので分配できる）
- **`.qgz` は読むだけ、書かない**。QGIS の既定保存形式は `.qgz`（zip 内に `.qgs` と補助 DB `.qgd`）
  だが、`.qgs` を開いて Ctrl+S すれば `.qgs` のまま保存される。`.qgz` が置かれていたら
  「他人が作ったファイル」として一度読み、`.bak` に退避する

### 不変条件（7条）

1. **1 dir = 1 `<dir名>.qgs`**。dir 名と一致する `.qgs` が無いときは、**自分の印（下の
   ウォーターマーク）を持つ `.qgs`** を探し、あればその `dirName` が旧 dir 名＝改名の痕跡なので
   ファイル名を追従させて採用する。印を持つものが無ければ新規に作り、他の `.qgs` は触らない。
   どちらも報告する
2. **レイヤツリー = dir 構造**。読み込み時に正規化する。dir 外参照（絶対パスは正規化して判定）・
   サポート外のデータソース・dir 構造に合わないグループは除外し、元ファイルは `<dir名>.qgs.bak`
   に退避してから書き直す。**黙ってやらない**（`NotificationCenter` に何を捨てたか出す）
3. **理解しないノードは触らない**。印刷レイアウト・リレーション・スナップ設定・未知のレンダラなど、
   自分のモデルに無いものは XML のまま保持して書き戻す。書き出しは「ゼロから生成」から
   **DOM 保持型の部分更新**に変わる
4. **表現できないスタイルは読み取り専用**。アプリのスタイルモデルは単一シンボル＋簡易ラベルだけ。
   分類・ルールベース・データ定義などはアプリで「QGIS で設定されたスタイル」と表示し、
   既定の見た目で描き、XML は保持する。アプリのスタイル編集で上書きしない
5. **メモリが正、ディスクは遅延書き込み**。QGIS がそうしているように（保存は Ctrl+S だけ、
   `.qgs~` にバックアップ）、DOM をメモリに持ち、変更後 2 秒のデバウンスと
   バックグラウンド移行・dispose で書く。一時ファイルに書いてリネーム（原子的）、
   直前の版を `<dir名>.qgs~` に残す。書く直前に mtime を見て、ロード後に他者が
   書いていたら読み直してマージする。web は rename が無いので直接書く（下の矛盾5）。
   Drive push と書き出しの前には必ず flush する
6. **アプリ限定の情報は名前空間に隔離**。同期情報・スキーマ版・オーバーレイの変換パラメータは
   プロジェクトの `<properties>` とレイヤの `<customproperties>` の `kokage/...` に置く。
   QGIS は保存時にこれらを保持する
7. **マージの単位は maplayer と tree ノード**。テキスト行ではなく id で対応づけて 3-way マージする。
   構造は dir が勝ち、見た目は新しい方が勝ち、決められないものは両方残して報告する。
   `.kmeta.json` でも本来同じ仕事が要るので、XML だから難しくなるわけではない

### ウォーターマーク（最後に書いたのは誰か）

QGIS は root 要素に `version` `saveDateTime` `saveUser` `saveUserFull` を書き、保存のたびに
上書きする。これが QGIS 側の印。アプリは `properties/kokage/` に自分の印を持つ
（QGIS は保存時に未知の properties を保持する）。

```xml
<qgis version="3.44.12-..." saveDateTime="..." saveUser="...">   <!-- QGIS の印 -->
  <properties>
    <kokage>
      <schemaVersion>1</schemaVersion>
      <app>kokage-map 0.6.1+18</app>
      <savedAt>2026-09-06T12:46:13Z</savedAt>
      <savedBy>deviceId</savedBy>
      <dirName>写真</dirName>
      <contentHash>書いた時点のファイルのハッシュ（この要素を除く）</contentHash>
    </kokage>
  </properties>
```

読み込み時の判定:

| 状態 | 判定 | 扱い |
|---|---|---|
| ハッシュ一致 | 最後に書いたのは自分 | そのまま読む（正規化なし） |
| 不一致・`saveDateTime` > `savedAt` | QGIS が後から保存した | 寛容モード（正規化＋報告）。マージでは見た目は QGIS 側が新しい |
| 不一致・それ以外、または `kokage` が無い | 手編集か他人のファイル | 寛容モード。元は `.bak` に退避 |
| `dirName` ≠ 現在の dir 名 | dir 改名の痕跡 | ファイル名を追従させて採用（1条） |

`savedBy` で別端末の変更が分かるので Drive 同期のマージに使える。`schemaVersion` で旧版アプリの出力を読み替える。

### `.kmeta.json` → `.qgs` の対応

| `.kmeta.json` | `.qgs` の置き場所 | 備考 |
|---|---|---|
| `visibility.folders/geopackages/layers` | `layer-tree-group@checked` | dir/gpkg/Layer はグループ |
| `visibility.views` | `layer-tree-layer@checked` | View が QGIS のレイヤ |
| `visibility.images` | `properties/kokage/images/<名>/visible` | 写真はレイヤを持たない（QGIS には出ない）。オーバーレイだけラスタレイヤ |
| `layout.sortOrder` / `expanded` | 子要素の並び / `@expanded` | `<layerorder>` も同じ順で書く |
| `views[*].filter` | `maplayer/subsetString` | 現行どおり |
| `views[*].style` / `styles.layers` | `maplayer/renderer-v2`（single symbol） | 解決済みの値を各レイヤに書く |
| `styles.layers.label*` | `maplayer/labeling type="simple"` | **現行未対応。ここで足す** |
| `styles.defaultStyle` と継承チェーン | 廃止 | 各レイヤに解決済みの値を書く。既定値はアプリ設定だけ（下の矛盾1） |
| `imageOverlays` | ラスタ `maplayer`（gdal・GeoTIFF）＋ `customproperties/kokage/overlay/*` | **現行未対応**。GeoTIFF は既に生成している |
| `sync.driveId/driveFolderName/driveUrl/isReadOnly` | `properties/kokage/sync/*` | リンク情報だけ |
| `sync.files/lastSynced/driveRevisionId/deviceId` | **共有ファイルには置かない** | アプリ私有領域 `AppSupport/sync/<driveId>.json`（下の矛盾3） |
| `version` | `properties/kokage/schemaVersion` | 印（`savedAt` `savedBy` `dirName` `contentHash`）も同じ場所 |
| 既定 View（暗黙の1枚） | **書く**（Layer グループ直下の maplayer 1つ） | QGIS はレイヤが無いと描けない（下の矛盾2） |

### 読むときの寛容さ（インポータの仕事がその場で走る）

- 既存の `qgs_importer` のルール（root 外破棄・グループは dir 構造に置換・捨てたものは報告）を
  **ロード時の正規化**として実行する。「一度読んで捨てる」から「読んで直して書き戻す」に変わる
- QGIS が保存時に datasource を絶対パスに書き換えることがある（プロジェクトの「パス: 相対」設定次第）。
  正規化して root 内なら相対に戻す
- `<qgis version>` は QGIS が上書きする。アプリはこれより新しい版を拒まない

### 移行

- dir を開いたとき `<dir名>.qgs` が無く `.kmeta.json` があれば、既存の `QgsProjectBuilder` で
  生成して書き、`.kmeta.json` を `.kmeta.json.migrated` に改名する（1世代だけ残す）
- 両方あれば `.qgs` が勝つ。`.kmeta.json` は無視して警告
- Drive 同期は「メタデータファイル」の対象を `.kmeta.json` から `<dir名>.qgs` に変える。
  相手側が旧版アプリのときは `.kmeta.json` を受け取る側で読めるよう、読み手だけ当面残す

### 実装の勘所

- **`KMeta` クラスはアプリ向けモデルとして残し、永続化だけを差し替える**。`kmeta` を触る
  ファイルは 35 本あるが、`KMetaService` の裏を「JSON」から「DOM 保持型の `.qgs` 文書」に
  変えれば呼び出し側の大半は動かない。`QgsProjectBuilder` / `QgsWriter` / `QgsImporter` は流用
- QGIS 3.44 が書いた `.qgs` を `test/fixtures/` に持っているので、「QGIS が保存 → アプリが読む →
  アプリが書く → 未知ノードが残っている」を往復テストにする

### 実装順序

| 段 | 内容 |
|---|---|
| 1 | DOM 保持型の `QgsDocument`（読む・自分のノードだけ更新・書き戻す）。往復テスト |
| 2 | `KMetaService` の裏を `QgsDocument` に差し替え。`.kmeta.json` は読み手だけ残す（移行用） |
| 3 | 出力の穴埋め: ラベル・ラスタ化したオーバーレイ・展開状態・`<layerorder>` |
| 4 | 子 dir の埋め込み（`embedded_project`）。平坦化版は派生物として書き出し |
| 5 | Drive 同期の対象を `<dir名>.qgs` に。レイヤ単位の 3-way マージ |
| 6 | 移行・`.qgz` 読み・`.bak` 退避・報告 |
| 7 | 読み取り専用スタイルの UI（「QGIS で設定されたスタイル」） |

### 実装と突き合わせて見つかった矛盾と修正（2026-09-06）

`kmeta_service` / `sync_*` / `k_file_system_web` / `qgs_*` を読んで、上の設計と食い違う点を潰した。

**1. 継承チェーンは廃止する（ポータビリティと矛盾していた）**
`KMetaService._resolveInheritanceChain()` は root から dir を辿って親の `visibility`・`styles.defaultStyle`・
`layout` を子にマージしている。子 dir の見た目が親の `.kmeta.json` に依存する＝**サブ dir 単体を持ち出すと
QGIS で見え方が変わる**ので、「サブ dir 単体で開ける」という移行の主目的と正面から矛盾する。
`.qgs` は各レイヤに解決済みのレンダラを持つ自己完結ファイルにし、継承は捨てる。
dir 単位の `defaultStyle` は廃止し、既定値はアプリ設定（`layer_style_settings`）だけにする。
（`layout.sortOrder` / `expanded` まで親から継承しているのは元々意味が無い。`visibility` の継承は
同名の gpkg/レイヤが子 dir にあると勝手に効く事故の元で、これも切る）

**2. 既定 View は `.qgs` に書く（前の対応表は誤り）**
QGIS はデータを maplayer としてしか描けないので、View が暗黙の1枚だけのレイヤも
**maplayer を1つ持つ Layer グループ**として書く。「既定 View は書かない」は `.kmeta.json` の
差分抑制のための規則で、`.qgs` が正典になれば理由が消える。読むときは「View が1枚で名前が既定」を
暗黙 View と同一視する（`ViewNode.isDefaultView` がその判定）。
ネストが深く見える（gpkg グループ > Layer グループ > レイヤ）のは受け入れる。View が2枚になった
瞬間に構造が変わる方が、インポータとマージにとって扱いにくい。

**3. 同期の帳簿は共有ファイルから追い出す**
いまの `KMetaSync` は `driveId` などの**リンク情報**と、`files`（パス→driveFileId）・`lastSynced`・
`driveRevisionId` という**端末ごとの帳簿**を同じ場所に持ち、`deviceId` だけ剥がして Drive に上げている。
`.qgs` でこれをやると、push/pull のたびに `.qgs` が書き換わって印（ウォーターマーク）が濁り、
QGIS ユーザーには意味不明な巨大な `kokage/sync/files` が見える。
→ 共有ファイルに残すのは `driveId` `driveFolderName` `driveUrl` `isReadOnly` だけ。
帳簿は**アプリ私有領域**（`AppSupport/sync/<driveId>.json`）に移す。副産物として、端末相対の
`lastSynced` を他端末に配っている今のねじれも消える。
`<dir名>.qgs` 自体は普通の同期対象ファイルにできる（`deviceId` 剥がしが要らなくなる）。
ただし衝突解決だけは gpkg と違い、7条のレイヤ単位マージを通す。

**4. スキーマ更新でデータを捨てない**
`getRawMeta()` の版ゲートは「旧版なら `sync` だけ残して再保存」＝スタイルと View を黙って捨てる。
`.qgs` では `schemaVersion` を見て**読み替える**か、読めなければ `.bak` に退避して報告する。捨てない。

**5. 書き込み戦略はプラットフォームで分ける**
- native: 一時ファイルに書いて `rename`。直前の版を `<dir名>.qgs~` に残す
- web: File System Access API に rename は無い（`k_file_system_web.rename` は読んで書いて消す代用）。
  ただし `createWritable()` 自体が一時ファイル経由で原子的なので、web は**直接書く**。
  バックアップは「旧バイトを読んで `.qgs~` に書く」で作る
- web はライフサイクルの `paused` が当てにならず、`pagehide` で非同期書き込みを待てない。
  デバウンスは native 2 秒 / web 即時（または 300ms）に分ける
- **Drive push と `.qgs` 書き出しの前には必ず flush する**。push はディスクのファイルを読んで上げる
  （`_uploadKmetaFile` が `fs.readAsString` している）ので、メモリだけ新しい状態で上げると古いものが飛ぶ

**6. Global フォルダは独立した `.qgs`**
Global はプロジェクト root の外にあり、Drive 連携もできる（`GlobalDriveFolderNode`）。root の `.qgs` から
埋め込むと2条（root 外参照）に反するので、**`Global/Global.qgs` を単独で持ち、プロジェクト側からは
参照しない**。QGIS で GPS 軌跡を見たい人は `Global.qgs` を別に開く。

**7. 写真マーカーは QGIS に出ない。可視性は名前空間へ**
写真（`ImageNode`）はレイヤを持たないので QGIS では描けない。ラスタレイヤになるのはオーバーレイだけ。
`visibility.images` は `properties/kokage/images/<ファイル名>/visible` に置く。
（写真を点レイヤとして見せたければ派生の gpkg を生成する話で、別件）

**8. 現行の `.qgs` レイヤ id は web と native で一致しない（バグ）**
`QgsProjectBuilder._layerId()` が `viewKey.hashCode` を使っている。Dart の `String.hashCode` は
VM と dart2js で実装が違い、**同じ View に web と Android で別の id が付く**。正典にすると
同期のたびに全レイヤが「別物」になる。UTF-8 バイト列の安定ハッシュ（fnv/md5）に替える。
**段1より前に直す**（今の書き出し機能でも Drive 越しに差分を生む）。

**9. 埋め込みは group だけでなく maplayer のスタブも要る**
QGIS は埋め込みレイヤを `<projectlayers>` に `<maplayer embedded="1" project="..." id="..."/>` の
スタブとして書き、`layer-tree-group embedded="1"` の子要素は書かない（読込時に子プロジェクトから
再構成する）。DOM 保持型の書き出しは、子 dir の `.qgs` が変わるたびに親側のスタブを作り直す。
現行のインポータは `embedded` を知らないので、読む側では埋め込みグループを**自分の管轄外として
スキップ**する（子 dir の `.qgs` が正典）。

**10. レンダラも部分更新（3条・4条の補強）**
QGIS が保存した単一シンボルは、アプリが知らないプロパティ（アウトラインの破線、オフセット等）を
大量に持つ。アプリのスタイル編集で `renderer-v2` を丸ごと生成し直すとそれが消える。
自分が持つ値（色・サイズ・線幅・不透明度）だけを既存の symbol XML の中で差し替える。
簡易ラベルも同じ。

**11. 印は `saveDateTime` に寄せて単純化**
アプリが書くとき root の `saveDateTime` を `kokage/savedAt` と同じ値にする。読むときに両者が
一致すれば「最後に書いたのは自分」、違えば QGIS が後から保存した。`contentHash` は手編集や
破損の検出用に残すが、判定の主役にはしない。

**12. 既存の `project.qgs` と書き出し／取り込みメニューの扱い**
現行の `kQgsFileName = 'project.qgs'` で生成済みのファイルは新名に改名して引き継ぐ（実装済み）。
手動の「書き出し」「取り込み」メニューは **2026-09-06 に撤去した**。書きは自動追従、読みは
開いたときの読み戻しで足りる。平坦化版の派生物書き出しが要るなら、そのとき別メニューとして足す。

**13. 段2 の実装形: `.qgs` は `KMetaService` 単体では書けない（2026-09-06 実装中に判明）**
`.qgs` の maplayer には gpkg のジオメトリ種別と CRS が要り、それは `QgsProjectBuilder` が `LayerNode` を
辿って DB から引いている。`KMetaService.saveMeta(folderPath, meta)` は名前しか知らないので、
永続化を差し替えるだけでは `.qgs` を書けない。**書くのは `FolderNode` 側**（子を知っている）にし、
`KMetaService` はメモリ上の `KMeta` を持つだけ、`FolderNode.flushProjectFile()` が
`QgsProjectBuilder` + `QgsDocument` で書く、という分担にする。読む側は `QgsImporter` の
変換（`.qgs` → `KMeta` の views / styles / visibility）を `KMetaService` の読み込み口に載せる。

段0-a と段1 は 2026-09-06 に実装済み（`lib/services/qgis/qgs_document.dart`・`test/qgs_document_test.dart`）。
書き出しメニューは既に DOM 保持型の更新になっている。

**14. 到達点（2026-09-06 夕方）: `.kmeta.json` を残したまま両方向を繋いだ**
- 書き: `.kmeta.json` が保存されるたびに `<dir名>.qgs` を自動更新（`QgsAutoRefresh`）
- 読み: プロジェクトを開いたとき、印と `saveDateTime` が食い違う `.qgs` を寛容インポータで読み戻す（`QgsReadBack`）
- 子 dir: 自分の `.kmeta.json` を持つ dir は独立した `.qgs` ＋ 親への埋め込み
- 帳簿: `SyncLedger`（アプリ私有）へ分離。継承チェーンは廃止
- 残り: `KMetaService` の裏の差し替え（段2 完全形・`.kmeta.json` の廃止）、レイヤ単位マージ、平坦化書き出し、
  ラスタ化オーバーレイ、読み取り専用スタイル UI、QGIS での実開封

### 未決の論点

- **dir 改名の追従**。1条のルールで拾えるが、Drive 同期越しに改名が届いたときの挙動は未検討
- **埋め込みの深さ**。3階層以上の dir で QGIS の埋め込み解決が重くならないか（要実測）
- **web 版の書き込み**。File System Access API で `.qgs~` のリネームが同じ手で書けるか
- **写真 dir**。写真だけの dir に `.qgs` を置く価値があるか（オーバーレイがあればラスタレイヤとして見える。無ければ置かない）
- **3-way マージの base**。最後に同期した版の中身をアプリ私有領域に残すか、Drive の revisionId から取り直すか

## 関連

- [[../features/concept|コンセプト]]
- [[qgis-interop|QGIS相互運用]]（既に実装済みの後始末）
- [[location-sharing|位置共有設計]]
