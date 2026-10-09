#!/usr/bin/env bash
# libgeodiff.so（Android arm64-v8a）を焼く。Git Bash / MSYS 前提。
#
# 依存: Android SDK の NDK（pubspec と同じ版）と SDK 同梱の cmake/ninja だけ。vcpkg は使わない。
# sqlite3 は amalgamation を session 拡張つきで NDK clang でビルドし、静的に geodiff へ入れる。
# 出力: android/app/src/main/jniLibs/arm64-v8a/libgeodiff.so（strip 済み）
#
# 使い方: third_party/geodiff/build_android.sh [作業dir]
set -euo pipefail

# 取得物は中身を固定する（版を上げるときは URL と SHA を組で書き換える）
GEODIFF_TAG="2.3.1"                                          # 表示用。取得はコミット SHA で行う
GEODIFF_SHA="f32842c79effd1be5b74140d295a1b0bb9ee521c"       # MerginMaps/geodiff の 2.3.1 タグが指すコミット
SQLITE_ZIP="https://sqlite.org/2026/sqlite-amalgamation-3530400.zip"
SQLITE_SHA256="1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d"   # sqlite.org 掲載の SHA3-256 と突き合わせ済み（2026-10-09）
# libgpkg は geodiff の CMake が GitHub の archive を取りにいく（URL はコミット固定だが照合が無い）。
# 先にこちらで落として照合し build dir に置いておくと、CMake は取得を飛ばす（libgpkg.tar.gz があれば使う）
LIBGPKG_URL="https://github.com/benstadin/libgpkg/archive/0822c5cba7e1ac2c2806e445e5f5dd2f0d0a18b4.tar.gz"
LIBGPKG_SHA256="2039f928724c57d7e8ba2983532346506cde48437e764efa243fbc6ba24fd1ba"

# $1 のファイルが SHA-256 $2 でなければ消して止まる
verify_sha256() {
  local got; got="$(sha256sum "$1" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    echo "SHA-256 不一致: $1 (got $got, want $2)" >&2; rm -f "$1"; exit 1
  fi
}
NDK_VER="${NDK_VER:-28.2.13676358}"   # android/app/build.gradle.kts の ndkVersion と揃える
API="${API:-24}"
ABI="${ABI:-arm64-v8a}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="${1:-$REPO/build/geodiff}"; mkdir -p "$W"; cd "$W"
SDK="${ANDROID_SDK_ROOT:-$LOCALAPPDATA/Android/Sdk}"; NDK="$SDK/ndk/$NDK_VER"
TC="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
CMAKE="$SDK/cmake/3.22.1/bin/cmake.exe"; NINJA="$SDK/cmake/3.22.1/bin/ninja.exe"
case "$ABI" in
  arm64-v8a) TARGET="aarch64-linux-android$API" ;;
  armeabi-v7a) TARGET="armv7a-linux-androideabi$API" ;;
  x86_64) TARGET="x86_64-linux-android$API" ;;
  *) echo "unknown ABI $ABI" >&2; exit 1 ;;
esac

echo "== sqlite amalgamation"
[ -f sqlite.zip ] || curl -fsSL -o sqlite.zip "$SQLITE_ZIP"
verify_sha256 sqlite.zip "$SQLITE_SHA256"
SQL_DIR="$(unzip -Z1 sqlite.zip | head -1 | cut -d/ -f1)"
[ -d "$SQL_DIR" ] || unzip -q sqlite.zip

echo "== sqlite3 静的ライブラリ ($ABI, API $API)"
mkdir -p "sqlite-$ABI" && pushd "sqlite-$ABI" >/dev/null
"$TC/clang.exe" --target="$TARGET" -O2 -fPIC -c "../$SQL_DIR/sqlite3.c" -o sqlite3.o \
  -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_RTREE \
  -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0
"$TC/llvm-ar.exe" rcs libsqlite3.a sqlite3.o
popd >/dev/null

echo "== geodiff $GEODIFF_TAG"
if [ ! -d geodiff ]; then
  git init -q geodiff
  git -C geodiff fetch -q --depth 1 https://github.com/MerginMaps/geodiff.git "$GEODIFF_SHA"
  git -C geodiff checkout -q FETCH_HEAD
fi
[ "$(git -C geodiff rev-parse HEAD)" = "$GEODIFF_SHA" ] || { echo "geodiff が $GEODIFF_SHA ではない（作業dirの geodiff/ を消して焼き直す）" >&2; exit 1; }
mkdir -p "build-$ABI" && pushd "build-$ABI" >/dev/null
[ -f libgpkg.tar.gz ] || curl -fsSL -o libgpkg.tar.gz "$LIBGPKG_URL"
verify_sha256 libgpkg.tar.gz "$LIBGPKG_SHA256"
"$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$(cygpath -m "$NINJA")" \
  -DCMAKE_TOOLCHAIN_FILE="$(cygpath -m "$NDK/build/cmake/android.toolchain.cmake")" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_TOOLS=OFF -DENABLE_TESTS=OFF -DWITH_POSTGRESQL=OFF -DPEDANTIC=OFF \
  -DSQLite3_INCLUDE_DIR="$(cygpath -m "$W/$SQL_DIR")" -DSQLite3_LIBRARY="$(cygpath -m "$W/sqlite-$ABI/libsqlite3.a")" \
  "$(cygpath -m "$W/geodiff/geodiff")" >/dev/null
"$NINJA" | tail -1
"$TC/llvm-strip.exe" --strip-unneeded -o libgeodiff.stripped.so libgeodiff.so
popd >/dev/null

OUT="$REPO/android/app/src/main/jniLibs/$ABI"; mkdir -p "$OUT"
cp "build-$ABI/libgeodiff.stripped.so" "$OUT/libgeodiff.so"
echo "== 出力: $OUT/libgeodiff.so ($(stat -c %s "$OUT/libgeodiff.so") bytes)"
"$TC/llvm-readelf.exe" -d "$OUT/libgeodiff.so" | grep NEEDED
