---
title: GDAL（Android と web）
tags: [technical, gdal, qgis, interop]
---

# GDAL

2026-10-09 決定。gpkg 以外の形式は **QGIS と同じ GDAL/OGR・PROJ で読む**（互換性が最優先）。
純 Dart の読み手を形式ごとに書く道はやめる（どこまで作っても QGIS の部分的な模倣で、CRS・文字コード・圧縮・オーバービューで差が残る）。

| | 実体 | 呼び方 |
|---|---|---|
| Android | `libgdal.so`（GDAL + PROJ、NDK でビルド、`third_party/gdal/`） | FFI で `gdal_utils.h` の C API |
| web | gdal3.js（WASM、自前ホスト） | `package:web` / `dart:js_interop`。gpkg 以外を開いたときだけ読み込む |
| ホストの単体テスト | Windows: QGIS 同梱の `gdal313.dll`、CI(Linux): `libgdal`（apt） | FFI。無ければそのテストは skip |

窓口は `lib/core/gdal/gdal.dart`（`Gdal`）。GDAL のコマンドラインユーティリティ（`ogr2ogr` `gdalwarp` `gdal_translate`
`gdalinfo -json` `ogrinfo -json`）を **引数の文字列でそのまま** 呼ぶ。gdal3.js も同じ関数群を持つので、2 つの実装が同じ形で揃う。

## 使いどころ

- **読み取り専用レイヤのキャッシュ**: `ogr2ogr -f GPKG <cache> <src>`（座標系は元のまま。アプリは投影座標の gpkg を描ける）
- **gpkg への変換**: キャッシュの複製（= ogr2ogr の出力。元の CRS が保たれる）
- **ラスタのオーバーレイ**: `gdalwarp -t_srs EPSG:4326 -ts <長辺 ≤ 4096>` → `gdal_translate -of PNG`。
  オーバービューがあれば GDAL が自分で使う。四隅は `gdalinfo -json` の `wgs84Extent`
- 範囲は「読む・変換する」だけ。gpkg の編集はこれまでどおり sqflite（同期のマージは geodiff）

## 未決・見張り

- APK の増分（目安 10〜25 MB）。PROJ の `proj.db` は日本で使う座標系に絞れるか
- web の初回読み込み（gdal3.js の WASM は数十 MB）。遅ければ考え直す（2026-10-09 松本「パフォーマンスに影響が出そうならまた考えよう」）
