---
title: gpkg 以外の形式（読み取り専用レイヤと gpkg への変換）
tags: [technical, geopackage, qgis, interop, import]
---

# gpkg 以外の形式

2026-10-09 決定。「取り込み」をやめ、QGIS と同じく **dir に置かれたファイルがそのままレイヤになる** 形にする。
新規に作るものは gpkg だけ。gpkg 以外は **読み取り専用** で開き、編集したければ gpkg へ **変換（置き換え）** する。

> [!IMPORTANT] 読み手は GDAL に一本化する（2026-10-09 同日決定、[[gdal]]）
> 下の「対応形式」の純 Dart の読み手（`ExternalReader`）は GDAL が入るまでのつなぎ。
> GDAL が入ったら、キャッシュは `ogr2ogr` の出力（元の CRS のまま）になり、対応形式は GDAL が読めるもの全部になる。

## 原則

- **dir 内に現に存在するファイルが正、`.qgs` は従**（[[qgis-interop]]）。
  「この gpkg は あの shp から作った」のような対応表はどこにも持たない。持つと `.qgs` か隠しファイルが真実源になる
- **変換は置き換え**: gpkg を書いて読み直して一致を確かめたら、元のファイル一式を消す。
  変換後の状態はフォルダを見れば分かる。途中で落ちて両方残ったら、両方見えるだけ（データは失われない）
- 消せない場所（読み取り専用の Drive 共有フォルダ）では変換を出さず、「自分のフォルダに gpkg として複製」だけ出す
- 1 ファイル（shp は付属ファイル一式）＝ 1 ノード（gpkg 1 本に相当）。中のレイヤはふつう 1 枚で、名前は元の名前。
  KML のフォルダや GeoJSON のジオメトリ型の混在では複数枚になる（`<名前>_point` など）。
  変換先は同じ dir の `<元の名前>.gpkg`。同名の gpkg があれば `<名前>_1.gpkg` …（既存の gpkg に混ぜない。どこに入ったか分からなくなる）
- 読み手の共通の形は `lib/services/external/external_dataset.dart`（`ExternalReader` → `ExternalDataset`）

## 対応形式

| 形式 | 拡張子 | 読み方 | 段 |
|---|---|---|---|
| Shapefile | `.shp`（`.shx` `.dbf` `.prj` `.cpg` を伴う） | 既存パーサー（`parsers/`） | 1 |
| GeoJSON | `.geojson` `.json`（中身が FeatureCollection / Feature のときだけ） | 既存パーサー | 1 |
| KML / KMZ | `.kml` `.kmz` | 新規（純 Dart、KMZ は archive で展開） | 2 |
| CSV（点） | `.csv`（緯度経度・XY 列を推定できたときだけ） | 新規 | 2 |
| GeoTIFF | `.tif` | 既存（オーバーレイ） | 済 |

GDAL は無い（純 Dart）。FlatGeobuf などは要望が来てから。

## 仕組み

### ノード

`ExternalLayerNode`（`lib/models/nodes/external_layer_node.dart`）は `GeoPackageNode` の派生で、
**描画・属性表・ヒットテストは裏の「読み込み済み gpkg」に任せる**（描画の経路を 1 本に保つ）。

- `name` は元のファイル名（例 `林班.shp`）、`getAbsoluteFilePath()` は元のファイルのパス
- `geoPackageFile` は `.kokage/cache/external/<元のパスの hash>.gpkg`（プロジェクトルート直下の `.kokage`。同期しない）。
  中のレイヤ名は元の名前（拡張子なし）
- キャッシュの作り直しは元ファイル（shp は付属一式）の更新時刻と大きさが変わったとき。印はキャッシュ gpkg の中の
  `kokage_external_source` 表に持つ（キャッシュの都合の印で、真実源ではない）
- `isReadOnly == true`。編集の入口（描画・頂点編集・属性の編集・レイヤの改名・View の追加は可/不可は下表）を閉じる
- 削除: 元のファイル一式とキャッシュを消す（gpkg の削除と同じ扱い）。`syncChildren` で外れるだけのときは何も消さない

| 操作 | 読み取り専用レイヤ |
|---|---|
| 表示・非表示・スタイル・ラベル・View | 可（`.qgs` に書く。QGIS と同じ） |
| 属性表を見る・選択・ヒットテスト | 可 |
| フィーチャの追加・削除・形と属性の編集 | 不可 →「gpkg に変換して編集」 |
| レイヤの改名・別 gpkg への移動 | 不可（ファイルの改名は可） |
| 書き出し | 可 |

### 変換（`ExternalLayerConverter`）

1. `<元の名前>.gpkg` を同じ dir に作る（キャッシュ gpkg を複製し、`kokage_external_source` 表を落とす）
2. 書いた gpkg を開き直し、件数・ジオメトリ型・列名が元と一致するか確かめる
3. 一致したら元のファイル一式を消す（shp: `.shp .shx .dbf .prj .cpg .qix .sbn .sbx .shp.xml .fix .aih .ain`）
4. 親 dir の `updateChildren()`。`.qgs` の参照は次の自動更新で実態に合わせて付け替わる。
   スタイル・View・可視性はレイヤの鍵が変わるので **変換時に新しい鍵へ移す**（フォルダ設定の書き換え）

⚠ 変換後の座標系は EPSG:4326（アプリが作るレイヤはすべて 4326）。元の CRS を保つのは後回し。

### `.qgs` との往復

- 書く: 読み取り専用レイヤは `provider=ogr`、`datasource=./林班.shp`（shp・GeoJSON・KML は `|layername=` なし、
  KMZ・複数レイヤの KML は `|layername=`）。CSV は `delimitedtext` の URI
- 読む（`_SourceResolver`）: ogr の非 gpkg は `ExternalLayerNode` に結びつける（`|layername=` が無ければファイル名）。
  `delimitedtext` は CSV のノードへ。gdal のラスタはオーバーレイ（既存）、`wms`/`xyz` の XYZ タイルは背景地図のレイヤへ。
  PostGIS・メモリなどは従来どおり「取り込めません」

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

- 同期の対象は拡張子の許可リスト（`SyncFileOperations.syncPatterns`）。対応形式と shp の付属ファイルを足す。
  照合は大文字小文字を区別しない（`IMG.JPG` が落ちていた）
- 手元で消したファイルは Drive では **ゴミ箱行き**（`files.update(trashed: true)`。`files.delete` はどこからも呼ばない）。
  変換で消した shp も 30 日は Drive のゴミ箱から戻せる
- 中身のマージ（geodiff）は gpkg だけ。ほかの形式はファイル丸ごとの新旧で扱う
