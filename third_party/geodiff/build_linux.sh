#!/usr/bin/env bash
# libgeodiff.so（Linux x64）を焼く。CI（ubuntu）のホスト VM テスト用。
#
# 依存: gcc/g++・cmake・curl・git（ubuntu-latest に入っている）。sqlite3 は amalgamation を
# session 拡張つきで静的にリンクする（Android / Windows と同じ構成。third_party/geodiff/README.md）。
# 出力: third_party/geodiff/linux/libgeodiff.so（コミットしない。.gitignore）
#
# 使い方: third_party/geodiff/build_linux.sh [作業dir]
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

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="${1:-$REPO/build/geodiff-linux}"; mkdir -p "$W"; cd "$W"

[ -f sqlite.zip ] || curl -fsSL -o sqlite.zip "$SQLITE_ZIP"
verify_sha256 sqlite.zip "$SQLITE_SHA256"
SQL_DIR="$(unzip -Z1 sqlite.zip | head -1 | cut -d/ -f1)"
[ -d "$SQL_DIR" ] || unzip -q sqlite.zip

mkdir -p sqlite-x64 && pushd sqlite-x64 >/dev/null
gcc -O2 -fPIC -c "../$SQL_DIR/sqlite3.c" -o sqlite3.o \
  -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_RTREE \
  -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0
ar rcs libsqlite3.a sqlite3.o
popd >/dev/null

if [ ! -d geodiff ]; then
  git init -q geodiff
  git -C geodiff fetch -q --depth 1 https://github.com/MerginMaps/geodiff.git "$GEODIFF_SHA"
  git -C geodiff checkout -q FETCH_HEAD
fi
[ "$(git -C geodiff rev-parse HEAD)" = "$GEODIFF_SHA" ] || { echo "geodiff が $GEODIFF_SHA ではない（作業dirの geodiff/ を消して焼き直す）" >&2; exit 1; }
mkdir -p build-x64 && pushd build-x64 >/dev/null
[ -f libgpkg.tar.gz ] || curl -fsSL -o libgpkg.tar.gz "$LIBGPKG_URL"
verify_sha256 libgpkg.tar.gz "$LIBGPKG_SHA256"
cmake -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_TOOLS=OFF -DENABLE_TESTS=OFF -DWITH_POSTGRESQL=OFF -DPEDANTIC=OFF \
  -DSQLite3_INCLUDE_DIR="$W/$SQL_DIR" -DSQLite3_LIBRARY="$W/sqlite-x64/libsqlite3.a" \
  "$W/geodiff/geodiff" >/dev/null
make -j"$(nproc)" >/dev/null
popd >/dev/null

OUT="$REPO/third_party/geodiff/linux"; mkdir -p "$OUT"
cp build-x64/libgeodiff.so "$OUT/libgeodiff.so"
echo "== 出力: $OUT/libgeodiff.so ($(stat -c %s "$OUT/libgeodiff.so") bytes)"
