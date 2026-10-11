# GDAL（Android の libgdal.so と web の WASM）

[GDAL](https://gdal.org/) 3.13.3 と [PROJ](https://proj.org/) 9.9.0 を、このアプリ向けに Android 3 ABI と WebAssembly へ焼いたもの。
両方とも同じ版・同じドライバの組（web は [[#web（WASM）]]）。
設計と使いどころは [[../../docs/technical/gdal|GDAL]]、Dart の窓口は `lib/core/gdal/`。

| 成果物 | 置き場 | 作り方 |
|---|---|---|
| `libgdal.so`（arm64-v8a / x86_64 / armeabi-v7a） | `android/app/src/main/jniLibs/<abi>/` | `build_android.sh`（WSL） |
| `proj.db`（PROJ の座標系 DB） | `assets/gdal/proj.db` | 同上（PROJ のビルドが作る） |
| `gdal_data.zip`（GDAL_DATA） | `assets/gdal/gdal_data.zip` | 同上（GDAL の install を zip に） |
| ライセンス本文 | `assets/licenses/{gdal,proj,expat,libiconv}.txt` | 各ソースから原文のまま（`lib/core/native_licenses.dart` がライセンス画面に載せる） |

コミット済みの成果物は 2026-10-09 に matsumoto_tabPC の WSL（Ubuntu 22.04）で焼いたもの（CI では作っていない）。

## 焼き方

**WSL の中で回す**（Windows の NDK と Git Bash では、PROJ の proj.db 生成にホストの sqlite3 が要るのと、
autotools の libiconv が通しにくい）。Linux 版 NDK は作業 dir に落とす。

```bash
# 一度だけ（WSL 側）
sudo apt-get install -y cmake ninja-build build-essential pkg-config sqlite3 zip unzip xz-utils curl
# repo の dir で（Windows 側から）
wsl -d Ubuntu -- bash third_party/gdal/build_android.sh                   # 3 ABI 全部（1 ABI あたり 20〜30 分）
wsl -d Ubuntu -- env ABIS=arm64-v8a bash third_party/gdal/build_android.sh
wsl -d Ubuntu -- env CLEAN=1 bash third_party/gdal/build_android.sh       # 版や引数を変えたとき（依存も作り直す）
```

作業 dir は `~/kokage-gdal`（WSL の ext4。`/mnt/c` の上だと何倍も遅い）。`W=` で変えられる。
⚠ WSL の `Ubuntu-24.04` は感染スマホ調査用のサンドボックス（automount・interop を切ってある）なので使わない。

## 版と取得物（SHA-256 で固定）

版を上げるときはスクリプト冒頭の URL と SHA を組で書き換え、`lib/core/gdal/gdal_ffi.dart` の `_dataStamp` も変える
（端末に書き出した proj.db / GDAL_DATA を入れ替える目印）。

| もの | 版 | SHA-256 | 突き合わせ |
|---|---|---|---|
| GDAL | 3.13.3 | `5e0c388d83da2d686cc00a40272882432cdb54edff43d4af173e532844a0a0ea` | download.osgeo.org の .md5 |
| PROJ | 9.9.0 | `791a0610547eeabb17006cfd49cdbd2034f3240f47ed5e88a1031811f4e2bcf3` | download.osgeo.org の .md5 |
| expat | 2.9.0 | `1e6371862cc31999b368c3b89b49994f0677e1bab5f1b2b85ae3741f5d803051` | GitHub release |
| GNU libiconv | 1.18 | `3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8` | ftp.gnu.org |
| SQLite amalgamation | 3.53.4（3530400） | `1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d` | geodiff と同じ値 |
| Android NDK（Linux） | r28c = 28.2.13676358 | `dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f` | `source.properties` の Pkg.Revision も照合 |

QGIS 4.2.2 同梱の GDAL も 3.13.3（ホスト VM テストはこれで回す）。

## 中身の方針

- **1 本の `libgdal.so`**。PROJ・SQLite・expat・libiconv・libc++ は静的に入れ、`-Wl,--exclude-libs,ALL` でシンボルを隠す
  （アプリの sqflite・geodiff が持つ別の SQLite と名前がぶつからない）。外に出るのは GDAL の C API だけ
  （例外は GDAL 自身の `sqlite3_extension_init`）。`NEEDED` は `libm` `libz` `libdl` `libc`
- zlib は NDK（システムの `libz.so`）。libtiff・libgeotiff・libjpeg・libpng・json-c・LERC・shapelib は GDAL 内蔵のもの
- curl・Python・GEOS・ネットワークのドライバは無し。`PROJ_NETWORK=OFF`
- **libiconv を入れている理由**: API 24 の bionic には iconv が無い（28 から）。無いと GDAL の文字コード変換は
  UTF-8 ⇔ ISO-8859-1 しかできず、Shift_JIS（CP932）の shp が読めない
- PROJ は TIFF なし（`ENABLE_TIFF=OFF`）= グリッドファイルを使う変換はしない（グリッドを積んでいないので同じこと）。
  JGD2011 ⇔ WGS84 はグリッド不要。旧日本測地系（Tokyo）⇔ JGD はグリッド（TKY2JGD）が無いので PROJ の近似（数 m）になる
- PROJ 9.5+ の静的ビルドは proj.db を `.so` に埋め込む（10 MB）のが既定なので切り、アセットで 1 本だけ持つ
- GDAL_DATA は C23 の `#embed`（`EMBED_RESOURCE_FILES`）で埋め込みたいが、NDK r28 の clang 19.0.1 に無いので zip のアセット。
  中身は DXF の雛形（書き出しに必須）、GML のレジストリと基盤地図情報（`jpfgdgml_*.gfs`）、タイル方式（`tms_*.json`）など
- 最適化は `-Os`（`OPT=` で変えられる）。arm64 で -O3 22.8 MB → -Os 20.1 MB
- 64bit は LOAD セグメントが 16KB 境界（NDK 28 の既定。スクリプトが `readelf` で表示）。API 24、libc++ 静的

### ドライバ

任意ドライバは全部切り（`GDAL_BUILD_OPTIONAL_DRIVERS=OFF` `OGR_BUILD_OPTIONAL_DRIVERS=OFF`）、次だけ入れる。

| | ドライバ |
|---|---|
| ラスタ | GTiff（COG を含む）、PNG、JPEG、GPKG（ラスタ）、MEM、VRT |
| ベクタ | GPKG、SQLite、ESRI Shapefile、GeoJSON / GeoJSONSeq / ESRIJSON / TopoJSON、KML（expat）、CSV、FlatGeobuf、GPX、GML、DXF、MapInfo File（TAB/MIF）、OpenFileGDB、Memory、OGR_VRT |

足すときは `-DOGR_ENABLE_DRIVER_<名前>=ON` を足して `CLEAN=1` で焼き直す（増分の目安は数百 KB）。

## 大きさ（2026-10-09、-Os）

| ABI | libgdal.so | 参考: -O3 |
|---|---|---|
| arm64-v8a | 20,114,184 B（gzip -9 で 8.3 MB） | 22.8 MB |
| x86_64 | 20,670,168 B | |
| armeabi-v7a | 14,522,524 B | |

| データ | 大きさ | APK の中（deflate） |
|---|---|---|
| `proj.db` | 10,551,296 B | 1,948,667 B |
| `gdal_data.zip` | 149,811 B | 144,380 B |
| ライセンス本文 4 本 | 51,188 B | 16,835 B |

**APK の増分**（`flutter build apk --release`、key.properties 無しの未署名で測った）:
.so は無圧縮（stored）で入るので 3 ABI の合計 55.3 MB ＋ アセット 2.1 MB = **約 57.4 MB**（APK 全体 175.3 MB）。
Play（AAB）は ABI ごとに配るので、arm64 の端末に入るのは .so 20.1 MB ＋ アセット 2.1 MB = 約 22 MB、
ダウンロードは .so が圧縮されて約 10 MB。端末上では初回に proj.db と GDAL_DATA を書き出すので、さらに約 11 MB 使う。

arm64 の中身のおおよその内訳: GDAL 本体 2.7 MB・OGR 1.7 MB・`gdal` CLI のアルゴリズム群 1.2 MB（3.11 から libgdal に入る。外せない）・
PROJ 1.9 MB・libc++ 1.9 MB・libiconv 0.7 MB・SQLite 0.6 MB、残りは例外表・再配置・動的シンボル表。

### proj.db を絞れるか（試した。絞らない）

| | 大きさ | gzip -9 |
|---|---|---|
| そのまま（EPSG・ESRI・IAU_2015・IGNF・NKG・NRCAN・OGC・PROJ） | 10.3 MB | 1.86 MB |
| 地球外・フランス・北欧・カナダ（IAU_2015・IGNF・NKG・NRCAN）を落とす | 8.2 MB | 1.64 MB |
| さらに ESRI を落とす | 6.9 MB | 1.40 MB |

（QGIS 4.2.2 同梱の proj.db で測った。PROJ 9.9.0 のものもほぼ同じ大きさ）
APK で減るのは圧縮後の 0.2〜0.5 MB だけ。ESRI は shp の `.prj`（ESRI WKT）を EPSG に同定するのに使うので落とせず、
他を落とす利益は小さいので、絞らない。

## Dart からの呼び方

`lib/core/gdal/gdal_provider.dart` の `createGdal()`（Android は `GdalFfi`）。初回に proj.db と GDAL_DATA を
`<アプリの support dir>/gdal/` に書き出し、`OSRSetPROJSearchPaths`・`GDAL_DATA`・`CPL_TMPDIR` を設定してから使う。
スレッドとアイソレートの約束は `gdal_ffi.dart` の冒頭。

## 確認

- ホスト VM: `flutter test test/gdal_test.dart`（Windows は QGIS の `gdal313.dll`、CI は apt の `libgdal-dev`）
- 実機: `flutter test integration_test/device/gdal_smoke_test.dart -d <device>`（同じ筋書きを `libgdal.so` で）

## web（WASM）

`build_web.sh`（WSL）が同じソース（SHA-256 も同じ値）を emscripten で焼き、`web/gdal3/<組>/` に書く。作業 dir は `build_android.sh` と共有（`~/kokage-gdal`、取得物も使い回す）。

```bash
wsl -d Ubuntu -- bash third_party/gdal/build_web.sh              # 初回は emsdk の取得込みで 15 分ほど（12 コア）
wsl -d Ubuntu -- env CLEAN=1 bash third_party/gdal/build_web.sh  # 版や引数を変えたとき
```

| 成果物 | 中身 |
|---|---|
| `gdal.js` | emscripten の Module 工場（`MODULARIZE`、`createGdalModule`、`ENVIRONMENT=worker`） |
| `gdal.wasm` | GDAL・PROJ・SQLite・expat・libiconv・zlib（静的に 1 本） |
| `gdal.data` | `/gdal_data`（GDAL_DATA）と `/proj/proj.db`（`--preload-file`） |
| `LICENSE` | GDAL・PROJ・expat・libiconv の条文 |

| もの | 版 | 固定のしかた |
|---|---|---|
| emsdk / emscripten | 6.0.12（2026-10-08） | emsdk の git commit `35ff8a6d150541276abbc6bae512ca90bcfbe220`。toolchain は emsdk が版の hash で取る |
| zlib | 1.3.2 | emscripten の port（`embuilder build zlib`。版は emsdk が決める） |
| GDAL・PROJ・expat・libiconv・SQLite | 上の表と同じ | 上の表と同じ SHA-256 |

Android との違い:

- 単一スレッド（`-pthread` なし = `SharedArrayBuffer` なし）。SQLite も `SQLITE_THREADSAFE=0` なので GDAL の確認を `ACCEPT_MISSING_SQLITE3_MUTEX_ALLOC=ON` で通す
- C++ の例外と setjmp は WebAssembly の例外（`-fwasm-exceptions -sSUPPORT_LONGJMP=wasm`）
- zlib は emscripten の port（GDAL 内蔵の zlib は `gdal_crc32_combine` の `z_off_t` の幅が食い違い、リンクで signature mismatch が出た）
- SQLite は拡張の読み込みを切る（`SQLITE_OMIT_LOAD_EXTENSION`、dlopen が無い）
- libiconv は Android と同じ GNU のもの（emscripten の musl の iconv は使わない。CP932 の表を揃えるため）
- リンク: `-sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=4GB -sINITIAL_MEMORY=64MB -sSTACK_SIZE=4MB -sFORCE_FILESYSTEM -lworkerfs.js -sDYNAMIC_EXECUTION=0`。
  書き出す C 関数は `EXPORTS`（`web/gdal3/worker.js` が cwrap するものと揃える）

大きさ（3.13.3-1）: `gdal.wasm` 12.3 MB（gzip 4.8 / brotli 3.6 MB）、`gdal.data` 11.8 MB（2.0 / 1.4 MB）、`gdal.js` 93 KB。
gdal3.js 2.8.1 の 40.0 MB（gzip 11.2 MB）から 24.2 MB（gzip 6.9 MB）に。詳細と速さは [[../../docs/technical/gdal#web（WASM）]]。

配り方: リポジトリには入れず、Release `gdal-wasm-<組>` に上げて `tool/web/fetch_gdal_wasm.sh` で取る（SHA-256 はスクリプトに固定）。
Release の作成と upload は人の作業。

## ライセンス

GDAL・PROJ は MIT/X 系、expat は MIT、GNU libiconv は LGPL-2.1+（静的リンク。アプリ自体が GPL-2.0+ でソースを公開しているので条件を満たす）、
SQLite はパブリックドメイン。GDAL の `LICENSE.TXT` は同梱の libtiff・libgeotiff・libjpeg・libpng・json-c・LERC（Apache-2.0）・
flatbuffers（Apache-2.0）などの条文も含む。本文は `assets/licenses/` にあり、アプリのライセンス画面に出る。
