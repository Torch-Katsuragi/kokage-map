#!/usr/bin/env bash
# libgdal.so（GDAL + PROJ、Android 3 ABI）と proj.db を焼く。**WSL（Ubuntu 22.04 以降）の中で回す**。
#
# Windows の NDK と Git Bash では PROJ の proj.db 生成（ホストの sqlite3 が要る）と autotools の libiconv が通しにくいので、
# Linux 版 NDK を作業 dir に落として Linux 上でクロスビルドする。設計とサイズは third_party/gdal/README.md。
#
# 依存（WSL 側）: cmake(>= 3.22.1) ninja-build build-essential pkg-config sqlite3 zip unzip xz-utils curl
#   sudo apt-get install -y cmake ninja-build build-essential pkg-config sqlite3 zip unzip xz-utils curl
#
# 使い方（Windows の repo を WSL から見て回す。作業 dir は WSL 側の ext4 に置く。/mnt/c 上だと何倍も遅い）:
#   wsl -d Ubuntu -- bash third_party/gdal/build_android.sh                 # 3 ABI 全部
#   wsl -d Ubuntu -- env ABIS=arm64-v8a bash third_party/gdal/build_android.sh
# 出力:
#   android/app/src/main/jniLibs/<abi>/libgdal.so（strip 済み、NEEDED は libc/libm/libdl/libz/liblog だけ）
#   assets/gdal/proj.db（PROJ の座標系 DB。アプリが初回にファイルへ書き出して PROJ_DATA に向ける）
set -euo pipefail

# ---- 取得物は中身を固定する（版を上げるときは URL と SHA を組で書き換える） ----
GDAL_VER="3.13.3"
GDAL_URL="https://download.osgeo.org/gdal/$GDAL_VER/gdal-$GDAL_VER.tar.gz"
GDAL_SHA256="5e0c388d83da2d686cc00a40272882432cdb54edff43d4af173e532844a0a0ea"   # 同所の .md5 と突き合わせ済み（2026-10-09）
PROJ_VER="9.9.0"
PROJ_URL="https://download.osgeo.org/proj/proj-$PROJ_VER.tar.gz"
PROJ_SHA256="791a0610547eeabb17006cfd49cdbd2034f3240f47ed5e88a1031811f4e2bcf3"   # 同所の .md5 と突き合わせ済み（2026-10-09）
EXPAT_VER="2.9.0"
EXPAT_URL="https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VER//./_}/expat-$EXPAT_VER.tar.xz"
EXPAT_SHA256="1e6371862cc31999b368c3b89b49994f0677e1bab5f1b2b85ae3741f5d803051"
ICONV_VER="1.18"
ICONV_URL="https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$ICONV_VER.tar.gz"
ICONV_SHA256="3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8"
# geodiff と同じ amalgamation（third_party/geodiff/build_android.sh と同じ値）
SQLITE_URL="https://sqlite.org/2026/sqlite-amalgamation-3530400.zip"
SQLITE_SHA256="1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d"
# NDK r28c = 28.2.13676358（android/app/build.gradle.kts の ndkVersion と揃える）。Linux 版
NDK_VER="28.2.13676358"
NDK_URL="https://dl.google.com/android/repository/android-ndk-r28c-linux.zip"
NDK_SHA256="dfb20d396df28ca02a8c708314b814a4d961dc9074f9a161932746f815aa552f"

API="${API:-24}"
ABIS="${ABIS:-arm64-v8a x86_64 armeabi-v7a}"
JOBS="${JOBS:-$(nproc)}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="${W:-$HOME/kokage-gdal}"
mkdir -p "$W/dl" "$W/src"

# $1 のファイルが SHA-256 $2 でなければ消して止まる
verify_sha256() {
  local got; got="$(sha256sum "$1" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    echo "SHA-256 不一致: $1 (got $got, want $2)" >&2; rm -f "$1"; exit 1
  fi
}
# URL を dl/ に落として照合し、src/ に展開する（展開済みなら飛ばす）
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

if [ -z "${NDK:-}" ]; then
  NDK="$W/android-ndk-r28c"
  if [ ! -d "$NDK" ]; then
    NDK_ZIP="$(fetch "$NDK_URL" "$NDK_SHA256")"
    (cd "$W" && unzip -q "$NDK_ZIP")
  fi
fi
grep -q "Pkg.Revision = $NDK_VER" "$NDK/source.properties" || { echo "NDK が $NDK_VER ではない: $NDK" >&2; exit 1; }
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"

# 全部同じ方針でビルドする: -fPIC、関数・データ単位のセクション（--gc-sections で落とせるように）
COMMON_CFLAGS="-fPIC -ffunction-sections -fdata-sections"
# 最適化（CMake の Release の既定は -O3）。OPT=-O3 などで差し替えて大きさを比べられる
OPT="${OPT:--Os}"

