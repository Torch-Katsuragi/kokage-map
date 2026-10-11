#!/usr/bin/env bash
# web 版の GDAL（GDAL + PROJ を WebAssembly に）を焼く。**WSL（Ubuntu 22.04 以降）の中で回す**。
#
# Android（build_android.sh）と同じ GDAL / PROJ / expat / libiconv / SQLite を、同じドライバの組で emscripten に通す。
# 出力は web/gdal3/worker.js がそのまま読む 4 ファイル。設計は docs/technical/gdal.md「web」、版と大きさは third_party/gdal/README.md。
#
# 依存（WSL 側）: build_android.sh と同じ + git python3
#   sudo apt-get install -y cmake ninja-build build-essential pkg-config sqlite3 zip unzip xz-utils curl git python3
#
# 使い方（Windows の repo を WSL から見て回す。作業 dir は build_android.sh と共有で、ソースの取得物も使い回す）:
#   wsl -d Ubuntu -- bash third_party/gdal/build_web.sh
#   wsl -d Ubuntu -- env CLEAN=1 bash third_party/gdal/build_web.sh     # 版や引数を変えたとき（依存も作り直す）
# 出力（web/gdal3/<BUILD>/、.gitignore 済み。配り方は tool/web/fetch_gdal_wasm.sh）:
#   gdal.js    emscripten の Module 工場（MODULARIZE、createGdalModule）
#   gdal.wasm  GDAL・PROJ・SQLite・expat・libiconv・zlib
#   gdal.data  /gdal_data（GDAL_DATA）と /proj/proj.db。emscripten の --preload-file
#   LICENSE    GDAL・PROJ・expat・libiconv の条文
#   SHA256SUMS 上の 4 ファイルの SHA-256（fetch_gdal_wasm.sh に写す）
set -euo pipefail

# ---- この組の名前。worker が読むフォルダ名になる（lib/core/gdal/gdal_web.dart の kGdalWasmBuild と揃える）。
# 版・引数・emsdk を変えたら末尾の番号を上げる（Firebase は版のフォルダごとに 1 年キャッシュするので、名前で入れ替える）
BUILD="3.13.3-1"

# ---- 取得物は中身を固定する（build_android.sh と同じ値。版を上げるときは両方を組で書き換える） ----
GDAL_VER="3.13.3"
GDAL_URL="https://download.osgeo.org/gdal/$GDAL_VER/gdal-$GDAL_VER.tar.gz"
GDAL_SHA256="5e0c388d83da2d686cc00a40272882432cdb54edff43d4af173e532844a0a0ea"
PROJ_VER="9.9.0"
PROJ_URL="https://download.osgeo.org/proj/proj-$PROJ_VER.tar.gz"
PROJ_SHA256="791a0610547eeabb17006cfd49cdbd2034f3240f47ed5e88a1031811f4e2bcf3"
EXPAT_VER="2.9.0"
EXPAT_URL="https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VER//./_}/expat-$EXPAT_VER.tar.xz"
EXPAT_SHA256="1e6371862cc31999b368c3b89b49994f0677e1bab5f1b2b85ae3741f5d803051"
ICONV_VER="1.18"
ICONV_URL="https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$ICONV_VER.tar.gz"
ICONV_SHA256="3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8"
SQLITE_URL="https://sqlite.org/2026/sqlite-amalgamation-3530400.zip"
SQLITE_SHA256="1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d"
# emsdk は git の commit で固定する（タグ 6.0.12 の commit。emsdk はこの版の toolchain を版の hash で取りに行く）
EMSDK_VER="6.0.12"
EMSDK_COMMIT="35ff8a6d150541276abbc6bae512ca90bcfbe220"

JOBS="${JOBS:-$(nproc)}"
# 最適化。Android と同じ -Os（-Oz は数 % 小さく、少し遅い）
OPT="${OPT:--Os}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="${W:-$HOME/kokage-gdal}"
P="$W/prefix-wasm"; B="$W/build-wasm"
OUT="$REPO/web/gdal3/$BUILD"
mkdir -p "$W/dl" "$W/src"

verify_sha256() {
  local got; got="$(sha256sum "$1" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    echo "SHA-256 不一致: $1 (got $got, want $2)" >&2; rm -f "$1"; exit 1
  fi
}
fetch() {
  local url="$1" sha="$2" f; f="$W/dl/$(basename "$url")"
  [ -f "$f" ] || curl -fsSL -o "$f" "$url"
  verify_sha256 "$f" "$sha"
  echo "$f"
}

