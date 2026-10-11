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
| web | 同じ GDAL 3.13.3 + PROJ 9.9.0 を emscripten で WASM に（同じドライバの組、[[../../third_party/gdal/README#web（WASM）|third_party/gdal]]、自前ホスト） | worker の中で同じ C API を cwrap（`web/gdal3/worker.js`）、Dart からは `package:web`（`gdal_web.dart`）。gpkg 以外を開いたときだけ読み込む |
| ホストの単体テスト | Windows: QGIS 同梱の `gdal313.dll`、CI(Linux): `libgdal`（apt の `libgdal-dev`） | FFI。無ければそのテストは skip |

窓口は `lib/core/gdal/gdal.dart`（`Gdal`）。GDAL のコマンドラインユーティリティ（`ogr2ogr` `gdalwarp` `gdal_translate`
`gdalinfo -json` `ogrinfo -json`）を **引数の文字列でそのまま** 呼ぶ。web も同じ版の同じ関数を WASM から呼ぶので、2 つの実装が同じ形・同じ結果で揃う。
実装は `gdal_provider.dart` の `createGdal()` で得る（各実装ファイルが同名のトップレベル関数を持つ取り決め）。

## 使いどころ

- **読み取り専用レイヤのキャッシュ**: `ogr2ogr -f GPKG <cache> <src>`（座標系は元のまま。アプリは投影座標の gpkg を描ける）
- **gpkg への変換**: キャッシュの複製（= ogr2ogr の出力。元の CRS が保たれる）
- **ラスタのオーバーレイ**: `gdalwarp -t_srs EPSG:4326 -ts <長辺 ≤ 4096>` → `gdal_translate -of PNG`。
  オーバービューがあれば GDAL が自分で使う。四隅は `gdalinfo -json` の `wgs84Extent`
- 範囲は「読む・変換する」だけ。gpkg の編集はこれまでどおり sqflite（同期のマージは geodiff）

## 実装の選び方

`lib/core/gdal/gdal_provider.dart` の `createGdal()`。各実装ファイルが同じ名前のトップレベル関数を持つ。

```dart
export 'gdal_stub.dart' if (dart.library.ffi) 'gdal_ffi.dart' if (dart.library.js_interop) 'gdal_web.dart';
```

## web（WASM）

2026-10-09 に gdal3.js 2.8.1（GDAL 3.8.4）で実装し、2026-10-11 に **Android と同じ GDAL 3.13.3 + PROJ 9.9.0 の自前ビルド** に替えた
（互換性が最優先。web だけ GDAL が古く、shp の文字コードや `-oo` の扱いも違っていた）。

| | |
|---|---|
| 中身 | GDAL **3.13.3** / PROJ **9.9.0** / expat 2.9.0 / GNU libiconv 1.18 / SQLite 3.53.4 / zlib 1.3.2（emscripten の port）。ドライバは Android と同じ組 |
| 作り方 | `third_party/gdal/build_web.sh`（WSL、emsdk 6.0.12 を commit で固定）。単一スレッド・`-Os`・WebAssembly の例外 |
| 置き場所 | `web/gdal3/<組>/`（組 = `3.13.3-1`。`gdal.js` `gdal.wasm` `gdal.data` `LICENSE`、リポジトリには入れない）、`web/gdal3/worker.js`（自前、リポジトリに入れる） |
| 配り方 | GitHub の Release（タグ `gdal-wasm-<組>`）に上げ、`tool/web/fetch_gdal_wasm.sh` が SHA-256 を照合して置く。CI の build (web) も同じ |
| `version()` | WASM の `GDALVersionInfo("RELEASE_NAME")`（定数ではない） |

フォルダ名の `gdal3` は GDAL 3 系の意味でそのまま使っている（gdal3.js の名残だが、パスを変えると Firebase のヘッダ・文書が全部動くので変えない）。

### 配り方を Release にした理由

- リポジトリに入れない（前回と同じ判断）。40 MB → 24 MB に減ったが、焼き直すたびに gzip で 7 MB ずつ積もる
- 自前のビルドなので npm のような取得元が無い。`kokage-map-data`（DEM 用に構想）はまだ無く、docs にも無い。
  リポジトリの Release なら置き場を増やさずに済み、URL が組（タグ）ごとに固定される
- 手元では `build_web.sh` が `web/gdal3/<組>/` に直接書くので、Release が無くても回る。`fetch_gdal_wasm.sh` は「揃っている」で終わる
- ⚠ **Release の作成と 4 ファイルの upload は人の作業**（`fetch_gdal_wasm.sh` の冒頭に `gh release create` の書き方）。上げるまで CI の build (web) は取得で落ちる

### GDAL_DATA と proj.db（gdal.data）

emscripten の `--preload-file` で 1 本の `gdal.data` にし、起動時に MEMFS へ展開する（`/gdal_data`、`/proj/proj.db`）。
中身は Android の `gdal_data.zip` と `proj.db` と同じ。WASM に埋め込む（`EMBED_RESOURCE_FILES`）と WASM が 10 MB 太り、
コンパイルとキャッシュを分けられないので、gdal3.js と同じ別ファイルにした。

### 大きさ（3.13.3-1）

| ファイル | そのまま | gzip -9 | brotli 11 | 参考: 2.8.1 そのまま / gzip / brotli |
|---|---|---|---|---|
| `gdal.wasm` | 12.3 MB | 4.81 MB | 3.61 MB | 28.2 / 9.07 / 6.61 MB |
| `gdal.data`（GDAL_DATA・proj.db） | 11.8 MB | 2.03 MB | 1.37 MB | 11.6 / 2.09 / 1.41 MB |
| `gdal.js` | 93 KB | 25 KB | 22 KB | 191 / 48 / 41 KB |
| 計 | **24.2 MB** | **6.86 MB** | **5.00 MB** | 40.0 / 11.2 / 8.1 MB |

WASM が半分以下になったのはドライバを Android と同じ組に絞ったから（gdal3.js は netCDF・HDF・PDF なども持っていた）。

`flutter build web` は `web/` を丸ごと `build/web/` に写すので、取得スクリプトを回してからビルドすれば配られる。
置き忘れると最初の呼び出しが「web/gdal3/ が配られているか」の `GdalException` になる（rewrites で index.html が返り、worker が読めない）。

### 仕組み

- **gpkg 以外を開いたときだけ読み込む**: 最初の呼び出しで worker（`web/gdal3/worker.js`）を起こし、その中で
  `importScripts(gdal.js)` → `createGdalModule()`。主スレッドには何も差し込まない
- worker は GDAL の C API（`GDALVectorTranslate` など）を cwrap して **引数の文字列をそのまま** 渡す（FFI 版と同じ形）。
  書き出す関数は `build_web.sh` の `EXPORTS` に並べてある（足すときは両方）
- **FFI 版と振る舞いを揃えている**: プロセス全体の設定（`OSRSetPROJSearchPaths`・`GDAL_DATA`・`PROJ_NETWORK=OFF`）はドライバ登録の前に 1 回、
  `-oo` `-if` は抜き出して `GDALOpenEx` に、`.cpg` も LDID も無い shp は `-oo ENCODING=CP932`、1 回の呼び出しのあいだ `CPL_ACCUM_ERROR_MSG=ON`、
  エラーの文言も同じ形。gdal3.js の頃はこのうち CP932 と `-oo` が web に無かった
- 1 回の呼び出し = worker への 1 メッセージ（開く → 実行 → 閉じる → 出力を集めて消す）。`--config K V` は thread-local で掛けて外す
- 入力: `fs` のパスと同じフォルダの「同じ名前.何か」（shp の付属一式、`.aux.xml` `.ovr` `.tfw` …、大文字小文字は問わない）を
  OPFS / フォルダハンドルの `File` のまま渡し、worker が WORKERFS で mount する。**中身はコピーしない**（GDAL が読んだ分だけ切り出す）
- 出力: worker の MEMFS（`/output/j<n>/<書き出し先の名前>`）に書かせ、できたファイルを全部 `fs.writeAsBytes` で書き出し先のフォルダへ
  （shp なら付属ファイル、PNG なら `.aux.xml` も）。ArrayBuffer は transfer なので、コピーは MEMFS から読む 1 回だけ
- 書き出し先が既にあれば（gdal_translate 以外）その一式を先に MEMFS に置く。`-update` `-append` `-overwrite`、gdalwarp の既存への書き込みが
  コマンドラインと同じに振る舞う
- WASM が abort したら（メモリ不足など）worker を捨て、次の呼び出しで読み込み直す
- 単一スレッドのビルド（`-pthread` なし）なので `SharedArrayBuffer` は使わず、COOP/COEP は要らない。
  `-sDYNAMIC_EXECUTION=0` で eval / `new Function` を出さない（CSP）

> [!WARNING] 大きいファイル
> 入力はコピーしないが、**出力は丸ごとメモリに載る**（MEMFS → 主スレッド → OPFS）。数百 MB の出力は避ける。
> WASM のヒープは wasm32 なので上限 4 GB（`-sMAXIMUM_MEMORY=4GB`。ブラウザによっては 2 GB）。2 GB を超えたポインタは JS では負の数になりうるので、
> worker はヒープを `>>> 0` / `HEAPU32[p >>> 2]` で引く。ラスタのオーバーレイは `-ts` で長辺を絞って出す前提。
> 引数の中のパス（`-clipsrc other.shp` など）とフォルダのデータセット（FileGDB など）は渡らない。

### 速さ（2026-10-11、matsumoto_tabPC、内蔵ブラウザ、127.0.0.1 から配信）

| | 3.13.3-1 | 参考: 2.8.1（2026-10-09、メインPC） |
|---|---|---|
| 初回の読み込み（キャッシュ無し、`version()` まで） | 0.91 秒（※ タブが隠れた状態） | 0.60 秒 |
| 2 回目以降の起動（HTTP キャッシュあり。WASM のコンパイル込み） | 0.46 秒（※ 同上） | 0.71 秒 |
| ogr2ogr: shp → GPKG | 初回 0.48 秒、2 回目 0.10 秒（1 件） | 初回 0.48 秒、2 回目 0.10 秒（3 件） |
| gdalwarp: GeoTIFF 1024²（Float32）→ EPSG:4326 | 初回 0.45 秒、2 回目 0.30 秒 | 初回 0.63 秒、2 回目 0.27 秒 |
| gdalwarp: GeoTIFF 4000²（Float32）→ EPSG:4326、長辺 4096（出力 56 MB） | 2.0 秒 | 2.0 秒（出力 16 MB） |
| gdal_translate: 1024² GeoTIFF → PNG（`-scale`） | 0.33 秒 | 0.9 秒 |
| ogrinfo / gdalinfo（小さいもの） | 0.05〜0.12 秒 | 0.1〜0.2 秒 |

PC とテストデータが前回と違う（今回は一様な値の LZW GeoTIFF）ので、目安の比較。遅くはなっていない。
手元の配信なので、実際の初回は **ダウンロード（gzip で約 6.9 MB）** が上乗せになる。タブが隠れていると数倍遅く出る。

確かめたこと（2026-10-11）: `version()` = `3.13.3`、Shift_JIS の shp（`.cpg` なし・LDID 0）が CP932 で読め、GPKG にしても EPSG:6674 のまま、
`.cpg` ありの shp、KML（`Name`）、CSV（`-oo X_POSSIBLE_NAMES` で点に）、shp の書き出し（`-lco ENCODING=UTF-8`、付属 5 ファイル）、
DXF の書き出し（GDAL_DATA の雛形）、EPSG:6674 の GeoTIFF の `gdalinfo`（`wgs84Extent`）と EPSG:4326 への gdalwarp、PNG への gdal_translate。

### 確かめ方

`--dart-define=K_LOG=true` でビルドすると `window.kokageGdal` が出る（`lib/core/gdal/gdal_debug_hook_web.dart`。製品版には出ない）。
OPFS にテスト用フォルダを入れて（[[cli-launch#web を外から動かす（OPFS、2026-09-30）]]）`#/map?project=opfs:<名前>` で開き、コンソールから:

```js
JSON.parse(await kokageGdal.version())                                     // {ok, ms, result: "3.13.3"}
JSON.parse(await kokageGdal.vectorTranslate('/T/a.shp', '/T/a.gpkg', ['-f', 'GPKG']))
JSON.parse(await kokageGdal.warp('/T/dem.tif', '/T/out/dem.tif', ['-t_srs', 'EPSG:4326', '-ts', '1024', '0']))
kokageGdal.loadMs()                                                         // 初回の読み込みにかかった ms
```

- 引数の配列は省かない（`vectorInfo(path)` だけだと dart2js の型で落ちる。`[]` を渡す）
- `web_opfs.py <dir>` で `seed(..., 'T')` すると、`<dir>` の中身が `/T/` の下に入る（`<dir>/T/` を作って配ると `/T/T/` になる）

ログ（`[Gdal] ...`、GDAL の stderr も）はアプリの LOG チップに出る。

### 組の上げ方（焼き直し）

1. `third_party/gdal/build_web.sh` の版・引数を変え、`BUILD` の末尾の番号を上げて焼く（GDAL / PROJ の版は `build_android.sh` と組で）
2. 最後に出る `SHA256SUMS` を `tool/web/fetch_gdal_wasm.sh` に写し、`BUILD` を揃える。`gdal_web.dart` の `kGdalWasmBuild` も
3. Release `gdal-wasm-<組>` を作って 4 ファイルを上げる（人の作業）
4. `web/gdal3/<旧組>/` を消す。キャッシュは組のフォルダごとに 1 年（`firebase.json`）なので、フォルダ名を変えれば入れ替わる

## 未決・見張り（web）

- web の初回読み込み: 手元配信では 0.5〜0.9 秒で、残りはダウンロード（gzip 6.9 MB / brotli 5.0 MB）。gpkg 以外を開いたときだけ払う。
  ⚠ Firebase Hosting が `.wasm` / `.data` を圧縮して返すかは本番で未確認（`.data` は `application/octet-stream` なので圧縮されないかもしれない。
  されなければ 11.8 MB そのまま）。デプロイ後に `content-encoding` を見る
  （2026-10-09 ユーザー「パフォーマンスに影響が出そうならまた考えよう」）
- Release `gdal-wasm-3.13.3-1` は未作成（上の「配り方」）

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

## 未決・見張り（Android）

- 実機（Pixel 9）での確認は `integration_test/device/gdal_smoke_test.dart`。armeabi-v7a は手元に実機が無く未確認
