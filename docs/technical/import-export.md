---
title: レイヤの書き出し（GDAL）
tags: [technical, architecture, export, gdal]
---

# レイヤの書き出し

2026-10-10 に純 Dart の書き出し（Shapefile・GeoJSON・KML・CSV を自前で組む）をやめ、**レイヤの gpkg を GDAL の `ogr2ogr` で書く** 形にした。
QGIS の「名前を付けて保存」と同じ部品（[[gdal]]）なので、文字コード・座標系・型の扱いが QGIS と揃う。
取り込みの純 Dart 実装（`importers/`・`parsers/`）も同時に消した。gpkg 以外のファイルはフォルダに置けば読み取り専用レイヤになる（[[external-formats]]）。

## 構成

| ファイル | 役目 |
|---|---|
| `lib/services/import_export/import_export_models.dart` | `FileFormat`（表示名・拡張子・GDAL のドライバ・WGS 84 固定か）、`ExportOptions`、`ImportExportResult` |
| `lib/services/import_export/import_export_service.dart` | `exportArgs()`（ogr2ogr の引数）と `exportLayer()` |
| `lib/widgets/layer_import_export_dialog.dart` | 書き出しダイアログ。一時フォルダに書いて、zip（shp）にしてから `FilePicker.saveFile` |

## 流れ

1. `GeoPackageFile.flushChanges()` で保存待ちの編集を gpkg へ、`checkIn()` で web の sqlite3 WASM の写しを元ファイル（OPFS）へ
2. `ExternalGdal.instance.vectorTranslate(<gpkg>, <書き出し先>, args: exportArgs(...))`。ソースのレイヤ名を位置引数で渡す
3. ダイアログは一時フォルダ（Android はアプリのキャッシュ、web は `<プロジェクト>/.kokage/tmp/kokage_export_*`）に書き、
   Shapefile は付属ファイルごと zip にして保存ダイアログへ渡す。終わったら一時フォルダを消す。
   file_picker の `saveFile` は中身を先に渡す作り（Android の SAF は保存先を選んでから書けない）なので、この順になる

対象はレイヤ全体（View の絞り込みは掛けない。ダイアログはレイヤの行のメニューからだけ開く）。

## 形式ごとの引数

| 形式 | ドライバ | 引数 | 決めたこと |
|---|---|---|---|
| GeoPackage | `GPKG` | — | |
| Shapefile | `ESRI Shapefile` | `-lco ENCODING=UTF-8` | QGIS の新規 shp と同じ UTF-8 ＋ `.cpg`。CP932 にはしない（古いソフト向けの CP932 が要る場面が出たら選択肢にする）。付けないと GDAL は ISO-8859-1 で書き日本語が落ちる |
| GeoJSON | `GeoJSON` | `-t_srs EPSG:4326 -lco RFC7946=YES` | RFC 7946 は WGS 84 だけ |
| KML | `KML` | `-t_srs EPSG:4326` | KML は WGS 84 だけ。`name`・`description` は `<name>`・`<description>`、ほかは ExtendedData |
| CSV | `CSV` | 点 `-lco GEOMETRY=AS_XY`、ほか `GEOMETRY=AS_WKT` | WKT の列名は形の列の名前（`geom`）。BOM は付けない（QGIS の既定と同じ） |
| GPX | `GPX` | `-t_srs EPSG:4326 -dsco GPX_USE_EXTENSIONS=YES` | 点は waypoints、線は tracks。面のレイヤでは選択肢に出さない |
| FlatGeobuf | `FlatGeobuf` | — | |
| DXF | `DXF` | `-select ''` | 任意の属性列を持てないので形だけ。GDAL_DATA の `header.dxf` が要る |

- **座標系**: 既定はレイヤのまま（平面直角の gpkg は平面直角の shp に、`.prj` は ESRI WKT）。ダイアログで選べば `-t_srs`。
  GeoJSON・KML・GPX は選ばせない（4326 固定）
- **点**: アプリの点レイヤは MULTIPOINT と宣言して POINT を入れている。Shapefile・CSV（X/Y）・GPX は `-nlt POINT` を付けて点として書く
  （付けないと「MultiPoint の shp に POINT は書けない」で止まる。MultiPoint の shp は古いソフトが読めないこともある）
- **行番号**: `ExportOptions.includeRowNumber` で
  `-sql 'SELECT *, ROW_NUMBER() OVER (ORDER BY "<主キー>") AS ROW_NUM FROM "<レイヤ>"' -nln <レイヤ>`（属性表の # と同じ順）。DXF では付けない
- 「ポイントクラウドとしてエクスポート」は旧実装でもどの形式も読んでいなかったので外した（頂点を点にしたいなら QGIS の「頂点を抽出」）

## テスト

- `test/import_export_service_test.dart`: 形式と `exportArgs()`（GDAL を呼ばない）
- `test/layer_export_test.dart`: ホストの GDAL（QGIS の `gdal*.dll`）で書き出し、`vectorInfo` で読み直す。
  日本語の属性の shp（`.cpg`）・GeoJSON の全属性と 4326・KML・CSV の X/Y と WKT・6674 の gpkg → shp が 6674・行番号・保存待ちの編集
- テストで shp を用意するときは `test/support/shp_fixture.dart`（GDAL で書く。`.cpg` も LDID も無い古い shp も作れる）

## GeoPackage 互換性に関する注意事項

### 仮想カラム（`_`で始まるカラム名）

`_`で始まるカラム名は**仮想カラム**として扱う。

| カラム名 | 用途 | 備考 |
|---------|------|------|
| `_row_num` | 行番号表示 | 属性テーブルUIで自動生成 |
| `_lat`, `_lon` | WGS84座標表示 | Pointレイヤーで座標表示時 |
| `_x`, `_y` | 変換座標表示 | EPSG指定時の座標変換結果 |

- 仮想カラムは**表示専用**であり、GeoPackageには保存されない
- 外部ツールで作成したGeoPackageに`_`で始まるカラムが存在する場合、アプリでは**編集不可**となる（意図しない上書きを防ぐため）

### PRIMARY KEY カラムの扱い

- 属性テーブルUIでは、PRIMARY KEYカラム（`fid`, `id`など）は非表示
- 新規追加したフィーチャのPRIMARY KEY値は内部的に自動採番されるが、表示には行番号（`#`）を使う

## 関連ドキュメント

- [[gdal]] - GDAL の呼び方（Android・web）
- [[external-formats]] - gpkg 以外のファイルを読み取り専用レイヤにする
- [[../features/geometry-types]] - レイヤジオメトリタイプ仕様