# CMake のクロスビルド共通引数（$1 = ABI、$2 = prefix）
cmake_android() {
  local abi="$1" prefix="$2"; shift 2
  cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="$OPT -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="$OPT -DNDEBUG" \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" -DCMAKE_CXX_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@" >/dev/null
}

for ABI in $ABIS; do
  case "$ABI" in
    arm64-v8a) TRIPLE="aarch64-linux-android" ;;
    armeabi-v7a) TRIPLE="armv7a-linux-androideabi" ;;
    x86_64) TRIPLE="x86_64-linux-android" ;;
    *) echo "unknown ABI $ABI" >&2; exit 1 ;;
  esac
  CC="$TC/$TRIPLE$API-clang"
  P="$W/prefix-$ABI"; B="$W/build-$ABI"
  # 依存ライブラリは出来ていれば飛ばす。版や引数を変えたら CLEAN=1 で作り直す
  if [ "${CLEAN:-0}" = 1 ]; then rm -rf "$P" "$B"; fi
  mkdir -p "$P/include" "$P/lib" "$B"

  echo "== [$ABI] sqlite3（静的。シンボルは libgdal.so の外へ出さない）"
  if [ ! -f "$P/lib/libsqlite3.a" ]; then
    mkdir -p "$B/sqlite"
    # RTREE は GPKG の空間索引、COLUMN_METADATA は GDAL の SQLite ドライバが使う
    "$CC" -O2 $COMMON_CFLAGS -c "$W/src/$SQL_DIR/sqlite3.c" -o "$B/sqlite/sqlite3.o" \
      -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0
    "$TC/llvm-ar" rcs "$P/lib/libsqlite3.a" "$B/sqlite/sqlite3.o"
    cp "$W/src/$SQL_DIR/sqlite3.h" "$W/src/$SQL_DIR/sqlite3ext.h" "$P/include/"
  fi

  echo "== [$ABI] libiconv $ICONV_VER（静的。API 24 の bionic には iconv が無い → Shift_JIS の shp が読めない）"
  if [ ! -f "$P/lib/libiconv.a" ]; then
    rm -rf "$B/iconv" && mkdir -p "$B/iconv" && pushd "$B/iconv" >/dev/null
    "$W/src/libiconv-$ICONV_VER/configure" --host="$TRIPLE" --prefix="$P" --enable-static --disable-shared \
      --with-pic --disable-nls --disable-rpath \
      CC="$CC" AR="$TC/llvm-ar" RANLIB="$TC/llvm-ranlib" CFLAGS="-O2 $COMMON_CFLAGS" >/dev/null
    # 要るのはライブラリだけ（iconv コマンドや翻訳は焼かない）。libcharset を先に
    # （トップの Makefile と同じく、localcharset.h を lib/ から見える include/ に置く）
    make -j"$JOBS" -C libcharset >/dev/null
    make -C libcharset install-lib libdir="$B/iconv/lib" includedir="$B/iconv/include" >/dev/null
    make -j"$JOBS" -C lib >/dev/null
    make -C lib install >/dev/null
    cp include/iconv.h "$P/include/"
    popd >/dev/null
  fi

  echo "== [$ABI] expat $EXPAT_VER（静的。KML / GPX / GML の読み取り）"
  if [ ! -f "$P/lib/libexpat.a" ]; then
    rm -rf "$B/expat" && mkdir -p "$B/expat" && pushd "$B/expat" >/dev/null
    cmake_android "$ABI" "$P" -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
      -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_PKGCONFIG=OFF "$W/src/expat-$EXPAT_VER"
    ninja -j"$JOBS" install >/dev/null
    popd >/dev/null
  fi

  echo "== [$ABI] PROJ $PROJ_VER（静的。TIFF/curl なし = グリッドを使わない変換だけ）"
  if [ ! -f "$P/lib/libproj.a" ]; then
    rm -rf "$B/proj" && mkdir -p "$B/proj" && pushd "$B/proj" >/dev/null
    # proj.db は埋め込まない（PROJ 9.5+ の静的ビルドは既定で .so に 10MB 埋める）。アセットで 1 本だけ持つ
    cmake_android "$ABI" "$P" -DBUILD_SHARED_LIBS=OFF -DENABLE_TIFF=OFF -DENABLE_CURL=OFF -DBUILD_TESTING=OFF \
      -DEMBED_RESOURCE_FILES=OFF -DUSE_ONLY_EMBEDDED_RESOURCE_FILES=OFF \
      -DBUILD_APPS=OFF -DBUILD_PROJSYNC=OFF -DBUILD_EXAMPLES=OFF \
      -DSQLite3_INCLUDE_DIR="$P/include" -DSQLite3_LIBRARY="$P/lib/libsqlite3.a" -DEXE_SQLITE3="$(command -v sqlite3)" \
      "$W/src/proj-$PROJ_VER"
    ninja -j"$JOBS" install >/dev/null
    popd >/dev/null
  fi

  echo "== [$ABI] GDAL $GDAL_VER"
  mkdir -p "$B/gdal" && pushd "$B/gdal" >/dev/null
  # 外部ライブラリは既定で全部切り、使うものだけ名指しで入れる。ドライバも同じ（任意ドライバを切って必要なものだけ）
  # iconv の第 2 引数の const 判定は NDK の iconv.h（API 28 から）を見て誤るので、libiconv に合わせて非 const と決め打つ
  # リンク: 静的に入れた sqlite3 / PROJ / expat / libiconv / libc++ のシンボルは --exclude-libs で隠す
  #         （アプリの sqflite・geodiff が持つ sqlite と名前がぶつからないように）
  cmake_android "$ABI" "$P" \
    -DBUILD_SHARED_LIBS=ON -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF \
    -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_JAVA_BINDINGS=OFF -DBUILD_CSHARP_BINDINGS=OFF \
    -DGDAL_HIDE_INTERNAL_SYMBOLS=ON -DENABLE_GNM=OFF -DGDAL_ENABLE_PLUGINS=OFF -DGDAL_ENABLE_PLUGINS_NO_DEPS=OFF \
    -DEMBED_RESOURCE_FILES=OFF \
    -DGDAL_USE_EXTERNAL_LIBS=OFF -DGDAL_USE_INTERNAL_LIBS=ON \
    -DGDAL_USE_ZLIB=ON -DGDAL_USE_ZLIB_INTERNAL=OFF \
    -DGDAL_USE_SQLITE3=ON -DSQLite3_INCLUDE_DIR="$P/include" -DSQLite3_LIBRARY="$P/lib/libsqlite3.a" \
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
    -DOGR_ENABLE_DRIVER_OPENFILEGDB=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--exclude-libs,ALL -Wl,--gc-sections" \
    "$W/src/gdal-$GDAL_VER"
  ninja -j"$JOBS" install >"$B/gdal/ninja.log" 2>&1 || { grep -E "FAILED|error" "$B/gdal/ninja.log" | head -40; exit 1; }
  SO="$(readlink -f "$B/gdal/libgdal.so")"
  OUT="$REPO/android/app/src/main/jniLibs/$ABI"; mkdir -p "$OUT"
  "$TC/llvm-strip" --strip-unneeded -o "$OUT/libgdal.so" "$SO"
  popd >/dev/null

  echo "== [$ABI] 出力: $OUT/libgdal.so ($(stat -c %s "$OUT/libgdal.so") bytes)"
  "$TC/llvm-readelf" -d "$OUT/libgdal.so" | grep -E "NEEDED|SONAME"
  "$TC/llvm-readelf" -lW "$OUT/libgdal.so" | awk '$1=="LOAD"{print "  LOAD align", $NF}' | sort -u
  # sqlite / PROJ の名前が外へ出ていないこと（sqlite3_extension_init は GDAL 自身の関数。SQLite の拡張として読ませる入口）
  if "$TC/llvm-nm" -D --defined-only "$OUT/libgdal.so" | grep -v " sqlite3_extension_init$" \
      | grep -qE " (sqlite3_|proj_|XML_|libiconv)"; then
    echo "⚠ 静的に入れたライブラリのシンボルが外に出ている" >&2; exit 1
  fi
