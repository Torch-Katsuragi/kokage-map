---
title: QGIS相互運用
tags: [technical, geopackage, qgis, interop]
---

# QGIS相互運用

こかげマップ は「ユーザーの `.gpkg` をそのまま読み書きする」ことを identity にしている
（[[../features/concept|コンセプト]]）。変換もパッケージ化も要求しないのが競合に対する差なので、
**編集して返したファイルが QGIS で普通に開けること**が要件になる。

ここは「編集中には邪魔だが QGIS 側では必要」というものの面倒を見る仕組み。
実装は `lib/models/geopackage/qgis_interop.dart`、テストは `test/qgis_interop_test.dart`。

## `.qgs` はいつ書かれるか（2026-09-06）

- フォルダ設定が保存されるたび（可視性・スタイル・View・並び順の変更。設定そのものは `kokage/meta` に即座に書く）、3秒のデバウンス後に
  root の `<dir名>.qgs` を `QgsAutoRefresh` が DOM 保持型で更新する
- ツリーの子の顔ぶれ（フォルダ・gpkg・外部形式・画像・レイヤ）が変わったときも同じデバウンスで更新する
  （`LayerTreeNode.onStructureChanged` → `QgsAutoRefresh.scheduleFor`、2026-10-11）。gpkg への変換・削除・改名・
  移動・ファイルの追加・移動で空になった gpkg の削除が該当。合図は `addChild` / `removeChild` / `dispose` /
  `syncChildren` で出るので、子を付け外しするときは `children` を直接いじらない。地物と View の増減は数えない。
  `syncChildren` は並びも読み直した順（開き直したときと同じ）にそろえる（以前は足した子を末尾に積んでいた）。
  ⚠ 以前は設定の保存だけが合図で、鍵を持たないレイヤを変換すると `.qgs` が元のファイルを指したまま開き直すまで残った
- Drive push の直前に `flushNow()` で待ちを消化する
- プロジェクトを開いたら一度書き直す（中身が同じなら書かない。無ければ最初の1本、`.kmeta.json` から移した直後なら QGIS の部分がそろう）
- 手動の「QGISプロジェクトを書き出す／取り込む」メニューは 2026-09-06 に撤去した（自動追従と読み戻しで不要）
- 失敗は logcat の `[QgsAutoRefresh]` に出るだけで通知しない（手動書き出しで再現できる）
- **逆方向**: プロジェクトを開いたとき `QgsReadBack` が root と子 dir の `.qgs` を見て、印（`kokage/savedAt`）と
  root の `saveDateTime` が食い違えば（＝QGIS が後から保存した）寛容インポータで View・スタイル・可視性を
  取り込み、続く自動更新で正規化＋印つきに書き戻す。ログは `[QgsReadBack]`。
  Drive 同期でツリーを読み直したあとにも走る（`DriveSyncOperations.refreshAfterSync`、2026-09-29）
- **子 dir**: 自分の設定（`.qgs`）を持つ子 dir は `<子dir名>.qgs` を持つ。どの `.qgs` にも子孫の dir の
  レイヤが平らに写される（2026-09-30 に埋め込みをやめた。どの dir を QGIS で開いても下が全部直せる）。
  持ち主はデータソースの置き場所の dir。読み戻しは QGIS で保存された `.qgs` を古い順に取り込み、
  持ち主のほうが新しい（印の savedAt が後）写しは飛ばす

## いつ走るか

`GeoPackageFile.dispose()` の中、**全ての書き込みが終わったあと・DBを閉じる直前**。

```
dispose()
  ├ flushChanges()              保留中の変更を書ききる
  ├ clearPendingChanges()
  ├ _finalizeForQgis()          ← ここ
  │   ├ QgisInterop.syncAllLayers()   範囲と件数を実データに合わせる
  │   └ qgisInterop.restoreTriggers() SpatiaLiteトリガーを戻す
  └ _connection.dispose()
```

> [!WARNING] トリガー復元は必ず最後
> 復元後に書き込むと、sqflite に `ST_IsEmpty` 等が無いため落ちる。
> 順序を入れ替えないこと。

### 閉じずに外へ出すとき（2026-10-12〜）

`dispose()` を待たずにファイルが端末の外へ出る場面がある。Drive へ上げる（push・マージの「端末を採用」・行単位マージのあと）、
3-way マージの base に写す、アプリが裏に回る（同じ端末の QGIS・USB で写す・裏で止められる）。
地図を開いている間はプロジェクトのツリーが `GeoPackageFile` を持ち続けるので、`dispose()` の整合だけでは
上がったファイルの rtree に足した地物が無く、トリガーも落ちたままだった（Pixel 9 で `ogrinfo -spat` が 0 件）。

`GeoPackageFile.prepareForHandOff(path)` がその前に同じ整合をする（`SyncBaseStore.prepareForUpload`・`saveBase`・`main.dart` の paused/hidden/detached から）。

```
prepareForHandOff(path)        パスごとに 1 つずつ
  ├ BackgroundSaveManager.flushChangesFor(path)
  ├ 書いていない・控えも無い → 何もしない（見ただけのファイルを変えない）
  ├ rtree も控えも無い（アプリ製・GPS の記録）→ 何もしない（接続も閉じない）
  ├ GeoPackageConnection.closeAllFor(path)
  ├ 別の sqflite 接続で syncAllLayers()・restoreTriggers()
  └ GpkgIndexRepair.rebuildFile(path)（書いたときだけ。開き直した接続があれば見送る）
```

