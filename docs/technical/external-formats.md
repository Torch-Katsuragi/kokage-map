---
title: gpkg 以外の形式（読み取り専用レイヤと gpkg への変換）
tags: [technical, geopackage, qgis, interop, import]
---

# gpkg 以外の形式

2026-10-09 決定。「取り込み」をやめ、QGIS と同じく **dir に置かれたファイルがそのままレイヤになる** 形にする。
新規に作るものは gpkg だけ。gpkg 以外は **読み取り専用** で開き、編集したければ gpkg へ **変換（置き換え）** する。

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
| Shapefile | `.shp`（`.shx` `.dbf` `.prj` `.cpg` を伴う） | `readers/shapefile_reader.dart`（既存パーサー `parsers/` を fs 経由で） | 1（済） |
| GeoJSON | `.geojson` `.json`（中身が FeatureCollection / Feature のときだけ） | `readers/geojson_reader.dart` | 1（済） |
| KML / KMZ | `.kml` `.kmz` | 新規（純 Dart、KMZ は archive で展開） | 2 |
| CSV（点） | `.csv`（緯度経度・XY 列を推定できたときだけ） | 新規 | 2 |
| GeoTIFF | `.tif` | 既存（オーバーレイ） | 済 |

GDAL は無い（純 Dart）。FlatGeobuf などは要望が来てから。

読み手の一覧は `lib/services/external/external_readers.dart`（拡張子で引く。形式を足すときは 1 行足す）。

### 読み方の細部（2026-10-09 実装）

- shp: `.cpg` があればその文字コード、無ければ Shift_JIS。DBF の文字コードは `charset`（純 Dart）で解く
  （`charset_converter` はプラットフォームチャネルで web とホストのテストに無い）。DBF は fs 経由で読む（web で dart:io に触れない）。
  DBF で削除済みの行のレコードは読み飛ばす（GDAL/QGIS と同じ）。`.prj` があれば WGS84 に直す。
  Z・M 付きの形は XY だけ読む。マルチポイントは最初の点
- GeoJSON: 多重の形（MultiLineString・MultiPolygon）は最初の 1 つだけ（旧来の取り込みと同じ。⚠ 変換すると残りの部分は落ちる）。
  入れ子の属性（オブジェクト・配列）は JSON の文字列。列の型は最初に値が入っていた行で決める。`crs` メンバーは見ない（WGS84 とみなす）
- 付属ファイルは「拡張子を除いた名前 + 付属の拡張子」を大文字小文字を区別せずに探す（`林班.SHP` と `林班.dbf` の混在）
- 列名が gpkg 側の予約名（`fid` `id` `geom` `geometry` `rowid`、大文字小文字を問わない）なら後ろに `_` を足す
  （`FeatureRepository` が黙って捨てていた。shp の `ID` 列は多い）
- 旧来の「取り込み」（`importers/`）は読み手に載せ替えていない。ドラッグ＆ドロップの置き換えで撤去する前提で、そのまま残した

## 仕組み

### ノード

`ExternalLayerNode`（`lib/models/nodes/external_layer_node.dart`）は `GeoPackageNode` の派生で、
**描画・属性表・ヒットテストは裏の「読み込み済み gpkg」に任せる**（描画の経路を 1 本に保つ）。

- `name` は元のファイル名（例 `林班.shp`）、`getAbsoluteFilePath()` は元のファイルのパス
- `geoPackageFile` は `.kokage/cache/external/<元のパスの hash>.gpkg`（プロジェクトルート直下の `.kokage`。同期しない）。
  hash は正規化した元の絶対パスの MD5 の先頭 20 桁（`ExternalLayerCache.cachePathFor`）。ルートが決まっていなければ元と同じ dir の `.kokage`。
  中のレイヤ名は元の名前（拡張子なし）
- キャッシュの作り直しは元ファイル（shp は付属一式）の名前・更新時刻・大きさが変わったとき。印はキャッシュ gpkg の中の
  `kokage_external_source` 表（`key`/`value`。`signature` と `source`）に持つ（キャッシュの都合の印で、真実源ではない）。
  印には読み方の版（`ExternalLayerCache.formatVersion`）も入れる。読み方を変えたら上げると全部作り直す