done

echo "== データ（ABI に依らない。最初の ABI の install から取る）"
mkdir -p "$REPO/assets/gdal"
FIRST_ABI="${ABIS%% *}"
cp "$W/prefix-$FIRST_ABI/share/proj/proj.db" "$REPO/assets/gdal/proj.db"
echo "  assets/gdal/proj.db ($(stat -c %s "$REPO/assets/gdal/proj.db") bytes)"
# GDAL_DATA（DXF の雛形、GML のレジストリと基盤地図情報 jpfgdgml_*.gfs、タイル方式の tms_*.json など）。
# NDK r28 の clang 19.0.1 は C23 の #embed を持たず EMBED_RESOURCE_FILES が使えないので、zip にしてアセットで持つ。
# 中身の順と時刻を揃えて、焼き直しても同じバイト列になるようにする
rm -f "$REPO/assets/gdal/gdal_data.zip"
(cd "$W/prefix-$FIRST_ABI/share/gdal" && find . -type f | LC_ALL=C sort | sed 's|^\./||' \
  | TZ=UTC xargs touch -d 2000-01-01T00:00:00 && find . -type f | LC_ALL=C sort | sed 's|^\./||' \
  | zip -q -X -9 -@ "$REPO/assets/gdal/gdal_data.zip")
echo "  assets/gdal/gdal_data.zip ($(stat -c %s "$REPO/assets/gdal/gdal_data.zip") bytes)"
