---
title: GDAL（Android と web）
tags: [technical, gdal, qgis, interop]
---

# GDAL

2026-10-09 決定。gpkg 以外の形式は **QGIS と同じ GDAL/OGR・PROJ で読む**（互換性が最優先）。
純 Dart の読み手を形式ごとに書く道はやめる（どこまで作っても QGIS の部分的な模倣で、CRS・文字コード・圧縮・オーバービューで差が残る）。

| | 実体 | 呼び方 |
|---|---|---|
| Android | `libgdal.so`（GDAL 3.13.3 + PROJ 9.9.0、NDK でビルド、[[../../third_party/gdal/README|third_party/gdal]]） | FFI で `gdal_utils.h` の C API（`gdal_ffi.dart`） |
| web | gdal3.js（WASM、自前ホスト） | `package:web` / `dart:js_interop`（`gdal_web.dart`）。gpkg 以外を開いたときだけ読み込む |
| ホストの単体テスト | Windows: QGIS 同梱の `gdal313.dll`、CI(Linux): `libgdal`（apt の `libgdal-dev`） | FFI。無ければそのテストは skip |

窓口は `lib/core/gdal/gdal.dart`（`Gdal`）。GDAL のコマンドラインユーティリティ（`ogr2ogr` `gdalwarp` `gdal_translate`
`gdalinfo -json` `ogrinfo -json`）を **引数の文字列でそのまま** 呼ぶ。gdal3.js も同じ関数群を持つので、2 つの実装が同じ形で揃う。
実装は `gdal_provider.dart` の `createGdal()` で得る（各実装ファイルが同名のトップレベル関数を持つ取り決め）。

## 使いどころ

- **読み取り専用レイヤのキャッシュ**: `ogr2ogr -f GPKG <cache> <src>`（座標系は元のまま。アプリは投影座標の gpkg を描ける）
- **gpkg への変換**: キャッシュの複製（= ogr2ogr の出力。元の CRS が保たれる）
- **ラスタのオーバーレイ**: `gdalwarp -t_srs EPSG:4326 -ts <長辺 ≤ 4096>` → `gdal_translate -of PNG`。
  オーバービューがあれば GDAL が自分で使う。四隅は `gdalinfo -json` の `wgs84Extent`
- 範囲は「読む・変換する」だけ。gpkg の編集はこれまでどおり sqflite（同期のマージは geodiff）

## Android の実装で決めたこと（2026-10-09）

- **入れたドライバ**: ラスタは GTiff（COG）・PNG・JPEG・GPKG・MEM・VRT、ベクタは GPKG・Shapefile・GeoJSON（Seq 含む）・KML・CSV・
  FlatGeobuf・GPX・GML・DXF・MapInfo・OpenFileGDB・VRT。ネットワーク系・LIBKML は無し
- **1 本の `.so`**。PROJ・SQLite・expat・libiconv は静的に入れてシンボルを隠す（sqflite・geodiff の SQLite とぶつからない）
- **libiconv を入れた**: API 24 の bionic に iconv が無く、無いと Shift_JIS の shp が読めない
- **proj.db と GDAL_DATA はアセット**（`assets/gdal/`、Android だけ）。初回に `<support dir>/gdal/` へ書き出して
  `OSRSetPROJSearchPaths` / `GDAL_DATA` を向ける。版が変わったら書き直す（`_dataStamp`）。
  GDAL_DATA は DXF の書き出しに必須で、基盤地図情報の GML（`jpfgdgml_*.gfs`）の読み取りにも使う
- **proj.db は絞らない**: IAU・IGNF・NKG・NRCAN を落として 10.3 → 8.2 MB、ESRI も落として 6.9 MB だが、
  APK で減るのは圧縮後 0.2〜0.5 MB だけ。ESRI は shp の `.prj` の同定に要る
- **PROJ のグリッドは無し**（TIFF・ネットワークなし）。JGD2011 ⇔ WGS84 は影響なし。旧日本測地系 ⇔ JGD は近似（数 m）
- **shp の文字コード**: `.cpg` か DBF の LDID があれば GDAL の判定どおり。どちらも無いときは CP932 とみなす（`-oo ENCODING=CP932` を足す）。
  GDAL 単体はこの場合に変換せずバイト列を返し（Shift_JIS が化ける）、QGIS は「システムの文字コード」で読み直すので
  日本語版 Windows の QGIS では CP932 に見える。その見え方に合わせた。呼ぶ側が `-oo ENCODING=...` を渡せばそちらが勝つ。
  `SHAPE_ENCODING`（設定オプション）は `.cpg` まで上書きしてしまうので使わない
- ⚠ shp を **書く** ときは `-lco ENCODING=UTF-8` を付ける。付けないと GDAL は ISO-8859-1 で書き、日本語が落ちる（QGIS の新規 shp は UTF-8）
- **スレッド**: 呼び出しは 1 回ごとに `Isolate.run`（別スレッド）で、開いて閉じるまでを同期で済ませる。データセットのハンドルはスレッドをまたがない。
  プロセス全体の設定（ドライバ登録・データの在処・`PROJ_NETWORK=OFF`・エラーハンドラ）は最初の 1 回だけ、ほかの呼び出しより先に
- **エラー**: スレッドに GDAL 自身の静かなハンドラを積み、`CPL_ACCUM_ERROR_MSG=ON`（スレッドローカル）で途中のエラーも溜めて
  `GdalException` にする（ogr2ogr は最後に「途中で止めた」としか言わない）。Dart のコールバックは GDAL の作業スレッドから呼ばれうるので使わない
- **C API の引数**: データセットは呼ぶ側が開くので、`-oo`（オープンオプション）と `-if`（ドライバ）は抜き出して `GDALOpenEx` に渡す

## 大きさ（2026-10-09）

| | 大きさ |
|---|---|
| `libgdal.so` arm64-v8a / x86_64 / armeabi-v7a（-Os、strip 済み） | 20.1 / 20.7 / 14.5 MB |
| `proj.db` / `gdal_data.zip` | 10.6 MB / 0.15 MB |
| APK の増分（3 ABI 入りの release APK） | 約 57.4 MB（.so 55.3 MB は無圧縮で入る ＋ アセット 2.1 MB） |
| Play（ABI ごと）で arm64 端末に入る分 | 約 22 MB（ダウンロードは約 10 MB）＋ 初回の書き出し約 11 MB |

当初の目安（10〜25 MB）は ABI ごとの配布なら収まる。3 ABI 入りの APK を直接配る場面では大きい
（詳細は [[../../third_party/gdal/README#大きさ（2026-10-09、-Os）|third_party/gdal]]）。

## 未決・見張り

- web の初回読み込み（gdal3.js の WASM は数十 MB）。遅ければ考え直す（2026-10-09 松本「パフォーマンスに影響が出そうならまた考えよう」）
- 実機（Pixel 9）での確認は `integration_test/device/gdal_smoke_test.dart`。armeabi-v7a は手元に実機が無く未確認
