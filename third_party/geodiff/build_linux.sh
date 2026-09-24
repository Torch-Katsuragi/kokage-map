#!/usr/bin/env bash
# libgeodiff.so（Linux x64）を焼く。CI（ubuntu）のホスト VM テスト用。
#
# 依存: gcc/g++・cmake・curl・git（ubuntu-latest に入っている）。sqlite3 は amalgamation を
# session 拡張つきで静的にリンクする（Android / Windows と同じ構成。third_party/geodiff/README.md）。
# 出力: third_party/geodiff/linux/libgeodiff.so（コミットしない。.gitignore）
#
# 使い方: third_party/geodiff/build_linux.sh [作業dir]
set -euo pipefail

GEODIFF_TAG="${GEODIFF_TAG:-2.3.1}"
SQLITE_ZIP="${SQLITE_ZIP:-https://sqlite.org/2026/sqlite-amalgamation-3530400.zip}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="${1:-$REPO/build/geodiff-linux}"; mkdir -p "$W"; cd "$W"

[ -f sqlite.zip ] || curl -sSL -o sqlite.zip "$SQLITE_ZIP"
SQL_DIR="$(unzip -Z1 sqlite.zip | head -1 | cut -d/ -f1)"
[ -d "$SQL_DIR" ] || unzip -q sqlite.zip

mkdir -p sqlite-x64 && pushd sqlite-x64 >/dev/null
gcc -O2 -fPIC -c "../$SQL_DIR/sqlite3.c" -o sqlite3.o \
  -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_RTREE \
  -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0
ar rcs libsqlite3.a sqlite3.o
popd >/dev/null

[ -d geodiff ] || git clone -q --depth 1 --branch "$GEODIFF_TAG" https://github.com/MerginMaps/geodiff.git
mkdir -p build-x64 && pushd build-x64 >/dev/null
cmake -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_TOOLS=OFF -DENABLE_TESTS=OFF -DWITH_POSTGRESQL=OFF -DPEDANTIC=OFF \
  -DSQLite3_INCLUDE_DIR="$W/$SQL_DIR" -DSQLite3_LIBRARY="$W/sqlite-x64/libsqlite3.a" \
  "$W/geodiff/geodiff" >/dev/null
make -j"$(nproc)" >/dev/null
popd >/dev/null

OUT="$REPO/third_party/geodiff/linux"; mkdir -p "$OUT"
cp build-x64/libgeodiff.so "$OUT/libgeodiff.so"
echo "== 出力: $OUT/libgeodiff.so ($(stat -c %s "$OUT/libgeodiff.so") bytes)"