開いていた `GeoPackageFile` はそのまま使える。次の `getDatabase()` で開き直し、次に書くときにトリガーをまた落とす。
そのため控え（`QgisInterop`）はパスごとに 1 つにして接続を閉じても残し（`GeoPackageConnection.qgisInteropFor`）、
「見回り済みの表」（`QgisInterop.cleanedTables`）も同じ控えに持ち、トリガーを戻したとき・開き直したときに空にする。
Drive から落として置き換えたときは控えを捨てる（`SyncBaseStore.settleAfterDownload`）。
web は rtree の焼き直しをせず、開いている写しでトリガーを戻して書き戻すだけ。

テストは `test/gpkg_hand_off_test.dart`（`SpatialIndexManager.debugWithoutRtreeModule` で Android の rtree 無しをまねる）。

#### Android でもトリガーを落とす理由

GDAL の rtree トリガーは `ST_IsEmpty`・`ST_MinX` などを呼ぶ。Android 本体の SQLite には SpatiaLite の関数も rtree モジュールも無いので、
トリガーを残したまま書くと INSERT/UPDATE が `no such function` で失敗する（地物を足せない）。関数を Dart から登録する手は sqflite に無い。
だから書く前に落とし、外へ出す前に戻して rtree を rtree のある SQLite（geodiff）で焼き直す。

## `.qgs`（QGISプロジェクト）の書き出し

