---
title: gpkg 以外の形式（読み取り専用レイヤと gpkg への変換）
tags: [technical, geopackage, qgis, interop, import]
---

# gpkg 以外の形式

2026-10-09 決定。「取り込み」をやめ、QGIS と同じく **dir に置かれたファイルがそのままレイヤになる** 形にする。
新規に作るものは gpkg だけ。gpkg 以外は **読み取り専用** で開き、編集したければ gpkg へ **変換（置き換え）** する。

> [!IMPORTANT] 読み手は GDAL（2026-10-10 実装、[[gdal]]）
> 純 Dart の読み手（`ExternalReader`・`readers/`）は撤去した。キャッシュは `ogr2ogr` の出力（元の CRS のまま）で、
> 対応形式は同梱の GDAL のベクタドライバが読めるもの。

## 原則

- **dir 内に現に存在するファイルが正、`.qgs` は従**（[[qgis-interop]]）。
  「この gpkg は あの shp から作った」のような対応表はどこにも持たない。持つと `.qgs` か隠しファイルが真実源になる
- **変換は置き換え**: gpkg を書いて読み直して一致を確かめたら、元のファイル一式を消す。
  変換後の状態はフォルダを見れば分かる。途中で落ちて両方残ったら、両方見えるだけ（データは失われない）
- 消せない場所（読み取り専用の Drive 共有フォルダ）では変換を出さず、「自分のフォルダに gpkg として複製」だけ出す
- 1 ファイル（shp は付属ファイル一式）＝ 1 ノード（gpkg 1 本に相当）。中のレイヤ名は **GDAL のレイヤ名**
  （shp・GeoJSON はふつうファイル名、KML はフォルダ名、GeoJSON の `name` メンバー、DXF は `entities`）。
  点・線・面が混ざったレイヤは `<名前>_point` `_line` `_polygon` に分ける。
  変換先は同じ dir の `<元の名前>.gpkg`。同名の gpkg があれば `<名前>_1.gpkg` …（既存の gpkg に混ぜない。どこに入ったか分からなくなる）
- 窓口は `lib/services/external/external_source.dart`（`ExternalSource`）

## 対応形式

拡張子で候補にし（`externalVectorExtensions`）、`.json` `.csv` だけは GDAL で開いて形のあるレイヤがあるときだけレイヤにする
（結果は更新時刻と大きさで控える）。`.gpkg` は従来の経路。隠しファイル・隠しフォルダ（`.kokage` など）の中は外す。