- web: 消したキャッシュを同じパスで作り直すと sqlite3 WASM 側に残った前の写しが開くので、作り直す前に捨てる
  （`GeoPackageConnection.discardWebCopy`）。キャッシュは fs 経由で書くので web でも同じ置き場
- ツリーには `FolderNode.loadExternalNodes` で載る（グローバル・Drive 連携 dir も同じ経路）。`.json` の中身の判定は
  更新時刻と大きさで控える（フォルダを開くたびに読み直さない）
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
2. 書いた gpkg を開き直し、件数・ジオメトリ型・列名が元と一致するか確かめる。件数とジオメトリ型は元を読み直した値と、
   列名はキャッシュと比べる（列名は gpkg に書くときに整える＝予約名に `_` を足すので、元の名前とは比べられない）。
   食い違えば書いた gpkg を消して元を残す（`ExternalConvertVerifyException`）
3. 一致したら元のファイル一式を消す（shp: `.shp .shx .dbf .prj .cpg .qix .sbn .sbx .shp.xml .fix .aih .ain`）。
   本体を先に消し、消せなければ書いた gpkg を消して元のまま戻し、「自分のフォルダにgpkgとして複製」を出す。
   付属ファイルだけ消せなかったときは残ったものを通知する
4. 親 dir の `updateChildren()`。`.qgs` の参照は次の自動更新で実態に合わせて付け替わる。
   スタイル・View・可視性はレイヤの鍵が変わるので **変換時に新しい鍵へ移す**（フォルダ設定の書き換え）

⚠ 変換後の座標系は EPSG:4326（アプリが作るレイヤはすべて 4326）。元の CRS を保つのは後回し。

### `.qgs` との往復

- 書く: 読み取り専用レイヤは `provider=ogr`、`datasource=./林班.shp`（shp・GeoJSON・KML は `|layername=` なし、
  KMZ・複数レイヤの KML は `|layername=`）。CSV は `delimitedtext` の URI。キャッシュのパスは書かない
  - GeoJSON の型の混在は `|layername=` ではなく `|geometrytype=Point`（`LineString` `Polygon`）。QGIS が同じファイルの
    型ごとのサブレイヤに付ける形で、OGR の GeoJSON はレイヤが 1 枚なので `|layername=<名前>_point` では開けない
  - CRS は `.prj` の WKT をそのまま書く（ESRI 形式の `.prj` は EPSG コードを持たないことが多い。QGIS は WKT から EPSG を引き当てる）。
    `.prj` の無い shp・GeoJSON は EPSG:4326
  - `.cpg` の無い shp は `<provider encoding="Shift_JIS">`（アプリと同じ読み方。`.cpg` があれば GDAL がそれで読む）
  - QGIS 4.2.2 で開いて valid・件数・CRS（平面直角 VI 系の `.prj` → EPSG:6674）・`geometrytype` のサブレイヤを確認（2026-10-09。
    `test/qgs_external_layer_test.dart` を `KOKAGE_KEEP_QGS=<dir>` で走らせると一式が残る）
- 読む（`_SourceResolver`）: ogr の非 gpkg は `ExternalLayerNode` に結びつける（`|layername=` が無ければ、1 レイヤならそれ、
  `geometrytype=` があれば `<名前>_point` など、それ以外はファイル名）。
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

> [!WARNING] キャッシュの `.kokage` を同期から外すこと（未対応・2026-10-09）
> 同期の対象は拡張子（`*.gpkg`）で dir を再帰的にたどるので、プロジェクトルートそのものが Drive 連携 dir だと
> `.kokage/cache/external/*.gpkg` まで上がる。ツリーには出さないようにした（`DriveFolderNode` の子に `.kokage` を出さない）が、
> 同期（`SyncFileOperations.listLocalSyncFiles`）の側でも `.kokage` を飛ばす必要がある

- 同期の対象は拡張子の許可リスト（`SyncFileOperations.syncPatterns`）。対応形式と shp の付属ファイルを足す。
  照合は大文字小文字を区別しない（`IMG.JPG` が落ちていた）
- 手元で消したファイルは Drive では **ゴミ箱行き**（`files.update(trashed: true)`。`files.delete` はどこからも呼ばない）。
  変換で消した shp も 30 日は Drive のゴミ箱から戻せる
- 中身のマージ（geodiff）は gpkg だけ。ほかの形式はファイル丸ごとの新旧で扱う