実装は `lib/services/qgis/`、テストは `test/qgs_writer_test.dart`。
設計の背景は [[project-format-design#View の導入]]。

```
QgsProjectBuilder   ツリーを辿って QgsProject を組み立てる（DB・FSに触る）
QgsProject / QgsLayer / QgsGroup   XMLと切り離した表現
QgsWriter           XMLにする（純粋関数。DBもFSも要らないのでテストしやすい）
QgsDocument         既存の .qgs を読み、自分の管轄だけ差し替えて書き戻す（DOM 保持型・2026-09-06）
```

> [!IMPORTANT] 書き出しは「上書き」ではなく「更新」（2026-09-06）
> `<dir名>.qgs` が既にあれば `QgsDocument.apply()` で読み込み、レイヤツリー・maplayer の参照と
> フィルタ・単一シンボルの色と太さ・`<layerorder>` だけを差し替える。QGIS 側で足した
> 印刷レイアウト・フィールド設定・単一シンボルの細部（破線・オフセット等）はそのまま残る。
> 単一シンボル以外のレンダラは触らず、件数を通知する。プロジェクトに無くなったレイヤは外して名前を通知する。
> ただし QGIS で足したネットワークのレイヤ（XYZ タイル・WMS など）は管轄外として残す（2026-10-09。
> [[external-formats#`.qgs` との往復]]）。
> `properties/kokage/` に印（`schemaVersion` `app` `savedAt` `dirName`）を書き、root の
> `saveDateTime` を同じ値にする。両者が一致していれば「最後に書いたのはこかげマップ」、
> 違えば QGIS が後から保存した、と読める。テストは `test/qgs_document_test.dart`。

対応:

| こかげマップ | QGIS |
|---|---|
| dir | レイヤグループ |
| GeoPackage | レイヤグループ |
| Layer | レイヤグループ |
| **View** | **レイヤ**（`layer-tree-layer` + `maplayer`） |

View だけがレイヤになるので **1:1 対応**が成立する。View のフィルタは OGR の
データソースURIに `|subset=` として載る（QGIS が subset string を書く場所と同じ）。

出力先は `<dir>/<dir名>.qgs`（2026-09-06 に `project.qgs` から改名。旧名が残っていれば
新名に改名して引き継ぐ）。**連携dirごとに1本**置く。パスは相対
（`<Absolute type="bool">false</Absolute>`）なので、そのdirを丸ごと渡された人が
そのdirだけで開ける。

> [!IMPORTANT] レイヤIDは決定的に作る
> 生成のたびに変わると `.qgs` の差分が毎回出て、Drive同期が無駄に動く。
> View のキーをサニタイズしたものに、キーのハッシュを添えている。
> ⚠ ハッシュは `stableHashHex()`（MD5）。以前の `String.hashCode` は VM と dart2js で値が違い、
> **web と Android で同じ View に別の id が付いていた**（2026-09-06 修正）。
> ⚠ `viewKey` は dir を含まないので、同名 gpkg が root とサブ dir にあると衝突する。
> ハッシュには gpkg の相対 dir を混ぜている（同日修正。QGIS は同じ id のレイヤを1つに畳む）。

> [!NOTE] QGIS 3.44.12 で実開封を確認済み（2026-08-26）
> ```
> read() = True
> --- '既定'        valid=True  count=12  crs=EPSG:4326
> --- '大きい区画'  valid=True  count=6   subset='area > 105'
>                   symbol=SimpleMarker color=#1e90ff
> [group] 林小班.gpkg → [group] rinshoban → [layer] 既定 / 大きい区画
> ```
> 相対パスの解決・subsetの適用（12→6）・レンダラの読み取り・グループ構造の
> いずれも意図どおり。

### QGISで確かめる手順

メイン PC（DESKTOP-16MQHHF）には 2026-09-12 に QGIS 4.2.0 を普通にインストールした
（`C:\Program Files\QGIS 4.2.0`）。こちらは pwsh から直接呼べる:

```powershell
& 'C:\Program Files\QGIS 4.2.0in\python-qgis.bat' tool/qgis/check_qgs.py <project.qgs>
& 'C:\Program Files\QGIS 4.2.0in\python-qgis.bat' tool/qgis/edit_qgs.py <in.qgs> <out.qgs>
```

⚠ `cmd //c` 経由だと Git Bash がパスを壊す。pwsh の `&` で呼ぶ。

Surface（開発機）には QGIS が**インストールされていない**（管理者権限が要るため）。
代わりにMSIを展開しただけのものを使っている。

```powershell
# 1. MSIを取得（署名がOSGeo財団のものであることを確認すること）
curl -L -o .temp/QGIS-LTR.msi https://download.osgeo.org/qgis/win64/QGIS-OSGeo4W-3.44.12-1.msi
Get-AuthenticodeSignature .temp\QGIS-LTR.msi   # Status が Valid であること

# 2. 管理者権限なしで「展開だけ」する（/a = 管理インストール）
msiexec /a .temp\QGIS-LTR.msi /qn TARGETDIR=C:\Users\<user>\qgis-extract

# 3. PyQGIS で開かせる
& 'C:\Users\<user>\qgis-extract\QGIS 3.44.12\bin\python-qgis-ltr.bat' `
    tool/qgis/check_qgs.py <project.qgs>
```

⚠ `winget install OSGeo.QGIS_LTR` は配信サービス側のエラー（0x8a15006d）で
落ちることがある。そのときは上のように直接MSIを取る。
⚠ `msiexec /i` は `Error 1925`（管理者権限が無い）で失敗する。`/a` なら通る。

書かないもの（`QgsProject.skipped` に入り、通知に出る）:

- 写真（`ImageNode`。QGIS には写真の概念が無い）
- こかげマップで位置合わせした GeoTIFF でない png/jpg のオーバーレイ（位置を QGIS に伝えられない。QGIS 由来のワールドファイル付きは書く）

オーバーレイ画像のうち **GeoTIFF（.tif/.tiff）はラスタレイヤとして書く**（2026-09-11）。
位置は `.tif` の GeoTIFF タグに焼き込み済み（`GeoTiffWriteScheduler`）なので、`.qgs` には
`provider=gdal` の参照（相対パス）だけを書き、レンダラ（`<pipe>`）は書かない。QGIS は読込時に既定の
レンダラを付ける。DOM 保持型の更新では参照と名前だけ直し、QGIS が付けた `<pipe>` は残す。
読み戻し（インポータ）は可視性だけをオーバーレイに戻し、XYZ タイルは背景地図に足す（2026-10-09。それまでは黙って飛ばしていた。一覧に無い URL の XYZ と WMS も 2026-10-11 から利用者の地図として足す）。
扱えないラスタ（root の外・位置か座標系を読めないもの・WMTS・Google などの規約で使えないタイル）は理由つきで報告する。
QGIS / GDAL で作ったラスタ（GeoTIFF・JPEG2000・ワールドファイル付き PNG/JPEG・VRT。GDAL で位置と座標系が読めるもの）は
2026-10-10 から読み取り専用のオーバーレイ（`ExternalOverlayImageNode`）になり、可視性を読み戻す。書き戻しは元のファイルの相対パスと
元の座標系（`gdalinfo` の WKT2・EPSG）で書く（[[external-formats#ラスタのオーバーレイ（GDAL、2026-10-10）]]）。
QGIS で足したラスタが同じ `.tif` を指していれば、書き戻しでアプリの id に付け替えて QGIS の `<pipe>`（不透明度など）を残す。
詳細は [[external-formats#ラスタ（2026-10-09 実装）]]。XML の形は `test/qgs_raster_test.dart`、読み戻しは `test/qgs_raster_read_back_test.dart`。

> [!NOTE] QGIS 4.2.0 で実開封を確認済み（2026-09-12、開発機に `C:\Program Files\QGIS 4.2.0` を入れて headless）
> 実機（Pixel 9）から pull した `Kitayama-2026/` に `test_overlay.tif` を `QgsRasterLayer` で足した `.qgs` を
> `python-qgis.bat` の `QgsProject.read()` で開き、そのまま QGIS 側で編集して保存し直し、アプリ側で読み戻した。
> ```
> read() = True   badLayers = []
> raster 'test_overlay'  valid=True  crs=EPSG:4326  bands=3  400x300
>        extent 135.5696,33.8969 : 135.5740,33.8996   ← GeoTIFF タグどおり
> tree: [group] Kitayama-2026 → 3 vector + raster、順序も `orderedLayerIds` どおり
> QGIS 側で編集して write(): saveUser / version="4.2.0-Belém do Pará" / subset `area_ha > 5` → 6 件 / 道レイヤ消灯 / ラスタ opacity 0.5
> アプリ側 QgsDocument.apply(): 名前と参照は直し、QGIS の <pipe>（opacity 0.5）と <projectCrs> は残る
> アプリ側 QgsImporter.import(): 3 View（subset は filter に、消灯はレイヤ可視に）、ラスタは報告せずに飛ばす
> ```
> 見つかった問題（同日修正）:
> - GDAL が `GPKG: unrecognized user_version=0x00000001` と警告。sqflite の `openDatabase(version: 1)` が
>   `PRAGMA user_version` を 1 に上書きしていた（外部の .gpkg を開くだけでも書き換わる）。
>   `version:` をやめ、新規作成時に `application_id=GPKG` / `user_version=10301` を書く（`test/geopackage_version_marker_test.dart`）
> - `<projectCrs>` が空（アプリは書かない）。QGIS は最初のレイヤの CRS を採用するので実害なし。書くなら EPSG:4326
> - `GeoTiffService` は GeoKey 2048（GeographicTypeGeoKey）を書いているが、古い実機の `.tif` には無く
>   QGIS が CRS を「不明」にする。書き直せば直る（`GeoTiffWriteScheduler` の再書き込み）
> 確認スクリプトは `tool/qgis/check_qgs.py`（読み）と `tool/qgis/edit_qgs.py`（QGIS 側で編集して保存）。
- プロジェクトフォルダの**外**を参照する `.gpkg`
  （渡された相手の環境には無いので、残すと「レイヤはあるが表示されない」になる）

## `.qgs` の読み込み（寛容側）

実装は `lib/services/qgis/qgs_importer.dart`、テストは `test/qgs_importer_test.dart`。

**一度読んで変換して捨てる。** `.qgs` を正典として持たない。
`<maplayer>` を1枚ずつ見て、飲めるものを View にする。

ルール:

1. **root外への参照は丸ごと捨てる。** `C:\work\data.shp` やPostGIS接続を指すレイヤは
   山の中のスマホでは開けない。残すと「レイヤはあるが表示されない」最悪の状態になる
   - ⚠ 相対パスで root 外を指すケース（`../shared/kyoyu.gpkg`）は林業では現実にありそう。
     判定は**正規化した絶対パス**で行う
2. **QGISのグループ階層は採らない。** レイヤ構造は dir 構造に置き換える
   （`.gpkg` の実在パスで既存ツリーのレイヤに突き合わせる）
3. **生き残った参照のスタイルは View として再利用する。**
   同じレイヤを指すQGISレイヤがN枚あれば **N個の View** になる。
   ここが View を入れた最大の理由で、これが無いと「1枚選んで残りを捨てる」しかなかった
4. **捨てたものは必ず報告する**（`QgsImportResult.discarded` → 通知）

> [!IMPORTANT] 取り込んだレイヤの View は丸ごと置き換える
> 何度読んでも増えないようにするため。`.qgs` に出てこなかったレイヤは触らない。

> [!IMPORTANT] テスト用 fixture は QGIS 本体に書かせたもの
> `test/fixtures/qgis_3_44_written.qgs` は `tool/qgis/write_fixture.py` を
> PyQGIS で走らせて作った**本物**。手で書いたXMLでは気づけない差がここで出る。
> 実際、これを入れて2件見つかった:
>
> - 色に浮動小数表記が付く: `30,144,255,255,rgb:0.1176471,0.5647059,1,1`
> - `<layer>` の中に `<data_defined_properties>` があり、そこにも
>   `name="name"` の `<Option>` が入っている。再帰で読むと本物の値を潰す
>
> QGISのバージョンを上げたら fixture を作り直すこと。

> [!NOTE] 読み取りは寛容に
> - シンボルのプロパティは QGIS 3.x の `<Option name= value=>` と、
>   それ以前の `<prop k= v=>` の**両方**を読む。他人のファイルは古い形式で来る
> - 単一シンボルは1レイヤ目だけ拾う。重ね合わせの完全再現は狙わない。
>   狙うと「開けるファイルを選り好みする」方向に行く（コンセプトと逆）
> - 分類・段階・ルールは地物ごとの色まで再現する（下の「描き分けの再現」）
> - `subset` は `|` で切らずに**最後まで丸ごと**取る（SQLの `||` で壊れるため）

読み込み口はファイル選択ダイアログではなく「**このフォルダの中の `.qgs`**」。
共有の単位が dir なので、それで足りる。複数あれば `project.qgs` を優先。

## 描き分け（分類・段階・ルール）の再現（2026-10-11）

QGIS で `categorizedSymbol` / `graduatedSymbol` / `RuleRenderer` にしたレイヤ（樹種で分類した小班など）を、
それまでの「代表の 1 色」ではなく地物ごとに QGIS と同じシンボルで描く。2D・3D・引いた段の焼き込みのどれも同じ経路。

```
.qgs <renderer-v2>
  └ QgsRendererReader.read（qgs_renderer_reader.dart）  → QgisRenderer（models/qgis_renderer.dart）
       └ KMetaLayerStyle.qgisRendererDef に入れてフォルダ設定（kokage/meta）に持つ。印 qgisRenderer と組
LayerNode.refreshStyleGroups（地物の読み込み・スタイル変更のたびに 1 回）
  └ シンボルごとにスタイルグループ `<View のキー>#<添字>` を作り、地物の属性で振り分ける（styleKeyByRowId）
  └ どのシンボルにも当たらない地物は rendererHiddenRowIds（地図にも選択にも出さない）
地図面は k-style でグループの色を引く（既存の View ごとのスタイルと同じ仕組み）
```

- **読むもの**: 分類は列か式・値（複数値の項目も）・「その他の値すべて」（値が空か NULL の項目）・チェックを外した項目。
  段階は列か式・範囲（並び順で最初に `lower <= v <= upper` のもの。QGIS の `rangeForValue` と同じ）。ルールは入れ子・ELSE・
  チェックを外したルール。複数のルールに当たったら **最後に当たったもの**（QGIS でいちばん上に描かれる）の色
- **シンボル**: 面は SimpleFill（塗り・輪郭の色と太さ、`style=no` / `outline_style=no`）、無ければ輪郭だけの SimpleLine。
  線は SimpleLine（色・太さ）、点は SimpleMarker（色・大きさ）。シンボルの `alpha` とレイヤの `<layerOpacity>` は面の塗りと輪郭の不透明度に掛ける
- **式**: `lib/utils/qgis_expression.dart`（QGIS の式の部分集合。比較・AND/OR/NOT・IN・LIKE/ILIKE・IS [NOT] NULL・BETWEEN・
  CASE・四則と `||`・lower/upper/coalesce/if など）。NULL は三値でフィルタでは偽。ラベルの式（`label_expression.dart`）とは別の木。
  **読めない式が 1 つでもあれば、そのレンダラは代表の色で全部描く**（ログに 1 回だけ出す。スタイル画面の凡例に注記）
- **速さ**: 1 万件の振り分けは分類 8ms・ルール 30ms 程度、`refreshStyleGroups` 全体で 15ms 程度（テストの実測）。描画のたびには評価しない。
  属性を直した地物は `LayerNode.updateFeatureAttribute` でその 1 件だけ選び直す
- **並び**: 同じ View の中はシンボルで並べ替えない（QGIS もシンボルレベルを使わなければデータの順）
- **書き戻し**: `.qgs` のレンダラは触らない（不変条件4、`QgsDocument`）。読み戻しのたびに中身を差し替え、QGIS で単一シンボルに
  戻されたら印と中身を一緒に外す（`KMetaLayerStyle.withoutQgisRenderer`）
- **古い取り込みの補完**: 中身を持つ前に取り込んだプロジェクトは印だけを持つ。自分が書いた `.qgs` は読み戻さないので、
  開いたときに `QgsImporter.backfillRendererDefs` が印だけのスタイル・View にレンダラの中身を足す（他の設定には触らない）
- **凡例**: スタイル画面（色・太さは引き続き編集させない）と、レイヤ一覧の行の下（8 件を超えたら「… +N」）
- **やらないこと**: 縮尺による切り替え（ルールの min/max scale は無視して常に当てる）・破線・点の形・線と点の不透明度・
  シンボルの重ね合わせ・データ定義の上書き・`$area` など地物の形を使う式

テストは `test/qgis_renderer_test.dart`（QGIS 4.2.2 に書かせた `test/fixtures/qgis_4_2_renderers.qgs` と、QGIS が地物ごとに選んだ
シンボルの `_expected.json` を突き合わせる。作り直しは `tool/qgis/write_renderer_fixture.py`）、`test/view_style_test.dart`
（振り分けと 3D の点の色）、`test/qgs_renderer_backfill_test.dart`（取り込みと補完）。

> [!NOTE] QGIS の `symbolsForFeature` は ELSE のルールを常に含める
> 正解を作るときは `legendKeysForFeature`（当たったルールの key）を使う。色で比べると ELSE が全部に当たって見える。

## 属性フォーム（編集ウィジェット・既定値・制約）（2026-10-11）

QGIS のレイヤのプロパティ →「属性フォーム」で決めた入力の形を、アプリの属性の入力（属性テーブルのフォーム表示・編集パネル・
属性テーブルのマス）にそのまま使う。**フォームの設計は QGIS でする**（アプリに設計の画面は作らない。QGIS のプラグインも要らない）。

```
.qgs <maplayer>（既定 View の maplayer、無ければそのレイヤを指す最初の maplayer）
  <fieldConfiguration><field name><editWidget type><config><Option …>   編集ウィジェットと設定
  <aliases> <defaults>（expression・applyOnUpdate） <constraints> <constraintExpressions> <editable>
  <editorlayout>tablayout + <attributeEditorForm>                        ドラッグ&ドロップの配置
  └ QgsFormReader.read（qgs_form_reader.dart） → QgisForm（models/qgis_form.dart）
       └ KMeta.forms[レイヤキー] に入れてフォルダ設定（kokage/meta）に持つ
入力の欄: QgisFieldInput（widgets/qgis_form/qgis_field_input.dart）。並びは qgisFormRows
既定値・制約: qgis_form_logic.dart（evaluateQgisDefaults / validateQgisForm）
選択肢: QgisFormOptions（UniqueValues はレイヤの既存の値、ValueRelation は参照先のレイヤ）
```

| QGIS の編集ウィジェット | アプリの欄 |
|---|---|
| ValueMap | ドロップダウン。表示名を見せて値を書く。選択肢に無い値も消さずに出す |
| CheckBox | チェック。`CheckedState` / `UncheckedState` を書く（無ければ数の列は 1/0、他は true/false） |
| DateTime | `display_format` で見せ、カレンダー（時刻があれば時計も）で選ぶ。DATE の列は `yyyy-MM-dd`、DATETIME の列は UTC の ISO 8601（`…T…Z`）、文字の列は `field_format` で書く |
| Range | `Style` が Slider/Dial ならつまみ（Step に合わせる）、それ以外は数の欄（確定で Min〜Max に収める） |
| TextEdit | `IsMultiline` なら複数行 |
| UniqueValues | レイヤの既存の値。`Editable` なら打てる候補つきの欄、でなければドロップダウン |
| Hidden | 出さない（既定値・更新時の既定値は書く） |
| ValueRelation | 参照先のレイヤの Key・Value を `FilterExpression`（qgis_expression で評価）で絞る。`OrderByValue` で並べる。複数選択（AllowMulti）は単一として扱う |
| その他（Color・ExternalResource・RelationReference など） | 文字の欄（種類と設定は持ち帰る） |

- **別名**は欄の名前と属性テーブルの見出しに。必須（強制）の欄は名前に `*`
- **既定値**は新しい地物（`FeatureNode._newAttributes`。どの道具で作っても通る）に入れる。名前・説明は道具が値を渡せばそちらを使う。
  `applyOnUpdate` のものは、属性フォームで欄を直したとき・編集パネルで保存したときにも当て直す。式は qgis_expression で評価する
  （`now()` / `$now` / `uuid()`・文字や数・列の参照・関数の部分集合）。読めない式（`@user_full_name` などの変数・知らない関数）はその列を飛ばしてログに 1 回
- **制約**: NULL でない（空の文字も入っていない扱い）・一意（同じレイヤのほかの地物の値と比べる）・式。強制（QGIS の「強制する」）は保存しない
  （通知と欄の下に理由。属性テーブルのマスは元の値に戻す）、強制しないものは保存して通知で知らせる。式の説明があれば説明を出す。
  編集パネルは保存のときに出ている全部の欄を、警告は書き換えた欄だけを確かめる
- **読み取り専用**（「編集可能」を外した列）は見せるだけ。属性テーブルのマスも編集させない
- **配置**: ドラッグ&ドロップの配置ならその順で、タブ・グループは見出しにする（タブを切り替える UI にはしない）。配置に無い列は出さない（QGIS と同じ）。
  自動生成の配置なら列の順
- **属性テーブル**: ValueMap・ValueRelation・値の決まったチェックボックスは選択の列（マスには値、見せるのは表示名）
- **持ち方**: QGIS では maplayer ごとに持つが、アプリはレイヤごと。同じレイヤを指す View が複数あれば既定 View のもの
- **ValueRelation の参照先**は `.qgs` の maplayer の id なので、取り込みでツリーの gpkg とレイヤ（このフォルダからの相対パスとレイヤ名）に読み替えて
  設定に入れる（`kokageTarget`）。読み替えられなければ取り込みの報告に出し、その列は文字の欄
  参照先の gpkg・レイヤをアプリで改名したら（読み取り専用レイヤの改名・gpkg への変換も）、プロジェクトのどのフォルダのフォームでも `kokageTarget` を新しい名前へ付け替える
  （`LayerDrawerService.retargetValueRelations` → `KMetaService.retargetValueRelations`。前は参照先を見失い、その列が文字の欄になっていた）
- **書き戻し**: `.qgs` のフォームの設定は触らない（QGIS の持ち物。`QgsDocument` が DOM ごと残す）。読み戻しのたびに差し替え、QGIS で設定を外したら外す
- **古い取り込みの補完**: 自分が書いた `.qgs` は読み戻さないので、開いたときに `QgsImporter.backfillForms` が、フォームの設定を持たないレイヤにだけ足す
  （`.qgs` にフォームを設定した跡があるときだけ読む）
- **やらないこと**: 制約・既定値の式のうち地物の形や変数を使うもの、ウィジェットの見た目の細部（ラベルの位置・列数・色）、表示条件の式、
  関係（RelationReference・子のフォーム）、ValueRelation の複数選択、ドラッグ&ドロップの HTML・QML・テキスト要素、`editforminit` の Python

テストは `test/qgis_form_test.dart`（QGIS 4.2.2 に書かせた `test/fixtures/qgis_4_2_forms.qgs` を読む・並び・式・既定値・制約・欄の出し分け。
作り直しは `tool/qgis/write_form_fixture.py`）と `test/qgs_form_import_test.dart`（取り込み・値の関係の解決と選択肢・新しい地物の既定値・補完・往復で残る）。

## 表の結合（森林簿 CSV と計画図）（2026-10-11）

森林簿（林班・小班ごとの樹種・林齢・面積の表）は CSV や Excel で、計画図（小班のポリゴン）は shp・gpkg で配られる。
QGIS ではレイヤのプロパティ →「結合」で 1 つの列どうしを結ぶ（`.qgs` の `<vectorjoins>`）。それと同じものをアプリに入れた。

```
座標の列が無い CSV ─ ExternalLayerNode.loadNodes が GDAL で座標の列を探して無ければ ─→ TableNode（models/nodes/table_node.dart）
  └ CsvTable.parse（services/table/csv_table.dart）  文字コードの判定・CSV の分解・型の判定
KMeta.joins[レイヤキー] = [LayerJoin]（models/layer_join.dart）  フォルダ設定に持つ。.qgs と往復
LayerNode.loadJoins（地物の読み込みのたび）
  └ TableCache.load → ResolvedJoin.build（services/table/table_join.dart）  表を「結合の値 → 行」の Map に 1 回だけ
  └ LayerNode.effectiveProperties(props)  属性 + 結合した列（描き分け・ラベル・検索・属性テーブルが読む）
```

- **表のノード**: 座標の列が無い CSV（`ExternalSource.accepts` が偽）はレイヤでなく表（`NodeType.table`）。地図には描かず、可視性も持たない。
  押すと中身を見る（`table_view_dialog.dart`）。長押しで削除。⚠ XLSX は同梱の GDAL にドライバが無い（[[gdal#Android の実装で決めたこと（2026-10-09）]]）ので CSV だけ
- **文字コード**: GDAL の CSV ドライバは文字コードを選べない（`ENCODING` のオープンオプションが無く、Shift_JIS はバイト列のまま化ける）ので、
  表は Dart で読む。UTF-8（BOM の有無を問わない）として正しければ UTF-8、でなければ CP932。CP932 の表は Python の cp932 から作った
  `cp932_table.dart`（`tool/gen_cp932_table.py`。NEC 特殊文字・IBM 拡張文字を含む。pub の charset は IBM 拡張文字を持たず「髙」「﨑」が化けた）
- **型**: QGIS の「CSV テキストレイヤ」（delimitedtext、`detectTypes=yes`）に合わせて整数・小数・文字。空の欄は NULL
- **照合**: QGIS と同じく **値の文字の形** で比べる（結合の記憶は `QVariant::toString()` を鍵にする）。整数 12 と文字 "12"、
  12.0 と "12" は当たる。NULL は当たらない。同じ値の行が複数あれば、記憶あり（`memoryCache="1"`、既定）は最後の行、なしは最初の行
  - 全角・半角と前後の空白を揃える照合（`LayerJoin.normalize`）はアプリだけの選択。既定は QGIS と同じ完全一致。
    `.qgs` には書けない（QGIS は揃えない）ので、付けると QGIS では結ばれない地物が出る。画面に注記
- **列**: 足す列は `<接頭辞><表の列名>`。接頭辞の既定は `<表の名前>_`（QGIS の既定も `<結合先のレイヤ名>_`。アプリは表の QGIS のレイヤ名を
  ファイル名から拡張子を除いたものに揃えて書くので一致する）。結合の列そのものと、既にある名前の列は足さない（QGIS と同じ）
- **速さ**: 表は読み込みのたびに 1 回だけ Map にし、地物ごとには引くだけ。1 万行の CSV で、読む 80 ms・Map にする 12 ms・1 万件の照合と属性の合成 35 ms（2026-10-11、メイン PC のテスト VM。
  `test/table_join_test.dart` は 1 秒を上限に確かめる）。
  表の中身は更新時刻と大きさで控える（`TableCache`）
- **出る所**: 属性テーブル（右側に鎖の印・薄い色で読み取り専用。フォーム表示も）、ラベル（式とラベルの組み立ての列の一覧）、
  QGIS の描き分け（分類・段階・ルールの式）、属性で探す（gpkg の SQL の後に、読み込んである地物の結合の値を見る）、
  書き出し（既定で書く。「結合した表の列も書く」で外せる）
- **書き出し**: `ogr2ogr -sql` に `WITH "__kokage_join"(fid, 列…) AS (VALUES …) SELECT t.*, … FROM <レイヤ> t LEFT JOIN …`。値はアプリの
  照合の結果を主キーごとに並べる（gpkg の SQLite で結合し直さない。照合の決まりが 1 か所に揃う）。View で絞らず全部の地物。
  1 行目は空の行（VALUES は空にできない）。数の列は数のまま書かれる（GDAL 3.13 で確認）
- **使えない所**: 属性テーブルのフィルタ（式を gpkg の SQL にする）・統計・置換・一括設定・View のフィルタ（`|subset=` は gpkg の SQL）。
  結合の先は表だけ（QGIS ではベクタのレイヤにも結べる。読み戻しで報告して外す）。林班と小班が別の列なら、両側に 1 つの列を作ってから結ぶ

### `.qgs` との往復

- **書く**（`QgsProjectBuilder`・`QgsWriter`・`QgsDocument`）: 表は `QgsTableLayer`。`provider=delimitedtext`、
  `datasource=file:./%E6%A3%AE%E6%9E%97%E7%B0%BF.csv?type=csv&encoding=CP932&maxFields=10000&detectTypes=yes&geomType=none&subsetIndex=no&watchFile=no`
  （QGIS の「CSV テキストレイヤを追加」が書く形。パスは % エンコードした相対）、`wkbType="NoGeometry"`。id は相対パスのハッシュ（`table_<hash>`）。
  ツリーには dir のグループの中に `providerKey="delimitedtext"` で載る。
  レイヤ（View）の maplayer に `<vectorjoins><join joinLayerId targetFieldName joinFieldName memoryCache [customPrefix hasCustomPrefix]><joinFieldsSubset>`
  （QGIS 4.2.2 が書く属性と同じ）。同じレイヤの View 全部に同じ結合を書く
- **更新**（DOM 保持型）: QGIS で足した表が同じファイルを指していれば、id をアプリのものに付け替え、`<join joinLayerId>` とツリーも付け替える
  （`_adoptTableIds`。外して足し直すと QGIS の結合が宙に浮く）。QGIS が ogr で読んでいる表（`encoding="CP932"` など）はその形のまま残す。
  `<vectorjoins>` はアプリの表への `<join>` だけ差し替え、ほかのレイヤへの結合（QGIS の持ち物）は残す
- **読む**（`QgsImporter`）: 形の無い maplayer（`wkbType="NoGeometry"`）は View にせず、delimitedtext・ogr のパスで表のノードに結ぶ。
  既定 View の maplayer（無ければ最初の maplayer）の `<vectorjoins>` を `KMeta.joins` に写す（無ければ外す）。結合先が表でなければ報告
- QGIS 4.2.2 で確認: アプリが書いた `.qgs` を開いて、UTF-8 の表（delimitedtext）と CP932 の表（`encoding=CP932`）が valid で、
  結合した列と値が QGIS が付けた値（`test/fixtures/qgis_4_2_joins_expected.json`）と一致（2026-10-11）

テストは `test/table_join_test.dart`（表のノード・UTF-8 と CP932・照合を QGIS の値と突き合わせる・検索・書き出し）と
`test/qgs_join_test.dart`（QGIS 4.2.2 に書かせた `test/fixtures/qgis_4_2_joins.qgs` の読み・書いて読み直す・QGIS の表の id の付け替えと
QGIS の結合を残す）。fixture の作り直しは `tool/qgis/write_join_fixture.py`。`KOKAGE_KEEP_QGS=<dir>` で書いた一式が残る
（`tool/qgis/check_qgs.py` で開ける）。

## 1. SpatiaLiteトリガーの復元

QGIS/GDAL 製の GeoPackage は RTree を自動更新するトリガーを持ち、
それらは `ST_IsEmpty` / `ST_MinX` 等の **SpatiaLite 関数**を使う。
sqflite にその拡張は無いので、こかげマップ は書き込み前にトリガーを落とし、
rtree は `SpatialIndexManager` が自前で更新している。

> [!IMPORTANT] 落としたまま返してはいけない
> トリガーが無いまま QGIS に戻すと、**その後 QGIS で編集しても空間インデックスが
> 更新されない**。インデックスと実データがズレて、空間検索の結果が欠ける。

対処: 落とす前に `sqlite_master` の `sql` を控えておき、クローズ時に**逐語的に**戻す。

規格から生成し直さない理由は、RTreeトリガーの構成が GDAL のバージョンで違うため
（`update1`〜`update7` 等）。生成し直すと元と違うものを書き込むことになる。

⚠ アプリが強制終了した場合は控えが失われ、トリガーが落ちたまま残る。
これは対処前と同じ状態なので退行ではないが、既知の穴。裏に回ったとき（paused）に戻すようにしたので、
裏で止められる分は塞いだ（[[#閉じずに外へ出すとき（2026-10-12〜）]]）。前面で落ちたときは残る。

## 2. `gpkg_contents` のバウンディングボックス

QGIS はここをレイヤの範囲として使う。空だと「レイヤにズーム」が効かない。

こかげマップ は新規レイヤ作成時に `min_x`/`min_y`/`max_x`/`max_y` を null で入れていたため、
クローズ時に rtree から集計して埋める。

rtree が無い場合はスキップする（全件走査は重く、こかげマップ は rtree を自前で維持しているので通常は存在する）。

2〜3 と rtree の焼き直し（`GpkgIndexRepair`）は、**アプリが書いたときだけ**行う（`GeoPackageConnection.hasWrites` = `total_changes()`）。
以前は見ただけの rtree つき gpkg も閉じるときに範囲と rtree を書き直していて、rtree の float32 の範囲が元の値と違うので
ファイルが変わっていた（2026-10-12、`test/gpkg_open_no_write_test.dart`）。

## 3. `gpkg_ogr_contents` のフィーチャ数

GDAL 拡張の件数キャッシュ。こかげマップ が直接 INSERT/DELETE すると実態とズレる
（GDAL 製ファイルにはこれを維持するトリガーもあるが、上記1で一緒に落ちることがある）。

存在しない GeoPackage もあるので、**無ければ何もしない**。
こかげマップ が勝手に作ると、逆に GDAL の前提を崩す可能性がある。

## 既にQGISに合わせてある点

- **主キーは `fid`**（QGIS/GDAL標準）。旧 こかげマップ 形式の `id` も読める
- **読んだ行の地物番号と解いた形は、列の名前と重ならない鍵に入れる**（`featureIdKey`・`featureGeometryKey`、
  `lib/models/geopackage/feature_row.dart`。NUL で始まり、SQLite の識別子には入らない）。行のほかの鍵は列の名前と値そのまま。
  `id`・`fid`・`geometry` という名前でも主キー・形の列でなければふつうの属性で、属性表・情報パネル・ラベル・描き分けの式に
  自分の値で出て、書き込み・写す・足すでも名前では外さない（外すのは表の主キーと形の列だけ）。
  属性表は QGIS と同じく主キーの列（fid）を読み取り専用で出す（主キーの無い表の rowid は列ではないので出ない）。
  以前は地物番号を `id`、解いた形を `geometry` に入れていて、主キーが fid の表や主キーの無い表の `id` の列（林小班の番号など）が
  地物番号に見えて直せず、形の列が geom の表の `geometry` の列は属性に出なかった（2026-10-12）。
  テストは `test/gpkg_id_column_test.dart`・`test/gpkg_geometry_attribute_test.dart`
- **形の列の名前は表ごとに `gpkg_geometry_columns` から引く**（`GeoPackageSchema.geometryColumn`。開いている間は控える）。
  GDAL の既定と QGIS は `geom` だが、GeoPandas / Fiona は `geometry`、ArcGIS Pro は `Shape`、PostGIS 由来は `the_geom`。
  新しく作るレイヤは `geom`。読んだ行からは形の列を抜き（属性に出さない）、`geom` という名前のふつうの列（形の列が `geometry` の表）と `geometry` という名前のふつうの列（形の列が `geom` の表）は属性として扱う。
  以前は `geom` を決め打ちしていて、ほかの名前の gpkg は地物が出ず、足すと `no column named geom` で落ちた（2026-10-12）。
  テストは `test/gpkg_geometry_column_test.dart`
- **主キーの無い表は `rowid` で読み書きする**（GDAL と同じ。GDAL は「no integer primary key」として `_rowid_` を FID にし、
  `fid`・`id` という名前の列があってもふつうの属性として扱う）。表に列を足さない。
  以前は主キーを調べるだけで `fid` 列を ALTER で足していて、開いただけでファイルが変わり Drive 同期で上がっていた（2026-10-12）。
  ⚠ 主キーの無い表の rowid は VACUUM で振り直されることがある（QGIS でも同じ）
- 任意の EPSG コードに対応（`GpkgCrsResolver`: ①gpkg の定義 → ②手元の表 `EpsgRegistry` → ③epsg.io）
  - 定義の無い（`undefined`）CRS は手元の表で解く。日本の CRS は JGD2011・JGD2000（地理 4612・平面直角 2443〜2461）・
    旧日本測地系（地理 4301・平面直角 30161〜30179）を持つので通信しない。4612 は 6668 と同じく変換しない
  - 旧日本測地系は Bessel + `towgs84=-146.414,507.337,680.507`（PROJ が既定に選ぶ EPSG:15484 Tokyo to WGS 84 (108)。
    QGIS もグリッドが無ければこれ）。PROJ 6 以降の CRS の proj 文字列には towgs84 が出ないが、proj4dart は CRS に持たせる
  - ⚠ **gpkg には書き戻さない**。epsg.io で取れた定義もメモリにだけ持つ。以前は `gpkg_spatial_ref_sys` に書いていて、
    開いただけでファイルが変わり Drive 同期で上がっていた（2026-10-12）。web も同じコード

## 未対応

- **`layer_styles`**（QGISのスタイル保存テーブル）。こかげマップ で設定した色・線幅は
  QGIS に引き継がれない。逆も同様
- `gpkg_metadata` / `gpkg_metadata_reference`

## テストの注意点

`test/qgis_interop_test.dart` は GDAL 製 GeoPackage を模したフィクスチャを作って検証する。

> [!WARNING] フィクスチャには `PRAGMA user_version = 1` が必要
> 実物の GeoPackage は `user_version=1`（GDAL製・既存ファイルで確認済み）。
> これを立てないと sqflite が「新規DB」とみなして `onCreate` を走らせ、
> 既存テーブルと衝突して `table gpkg_spatial_ref_sys already exists` で落ちる。

## 関連

- [[../features/concept|コンセプト]]
- [[testing|テスト構成]]
