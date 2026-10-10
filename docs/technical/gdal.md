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
  オーバービューがあれば GDAL が自分で使う。四隅はワープ後の `geoTransform`（2026-10-10 実装、
  [[external-formats#ラスタのオーバーレイ（GDAL、2026-10-10）]]）
- 範囲は「読む・変換する」だけ。gpkg の編集はこれまでどおり sqflite（同期のマージは geodiff）

## 実装の選び方

`lib/core/gdal/gdal_provider.dart` の `createGdal()`。各実装ファイルが同じ名前のトップレベル関数を持つ。

```dart
export 'gdal_stub.dart' if (dart.library.ffi) 'gdal_ffi.dart' if (dart.library.js_interop) 'gdal_web.dart';
```

## web（gdal3.js）

2026-10-09 実装（`lib/core/gdal/gdal_web.dart`、`web/gdal3/worker.js`）。

| | |
|---|---|
| gdal3.js | **2.8.1**（npm の最新安定版、2024-02。LGPL-2.1-or-later） |
| 中の GDAL / PROJ | **3.8.4** / 9.3.1（`GDALVersionInfo` は WASM から書き出されていないので、`version()` は定数で返す） |
| 置き場所 | `web/gdal3/2.8.1/`（`tool/web/fetch_gdal3.sh` で取る。リポジトリには入れない）、`web/gdal3/worker.js`（自前、リポジトリに入れる） |

> [!NOTE] 3.0.0 は beta（2026-05 の beta.4 は GDAL 3.12.4・PROJ 9.8.1）
> 作りが変わっている（`gdal3js-wasm-wasm32-{st,mt}-release.browser.wasm` など、st/mt の 2 系統）。安定版が出たら上げる。
> QGIS 4.2 の GDAL は 3.13 なので、それまでは web だけ GDAL が古い。

### 大きさ（2.8.1）

| ファイル | そのまま | gzip -9 | brotli 11 |
|---|---|---|---|
| `gdal3WebAssembly.wasm` | 28.2 MB | 9.07 MB | 6.61 MB |
| `gdal3WebAssembly.data`（GDAL_DATA・proj.db） | 11.6 MB | 2.09 MB | 1.41 MB |
| `gdal3.js` | 191 KB | 48 KB | 41 KB |
| 計 | 40.0 MB | 11.2 MB | 8.1 MB |

リポジトリ（pack 23.6 MB）に入れると 1.5 倍になり、版を上げるたびに 11 MB ずつ積もる。だから取得スクリプトで置く
（版と SHA-256 は `fetch_gdal3.sh` に固定。tarball と中の 3 ファイルの両方を照合する）。
`flutter build web` は `web/` を丸ごと `build/web/` に写すので、スクリプトを回してからビルドすれば配られる。
置き忘れると最初の呼び出しが「web/gdal3/ が配られているか」の `GdalException` になる（rewrites で index.html が返り、worker が読めない）。

### 仕組み

- **gpkg 以外を開いたときだけ読み込む**: 最初の呼び出しで worker（`web/gdal3/worker.js`）を起こし、その中で
  `importScripts(gdal3.js)` → `initGdalJs({useWorker: false})`。主スレッドには何も差し込まない
- gdal3.js の JS 関数（`Gdal.ogr2ogr` など）と、gdal3.js 自身の worker 方式（`initGdalJs({useWorker: true})`）は使わない。
  同梱の emscripten Module から `GDALVectorTranslate` などを cwrap して、**引数の文字列をそのまま** 渡す（FFI 版と同じ形）。理由:
  - gdal3.js の `ogr2ogr` は出力を `/output/<名前>.<-f から決めた拡張子>` に固定する。出力先の拡張子で形式を決められない
  - 出力を MEMFS から消す口が無い（呼ぶたびに worker のメモリが増える）
  - `open` が毎回 gdalinfo / ogrinfo を走らせ、1 回の操作が 3 往復になる。並んだ呼び出しどうしで入力の mount を外し合う
- 1 回の呼び出し = worker への 1 メッセージ（開く → 実行 → 閉じる → 出力を集めて消す）。`--config K V` は thread-local で掛けて外す
- 入力: `fs` のパスと同じフォルダの「同じ名前.何か」（shp の付属一式、`.aux.xml` `.ovr` `.tfw` …、大文字小文字は問わない）を
  OPFS / フォルダハンドルの `File` のまま渡し、worker が WORKERFS で mount する。**中身はコピーしない**（GDAL が読んだ分だけ切り出す）
- 出力: worker の MEMFS（`/output/j<n>/<書き出し先の名前>`）に書かせ、できたファイルを全部 `fs.writeAsBytes` で書き出し先のフォルダへ
  （shp なら付属ファイル、PNG なら `.aux.xml` も）。ArrayBuffer は transfer なので、コピーは MEMFS から読む 1 回だけ
- 書き出し先が既にあれば（gdal_translate 以外）その一式を先に MEMFS に置く。`-update` `-append` `-overwrite`、gdalwarp の既存への書き込みが
  コマンドラインと同じに振る舞う
- WASM が abort したら（メモリ不足など）worker を捨て、次の呼び出しで読み込み直す
- `SharedArrayBuffer` は使わない（2.8.1 は単一スレッドのビルド）ので、COOP/COEP は要らない

> [!WARNING] 大きいファイル
> 入力はコピーしないが、**出力は丸ごとメモリに載る**（MEMFS → 主スレッド → OPFS）。数百 MB の出力は避ける。
> WASM のヒープは wasm32 なので上限 4 GB（ブラウザによっては 2 GB）。ラスタのオーバーレイは `-ts` で長辺を絞って出す前提。
> 引数の中のパス（`-clipsrc other.shp` など）とフォルダのデータセット（FileGDB など）は渡らない。

### 速さ（2026-10-09、メインPC、Chrome 系の内蔵ブラウザ、127.0.0.1 から配信）

| | 時間 |
|---|---|
| 初回の読み込み（キャッシュ無し、`version()` まで） | 0.60 秒 |
| 2 回目以降の起動（HTTP キャッシュあり。WASM のコンパイル込み） | 0.71 秒 |
| ogr2ogr: shp 3 件 → GPKG | 初回 0.48 秒、2 回目 0.10 秒 |
| gdalwarp: GeoTIFF 1024² → EPSG:4326 | 初回 0.63 秒、2 回目 0.27 秒 |
| gdalwarp: GeoTIFF 4000² → EPSG:4326、長辺 4096（出力 16 MB） | 2.0 秒 |
| gdal_translate: 1024² GeoTIFF → PNG | 0.9 秒 |
| ogrinfo / gdalinfo（小さいもの） | 0.1〜0.2 秒 |

手元の配信なので、実際の初回は **ダウンロード（gzip で約 11 MB）** が上乗せになる。WASM のコンパイルだけで 0.34 秒。
タブが隠れていると数倍遅く出る（測るときは見えている画面で）。

### 確かめ方

`--dart-define=K_LOG=true` でビルドすると `window.kokageGdal` が出る（`lib/core/gdal/gdal_debug_hook_web.dart`。製品版には出ない）。
OPFS にテスト用フォルダを入れて（[[cli-launch#web を外から動かす（OPFS、2026-09-30）]]）`#/map?project=opfs:<名前>` で開き、コンソールから:

```js
JSON.parse(await kokageGdal.version())                                     // {ok, ms, result: "3.8.4"}
JSON.parse(await kokageGdal.vectorTranslate('/T/a.shp', '/T/a.gpkg', ['-f', 'GPKG']))
JSON.parse(await kokageGdal.warp('/T/dem.tif', '/T/out/dem.tif', ['-t_srs', 'EPSG:4326', '-ts', '1024', '0']))
kokageGdal.loadMs()                                                         // 初回の読み込みにかかった ms
```

ログ（`[Gdal] ...`、GDAL の stderr も）はアプリの LOG チップに出る。

### 版の上げ方

1. `tool/web/fetch_gdal3.sh` の `VERSION` と SHA-256（tarball と 3 ファイル）を書き換えて回す
2. `gdal_web.dart` の `kGdal3Version` と `_gdalRelease`（WASM の中の `GDAL 3.x.y` の文字列で確かめる）
3. `web/gdal3/<旧版>/` を消す。キャッシュは版のフォルダごとに 1 年（`firebase.json`）なので、フォルダ名を変えれば入れ替わる

## 未決・見張り（web）

- web の初回読み込み: 手元配信では 0.6 秒で、残りはダウンロード（gzip 11 MB）。gpkg 以外を開いたときだけ払う。
  ⚠ Firebase Hosting が `.wasm` / `.data` を圧縮して返すかは本番で未確認（`.data` は `application/octet-stream` なので圧縮されないかもしれない。
  されなければ 11.6 MB そのまま）。デプロイ後に `content-encoding` を見る
  （2026-10-09 松本「パフォーマンスに影響が出そうならまた考えよう」）

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
  - FFI 版は `gdal_ffi.dart` が自分で足す。web 版は足さないので、読み取り専用レイヤは呼ぶ側（`ExternalSource.openArgs`）でも同じ判定で渡す。
    `.qgs` には `<provider encoding="CP932">` と書く（2026-10-10）
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

## 未決・見張り（Android）

- 実機（Pixel 9）での確認は `integration_test/device/gdal_smoke_test.dart`。armeabi-v7a は手元に実機が無く未確認