| 形式 | 拡張子 | 備考 |
|---|---|---|
| Shapefile | `.shp`（付属は `GDALGetFileList` の一式） | `.cpg` も DBF の LDID も無ければ `-oo ENCODING=CP932`（[[gdal#Android の実装で決めたこと（2026-10-09）]]） |
| GeoJSON | `.geojson` `.json` | `.json` は GDAL が形を見つけたときだけ |
| KML / KMZ | `.kml` `.kmz` | 同梱の GDAL は LIBKML なし。KMZ は `/vsizip/<パス>` で KML ドライバに渡す（web は worker が `vsi` を付ける） |
| CSV（点） | `.csv` | `X_POSSIBLE_NAMES`（lon・lng・long・longitude・経度・x）/`Y_POSSIBLE_NAMES`（lat・latitude・緯度・y）、`KEEP_GEOM_COLUMNS=NO`、`AUTODETECT_TYPE=YES`。座標列が無ければレイヤにしない |
| GPX | `.gpx` | waypoints・routes・tracks… が別レイヤ（空のレイヤも GDAL が出す） |
| FlatGeobuf | `.fgb` | |
| GML | `.gml`（`.xsd` `.gfs`） | 基盤地図情報は GDAL_DATA の `.gfs` を使う |
| DXF | `.dxf` | 1 レイヤ（`entities`）で型が混ざる → 分ける |
| MapInfo | `.tab`（`.dat` `.map` `.id` `.ind`）`.mif`（`.mid`） | |
| GeoTIFF | `.tif` | 既存（オーバーレイ） |

### キャッシュの作り方（`ExternalSource.plan` → `translate`）

1. `ogrinfo -json -so`（`vectorInfo`）でレイヤと形の型・件数を見る。形の無いレイヤは飛ばす
2. 型が `Geometry`（混在）・`GeometryCollection` のレイヤは、`-where "OGR_GEOMETRY IN (...)"` で点・線・面ごとに数え、
   2 種以上あれば分ける（1 種だけなら名前はそのまま）。GeometryCollection の地物は落ちる
3. レイヤごとに `ogr2ogr -f GPKG [-update] -nlt MULTIPOINT|MULTILINESTRING|MULTIPOLYGON -dim XY -nln <名前> [-where …] <元> <GDAL のレイヤ名>`。
   **`-t_srs` は付けない**（元の CRS のまま。アプリは投影座標系の gpkg を描ける・選べる）。Z・M は落とす（`-dim XY`）
4. 印の表 `kokage_external_source` に `signature`（`GDALGetFileList` の一式の名前・更新時刻・大きさ＋`formatVersion`）・`source`・
   `layers`（キャッシュのレイヤ → 元の GDAL のレイヤ名・分けた型・件数。`.qgs` の `|layername=` `|geometrytype=` に使う）

- 列名は GDAL のまま（旧来の予約名の言い換え `ID` → `ID_` はやめた）。属性の型も GDAL の判定（CSV は `AUTODETECT_TYPE`）
- GDAL の呼び出しは FFI 版なら 1 回ごとに `Isolate.run`（UI を塞がない）、web は worker
- 使う GDAL は `ExternalGdal.instance`（既定は `createGdal()`。テストは `GdalFfi(findHostGdal())` を差す）

## 仕組み

### ノード

`ExternalLayerNode`（`lib/models/nodes/external_layer_node.dart`）は `GeoPackageNode` の派生で、
**描画・属性表・ヒットテストは裏の「読み込み済み gpkg」に任せる**（描画の経路を 1 本に保つ）。

- `name` は元のファイル名（例 `林班.shp`）、`getAbsoluteFilePath()` は元のファイルのパス
- `geoPackageFile` は `.kokage/cache/external/<元のパスの hash>.gpkg`（プロジェクトルート直下の `.kokage`。同期しない）。
  hash は正規化した元の絶対パスの MD5 の先頭 20 桁（`ExternalLayerCache.cachePathFor`）。ルートが決まっていなければ元と同じ dir の `.kokage`。
  中のレイヤ名は GDAL のレイヤ名
- キャッシュの作り直しは元ファイル（`GDALGetFileList` の一式）の名前・更新時刻・大きさが変わったとき。印はキャッシュ gpkg の中の
  `kokage_external_source` 表（`key`/`value`。`signature` `source` `layers`）に持つ（キャッシュの都合の印で、真実源ではない）。
  印には読み方の版（`ExternalLayerCache.formatVersion`）も入れる。読み方を変えたら上げると全部作り直す
- web: 消したキャッシュを同じパスで作り直すと sqlite3 WASM 側に残った前の写しが開くので、作り直す前に捨てる
  （`GeoPackageConnection.discardWebCopy`）。キャッシュは fs 経由で書くので web でも同じ置き場
- ツリーには `FolderNode.loadExternalNodes` で載る（グローバル・Drive 連携 dir も同じ経路）。`.json` `.csv` の中身の判定は
  更新時刻と大きさで控える（フォルダを開くたびに GDAL で開き直さない）
- `isReadOnly == true`。編集の入口（描画・頂点編集・属性の編集・レイヤの改名・View の追加は可/不可は下表）を閉じる
- 削除: 元のファイル一式とキャッシュを消す（gpkg の削除と同じ扱い）。`syncChildren` で外れるだけのときは何も消さない
- ファイルの改名は元一式の改名（拡張子は保つ）。中のレイヤ名も変わるので、フォルダ設定の鍵を移す
  （`KMetaService.renameGeoPackageKeys`）。フォルダへの移動（左スワイプ）は付属ファイルも一緒に動かす
- 編集の門番は `lib/widgets/external_layer_actions.dart` の `refuseReadOnlyEdit`。断ったら通知センターに
  「gpkgに変換して編集」のボタンつきで出す。地物の削除はまとめて削除の口（`SelectedFeatures.disposeSelectedFeatures`）、
  描画の確定は `GlobalDrawingState.confirmCurrentFeature`、形の編集は `FeatureEditor.start` で止める。
  View の追加・改名はフォルダ設定への書き込みなのでできる

| 操作 | 読み取り専用レイヤ |
|---|---|
| 表示・非表示・スタイル・ラベル・View | 可（`.qgs` に書く。QGIS と同じ） |
| 属性表を見る・選択・ヒットテスト | 可 |
| フィーチャの追加・削除・形と属性の編集 | 不可 →「gpkg に変換して編集」 |
| レイヤの改名・別 gpkg への移動 | 不可（ファイルの改名は可） |
| 書き出し | 可 |

### 変換（`ExternalLayerConverter`）

1. `<元の名前>.gpkg` を同じ dir に作る（キャッシュ gpkg を複製し、`kokage_external_source` 表を落とす）
2. 書いた gpkg を確かめる。件数はレイヤごとに **元と書いた gpkg の両方を GDAL（`ogrinfo -so`）で数えて** 比べる
   （分けたレイヤは `-where` 付きで数えた元の件数）。ジオメトリ型はアプリの 3 種、列名はキャッシュと比べる。
   食い違えば書いた gpkg を消して元を残す（`ExternalConvertVerifyException`）
3. 一致したら元のファイル一式（`GDALGetFileList`）を消す。
   本体を先に消し、消せなければ書いた gpkg を消して元のまま戻し、「自分のフォルダにgpkgとして複製」を出す。
   付属ファイルだけ消せなかったときは残ったものを通知する
4. 親 dir の `updateChildren()`。`.qgs` の参照は次の自動更新で実態に合わせて付け替わる。
   スタイル・View・可視性はレイヤの鍵が変わるので **変換時に新しい鍵へ移す**（フォルダ設定の書き換え）

変換後の座標系は **元のまま**（キャッシュが ogr2ogr の出力で、それを複製するので。2026-10-10〜）。

### `.qgs` との往復

- 書く: 読み取り専用レイヤは `provider=ogr`、`datasource=./林班.shp`。元の GDAL のレイヤが 2 枚以上なら `|layername=<GDAL のレイヤ名>`、
  型の混ざったレイヤから分けたものは `|geometrytype=Point`（`LineString` `Polygon`。QGIS が型ごとのサブレイヤに付ける形）。
  CSV も `provider=ogr`（GDAL の CSV ドライバ。⚠ QGIS では `-oo` の座標列の指定が無いので形の無い表に見えるかもしれない。未確認）。キャッシュのパスは書かない
  - CRS はキャッシュ gpkg のもの（ogr2ogr が元の CRS のまま書いている）を gpkg と同じ経路（`GpkgCrsResolver`）で書く
  - `.cpg` も DBF の LDID も無い shp は `<provider encoding="CP932">`（アプリと同じ読み方。それ以外は UTF-8 で、GDAL が自分で決める）
  - QGIS 4.2.2 で開いて valid・件数・CRS（平面直角 VI 系の `.prj` → EPSG:6674）・`geometrytype` のサブレイヤを確認（2026-10-09。
    `test/qgs_external_layer_test.dart` を `KOKAGE_KEEP_QGS=<dir>` で走らせると一式が残る）
- 読む（`_SourceResolver`）: ogr の非 gpkg は `ExternalLayerNode` に結びつける。`|layername=`（GDAL のレイヤ名）と
  `|geometrytype=` をキャッシュの `layers` の割り当てで引く（無ければ、1 レイヤならそれ、`<名前>_point` など、ファイル名）。
  `delimitedtext` は CSV のノードへ。gdal のラスタはオーバーレイ、`wms`/`xyz` の XYZ タイルは背景地図のレイヤへ（下の 2 項）。
  PostGIS・メモリなどは従来どおり「取り込めません」

#### ラスタ（2026-10-09 実装）

`<maplayer type="raster">` は View にならない。`_SourceResolver._resolveRaster` が振り分け、部品は `qgs_raster_source.dart`。
fixture は QGIS 4.2.2 に書かせた `test/fixtures/qgis_4_2_raster_xyz.qgs`（`tool/qgis/write_raster_fixture.py`）、
テストは `test/qgs_raster_read_back_test.dart`。

**gdal（GeoTIFF）**: dir にあるファイルが正。ノード（`OverlayImageNode`）は dir の中身から作られているので、
`.qgs` はそれに突き合わせて **可視性だけ** を読み戻す（フォルダ設定の `visibility.images` に書く）。
こかげマップが書いた形（`raster_<相対パスの hash>` の id）なら自身の checked、QGIS で足したものは祖先のグループで畳む。

| `.qgs` 側 | 扱い |
|---|---|
| dir 内の `.tif`、位置を読める（こかげマップの形） | オーバーレイの可視性に読み戻す |
| dir 内の `.tif`、位置を読めない（GDAL 既定の Tiepoint 形式・投影座標系） | 報告「位置を読めません」（写真として並ぶ。TODO） |
| ファイルが無い | 報告「見つかりません」 |
| `.png` `.jp2` など GeoTIFF 以外 | 報告「GeoTIFF 以外のラスタは未対応」 |
| root の外・`/vsicurl/`・`GPKG:…` | 報告 |

- ⚠ 不透明度はアプリのオーバーレイに受け皿が無い（2026-04 に廃止、GeoTIFF のアルファで持つ）。読まない。
  代わりに書き戻しで QGIS の `<pipe>` を残す: QGIS で足したラスタが同じ `.tif` を指していれば、外して足し直さずに
  **アプリの決定的な id に付け替える**（`QgsDocument._adoptRasterIds`）。不透明度などは QGIS 側で生き残る

**wms（XYZ タイル）**: URI（`type=xyz&url=<URL エンコード>`）の URL を背景地図の一覧（`BaseMapProvider.availableProviders`）と
突き合わせる（`BaseMapProvider.findByTileUrl`。http/https・OSM の `a.` `{s}.` は無視）。

| `.qgs` 側 | 扱い |
|---|---|
| 一覧にある XYZ（地理院・OSM） | 背景地図のレイヤに足す。可視は checked、不透明度は `<rasterrenderer opacity>` |
| 一覧に無い XYZ | 報告「背景地図の一覧に無い XYZ タイル: ホスト」 |
| 本物の WMS / WMTS（`type=xyz` でない） | 報告「WMS は未対応」 |

> [!IMPORTANT] 背景地図は端末の設定のまま（2026-10-09 決定）
> 背景地図（`BaseMapService.layers`、prefs `basemap_layers`）は端末ごとの設定で、プロジェクトには属さない。
> プロジェクトごとに持たせる作り直しはしない。代わりに `.qgs` から足すときは:
> - **一覧に既にあるプロバイダは触らない**（可視・不透明度も端末の利用者の選択を優先）
> - **一度でも `.qgs` から足したプロバイダは二度と自動では足さない**（prefs `basemap_qgs_imported`）。
>   開くたびに積み上がらず、端末で消したものが次の読み戻しで戻ってこない
> - 足したら通知する（「QGIS のプロジェクトにあった背景地図を足しました」）
>
> 読み戻しは QGIS が保存した `.qgs` を開いたときだけ走る（印で判定。[[qgis-interop]]）ので、そもそも頻度は低い。
> 実装は `lib/services/qgis/qgs_base_map_import.dart`（並びの計算は純粋関数 `merge`）

> [!NOTE] 逆向き（端末の背景地図を `.qgs` に書く）はしない
> 端末ごとに背景地図が違うので、書けば最後に書いた端末で `.qgs` が揺れ、Drive 同期が無駄に動く。
> その代わり **QGIS で足したネットワークのレイヤ（wms・wcs・wfs・arcgis・ベクタタイル）は書き戻しで外さない**
> （`QgsDocument.isWebLayer`）。以前は「プロジェクトに無いレイヤ」として外していたので、QGIS の利用者の背景地図が
> 次の自動更新で消えていた。残したレイヤはツリーの root の一番下・`<layerorder>` の後ろに寄せる（入っていたグループは保たない）

### ファイルをフォルダに入れる経路

- Drive 連携 dir: Drive に置けば同期で落ちてくる（同期対象の拡張子に含める）
- Android: ファイルアプリで `Documents/KokageMap` 以下に置く、またはフォルダの ⋮「ファイルを追加」（file_picker → コピー）
- web: フォルダの ⋮「ファイルを追加」（OPFS へコピー）。ドラッグ＆ドロップも同じ処理に
- 「取り込み」（gpkg へのコピー）は撤去する

## gpkg のレイヤ移動で空になったら gpkg を消す

最後のレイヤを別の gpkg へ **移動** して `gpkg_contents` が空になったら、移し元の gpkg ファイルを消す
（`layer_styles` だけ残っていても空扱い）。ラスタのタイルや属性だけの表など、アプリに見えない中身が残っていれば消さない。
最後のレイヤの **削除** では消さない（中身はどこにも渡っていない。ファイルの削除は利用者が別に選ぶ）。

## Drive 同期

> [!WARNING] キャッシュの `.kokage` を同期から外すこと（未対応・2026-10-09）
> 同期の対象は拡張子（`*.gpkg`）で dir を再帰的にたどるので、プロジェクトルートそのものが Drive 連携 dir だと
> `.kokage/cache/external/*.gpkg` まで上がる。ツリーには出さないようにした（`DriveFolderNode` の子に `.kokage` を出さない）が、
> 同期（`SyncFileOperations.listLocalSyncFiles`）の側でも `.kokage` を飛ばす必要がある

- 同期の対象は拡張子の許可リスト（`SyncFileOperations.syncPatterns`）。対応形式と shp の付属ファイルを足す。
  照合は大文字小文字を区別しない（`IMG.JPG` が落ちていた）
- 手元で消したファイルは Drive では **ゴミ箱行き**（`files.update(trashed: true)`。`files.delete` はどこからも呼ばない）。
  変換で消した shp も 30 日は Drive のゴミ箱から戻せる
- 中身のマージ（geodiff）は gpkg だけ。ほかの形式はファイル丸ごとの新旧で扱う