echo "== 取得と照合"
GDAL_TGZ="$(fetch "$GDAL_URL" "$GDAL_SHA256")"
PROJ_TGZ="$(fetch "$PROJ_URL" "$PROJ_SHA256")"
EXPAT_TXZ="$(fetch "$EXPAT_URL" "$EXPAT_SHA256")"
ICONV_TGZ="$(fetch "$ICONV_URL" "$ICONV_SHA256")"
SQLITE_ZIP="$(fetch "$SQLITE_URL" "$SQLITE_SHA256")"
cd "$W/src"
[ -d "gdal-$GDAL_VER" ] || tar xf "$GDAL_TGZ"
[ -d "proj-$PROJ_VER" ] || tar xf "$PROJ_TGZ"
[ -d "expat-$EXPAT_VER" ] || tar xf "$EXPAT_TXZ"
[ -d "libiconv-$ICONV_VER" ] || tar xf "$ICONV_TGZ"
SQL_DIR="$(unzip -Z1 "$SQLITE_ZIP" | head -1 | cut -d/ -f1)"
[ -d "$SQL_DIR" ] || unzip -q "$SQLITE_ZIP"

echo "== emsdk $EMSDK_VER"
if [ ! -d "$W/emsdk/.git" ]; then git clone -q https://github.com/emscripten-core/emsdk.git "$W/emsdk"; fi
(cd "$W/emsdk" && { git cat-file -e "$EMSDK_COMMIT^{commit}" 2>/dev/null || git fetch -q origin; } \
  && git -c advice.detachedHead=false checkout -q "$EMSDK_COMMIT" \
  && ./emsdk install "$EMSDK_VER" >/dev/null && ./emsdk activate "$EMSDK_VER" >/dev/null)
# shellcheck disable=SC1091
EMSDK_QUIET=1 source "$W/emsdk/emsdk_env.sh"
emcc --version | head -1 | grep -q " $EMSDK_VER " || { echo "emcc が $EMSDK_VER ではない" >&2; emcc --version | head -1; exit 1; }

if [ "${CLEAN:-0}" = 1 ]; then rm -rf "$P" "$B"; fi
mkdir -p "$P/include" "$P/lib" "$B"

# 全部同じ方針: 単一スレッド（-pthread なし = SharedArrayBuffer なし）、C++ の例外は WebAssembly の例外
# （GDAL・PROJ は例外を使う。JS 経由の例外より小さく速い）。setjmp/longjmp（libpng・libjpeg）も同じ仕組みで
EH="-fwasm-exceptions -sSUPPORT_LONGJMP=wasm"
CFLAGS_ALL="$OPT $EH"

emcmake_build() { # $1 = ソース dir、残りは cmake の引数。$PWD にビルドして $P に入れる
  local src="$1"; shift
  emcmake cmake -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="-DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-DNDEBUG" \
    -DCMAKE_C_FLAGS="$CFLAGS_ALL" -DCMAKE_CXX_FLAGS="$CFLAGS_ALL" \
    -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_PREFIX_PATH="$P" -DCMAKE_FIND_ROOT_PATH="$P" \
    "$@" "$src" >/dev/null
}

echo "== sqlite3（単一スレッド）"
if [ ! -f "$P/lib/libsqlite3.a" ]; then
  mkdir -p "$B/sqlite"
  # RTREE は GPKG の空間索引、COLUMN_METADATA は GDAL の SQLite ドライバが使う。拡張の読み込み（dlopen）は使えないので切る
  emcc $CFLAGS_ALL -c "$W/src/$SQL_DIR/sqlite3.c" -o "$B/sqlite/sqlite3.o" \
    -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_THREADSAFE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 \
    -DSQLITE_OMIT_LOAD_EXTENSION
  emar rcs "$P/lib/libsqlite3.a" "$B/sqlite/sqlite3.o"
  cp "$W/src/$SQL_DIR/sqlite3.h" "$W/src/$SQL_DIR/sqlite3ext.h" "$P/include/"
fi

echo "== libiconv $ICONV_VER（Android と同じ。emscripten の musl の iconv ではなく GNU の CP932 表を使う）"
if [ ! -f "$P/lib/libiconv.a" ]; then
  rm -rf "$B/iconv" && mkdir -p "$B/iconv" && pushd "$B/iconv" >/dev/null
  emconfigure "$W/src/libiconv-$ICONV_VER/configure" --host=wasm32-unknown-emscripten --prefix="$P" \
    --enable-static --disable-shared --disable-nls --disable-rpath CFLAGS="$CFLAGS_ALL" >/dev/null
  emmake make -j"$JOBS" -C libcharset >/dev/null
  emmake make -C libcharset install-lib libdir="$B/iconv/lib" includedir="$B/iconv/include" >/dev/null
  emmake make -j"$JOBS" -C lib >/dev/null
  emmake make -C lib install >/dev/null
  cp include/iconv.h "$P/include/"
  popd >/dev/null
