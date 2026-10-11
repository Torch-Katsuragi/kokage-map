---
name: import-export
description: レイヤの書き出し（GDAL の ogr2ogr）と、gpkg 以外のファイルの読み取りの実装ガイド。Shapefile・GeoJSON・KML・CSV などの入出力、座標系、文字コードを触る際に使用。
---

# Import/Export 実装ガイド

## 詳細資料

| 資料 | パス |
|------|------|
| レイヤの書き出し | `docs/technical/import-export.md` |
| GDAL の呼び方（Android・web） | `docs/technical/gdal.md` |
| gpkg 以外のファイルを読み取り専用レイヤに | `docs/technical/external-formats.md` |

## 原則

- 形式の読み書きは **GDAL**（QGIS と同じ部品）。純 Dart で形式ごとの読み手・書き手を書かない（2026-10 に全部消した）
- 書き出しは `ImportExportService.exportLayer` → レイヤの gpkg から `ogr2ogr`。引数は `ImportExportService.exportArgs`
- 取り込みは無い。gpkg 以外のファイルはフォルダに置けば読み取り専用レイヤになり、必要なら「gpkgに変換」
- GDAL は `ExternalGdal.instance`（テストで差し替える）。パスは `fs` のパス（web は OPFS）
- 書き出しの前に `flushChanges()` と `checkIn()`（web は OPFS の元ファイルへ書き戻さないと GDAL が古い中身を読む）

## 落とし穴

- shp を書くときは `-lco ENCODING=UTF-8`（付けないと ISO-8859-1 で日本語が落ちる）
- アプリの点レイヤは MULTIPOINT 宣言に POINT が入っている。shp・CSV の X/Y・GPX は `-nlt POINT`
- GeoJSON（RFC 7946）・KML・GPX は WGS 84 だけ
- テストで GDAL を使うときは `setUpAll` で GDAL の `version()` を sqflite より先に呼ぶ（QGIS の DLL 群と sqlite3.dll の読み込み順）。
  shp の用意は `test/support/shp_fixture.dart`