fi

echo "== expat $EXPAT_VER"
if [ ! -f "$P/lib/libexpat.a" ]; then
  rm -rf "$B/expat" && mkdir -p "$B/expat" && pushd "$B/expat" >/dev/null
  emcmake_build "$W/src/expat-$EXPAT_VER" -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
    -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_PKGCONFIG=OFF
  ninja -j"$JOBS" install >/dev/null
  popd >/dev/null
fi

echo "== PROJ $PROJ_VER（TIFF/curl なし。proj.db は埋め込まず gdal.data に入れる）"
if [ ! -f "$P/lib/libproj.a" ]; then
  rm -rf "$B/proj" && mkdir -p "$B/proj" && pushd "$B/proj" >/dev/null
  emcmake_build "$W/src/proj-$PROJ_VER" -DBUILD_SHARED_LIBS=OFF -DENABLE_TIFF=OFF -DENABLE_CURL=OFF -DBUILD_TESTING=OFF \
    -DEMBED_RESOURCE_FILES=OFF -DUSE_ONLY_EMBEDDED_RESOURCE_FILES=OFF \
    -DBUILD_APPS=OFF -DBUILD_PROJSYNC=OFF -DBUILD_EXAMPLES=OFF \
    -DSQLite3_INCLUDE_DIR="$P/include" -DSQLite3_LIBRARY="$P/lib/libsqlite3.a" -DEXE_SQLITE3="$(command -v sqlite3)"
  ninja -j"$JOBS" install >"$B/proj/ninja.log" 2>&1 || { grep -E "FAILED|error" "$B/proj/ninja.log" | head -40; exit 1; }
  popd >/dev/null
fi

echo "== zlib（emscripten の port。版は emsdk が決める）"
embuilder build zlib >/dev/null
EMSYSROOT="$(em-config CACHE)/sysroot"

echo "== GDAL $GDAL_VER（静的。ドライバは build_android.sh と同じ組）"
mkdir -p "$B/gdal" && pushd "$B/gdal" >/dev/null
# zlib は emscripten の port（Android は NDK の libz。GDAL 内蔵の zlib は z_off_t の幅が食い違ってリンクで警告が出る）。iconv の第 2 引数は GNU libiconv に合わせて非 const
# SQLite は単一スレッド（mutex なし）。WASM の中では GDAL もスレッドを作らないので、GDAL の確認を通す
emcmake_build "$W/src/gdal-$GDAL_VER" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF \
  -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_JAVA_BINDINGS=OFF -DBUILD_CSHARP_BINDINGS=OFF \
  -DENABLE_GNM=OFF -DGDAL_ENABLE_PLUGINS=OFF -DGDAL_ENABLE_PLUGINS_NO_DEPS=OFF \
  -DEMBED_RESOURCE_FILES=OFF \
  -DGDAL_USE_EXTERNAL_LIBS=OFF -DGDAL_USE_INTERNAL_LIBS=ON \
  -DGDAL_USE_ZLIB=ON -DGDAL_USE_ZLIB_INTERNAL=OFF \
  -DZLIB_INCLUDE_DIR="$EMSYSROOT/include" -DZLIB_LIBRARY="$EMSYSROOT/lib/wasm32-emscripten/libz.a" \
  -DGDAL_USE_SQLITE3=ON -DSQLite3_INCLUDE_DIR="$P/include" -DSQLite3_LIBRARY="$P/lib/libsqlite3.a" \
  -DACCEPT_MISSING_SQLITE3_MUTEX_ALLOC=ON \
  -DGDAL_USE_EXPAT=ON -DEXPAT_INCLUDE_DIR="$P/include" -DEXPAT_LIBRARY="$P/lib/libexpat.a" \
  -DGDAL_USE_ICONV=ON -DIconv_INCLUDE_DIR="$P/include" -DIconv_LIBRARY="$P/lib/libiconv.a" -DIconv_IS_BUILT_IN=OFF \
  -D_ICONV_SECOND_ARGUMENT_IS_NOT_CONST=ON \
  -DGDAL_USE_QHULL_INTERNAL=OFF -DGDAL_USE_OPENCAD_INTERNAL=OFF \
  -DPROJ_DIR="$P/lib/cmake/proj" \
  -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
  -DGDAL_ENABLE_DRIVER_GTIFF=ON -DGDAL_ENABLE_DRIVER_PNG=ON -DGDAL_ENABLE_DRIVER_JPEG=ON -DGDAL_ENABLE_DRIVER_VRT=ON \
  -DOGR_ENABLE_DRIVER_SHAPE=ON -DOGR_ENABLE_DRIVER_GEOJSON=ON -DOGR_ENABLE_DRIVER_KML=ON -DOGR_ENABLE_DRIVER_CSV=ON \
  -DOGR_ENABLE_DRIVER_FLATGEOBUF=ON -DOGR_ENABLE_DRIVER_GPX=ON -DOGR_ENABLE_DRIVER_GML=ON -DOGR_ENABLE_DRIVER_DXF=ON \
  -DOGR_ENABLE_DRIVER_TAB=ON -DOGR_ENABLE_DRIVER_VRT=ON -DOGR_ENABLE_DRIVER_SQLITE=ON -DOGR_ENABLE_DRIVER_GPKG=ON \
  -DOGR_ENABLE_DRIVER_OPENFILEGDB=ON
ninja -j"$JOBS" install >"$B/gdal/ninja.log" 2>&1 || { grep -E "FAILED|error" "$B/gdal/ninja.log" | head -40; exit 1; }
popd >/dev/null

echo "== リンク（gdal.js / gdal.wasm / gdal.data）"
# worker.js が cwrap する C 関数（足したら worker.js と揃える）
EXPORTS=(
  malloc free
  GDALAllRegister GDALVersionInfo GDALOpenEx GDALClose GDALGetFileList CSLDestroy VSIFree
  CPLErrorReset CPLGetLastErrorMsg CPLGetLastErrorType CPLSetConfigOption CPLSetThreadLocalConfigOption
  OSRSetPROJSearchPaths
  GDALInfoOptionsNew GDALInfo GDALInfoOptionsFree
  GDALVectorInfoOptionsNew GDALVectorInfo GDALVectorInfoOptionsFree
  GDALVectorTranslateOptionsNew GDALVectorTranslate GDALVectorTranslateOptionsFree
  GDALWarpAppOptionsNew GDALWarp GDALWarpAppOptionsFree
  GDALTranslateOptionsNew GDALTranslate GDALTranslateOptionsFree
)
EXPORTED_FUNCTIONS="$(printf '_%s,' "${EXPORTS[@]}")"
STAGE="$B/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
# GDAL_DATA と proj.db（中身は Android の gdal_data.zip・proj.db と同じもの）
LINK_LIBS=("$P/lib/libgdal.a" "$P/lib/libproj.a" "$P/lib/libsqlite3.a" "$P/lib/libexpat.a" "$P/lib/libiconv.a" -sUSE_ZLIB=1)
# -sMAXIMUM_MEMORY=4GB: wasm32 の上限。2GB を超えるポインタは JS 側で符号なしに読む（worker.js は >>> で扱う）
# -sENVIRONMENT=worker: worker の中でしか読まない。-sDYNAMIC_EXECUTION=0: eval / new Function を出さない（CSP）
# -sSTACK_SIZE: emscripten の既定 64KB では PROJ・GDAL の深い呼び出しが溢れる
em++ $OPT $EH -o "$STAGE/gdal.js" "${LINK_LIBS[@]}" \
  -sMODULARIZE=1 -sEXPORT_NAME=createGdalModule -sENVIRONMENT=worker \
  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=4MB \
  -sFORCE_FILESYSTEM=1 -lworkerfs.js -sDYNAMIC_EXECUTION=0 -sEXIT_RUNTIME=0 \
  -sEXPORTED_FUNCTIONS="${EXPORTED_FUNCTIONS%,}" \
  -sEXPORTED_RUNTIME_METHODS=cwrap,FS,UTF8ToString,stringToUTF8,lengthBytesUTF8,HEAPU32 \
  --preload-file "$P/share/gdal@/gdal_data" \
  --preload-file "$P/share/proj/proj.db@/proj/proj.db" \
  --exclude-file '*.cmake'

mkdir -p "$OUT"
cp "$STAGE/gdal.js" "$STAGE/gdal.wasm" "$STAGE/gdal.data" "$OUT/"
{
  echo "GDAL $GDAL_VER / PROJ $PROJ_VER / expat $EXPAT_VER / GNU libiconv $ICONV_VER / SQLite（public domain）"
  echo "built with emscripten $EMSDK_VER by third_party/gdal/build_web.sh"
  for f in "gdal-$GDAL_VER/LICENSE.TXT" "proj-$PROJ_VER/COPYING" "expat-$EXPAT_VER/COPYING" "libiconv-$ICONV_VER/COPYING.LIB"; do
    printf '\n==================== %s ====================\n\n' "$f"; cat "$W/src/$f"
  done
} >"$OUT/LICENSE"
(cd "$OUT" && sha256sum gdal.js gdal.wasm gdal.data LICENSE >SHA256SUMS)
echo "== 出力: $OUT"
ls -l "$OUT"
cat "$OUT/SHA256SUMS"
