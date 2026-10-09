#!/usr/bin/env bash
# web 版の GDAL（gdal3.js）を web/gdal3/<版>/ に取ってくる。設計は docs/technical/gdal.md「web」
#
#   bash tool/web/fetch_gdal3.sh
#
# 40 MB ほどあるのでリポジトリには入れない（web/gdal3/<版>/ は .gitignore 済み）。
# `flutter build web` の前に一度回す。CI の build (web) とデプロイ手順（docs/technical/web-hosting.md）にも入れてある。
# 版を上げるときは VERSION と SHA256 を揃えて書き換え、lib/core/gdal/gdal_web.dart の kGdal3Version も合わせる。
#
# 取得元は npm の tarball（GitHub のリリースには成果物が付いていない）。
# 中身の 3 ファイルにも SHA-256 を当てる（tarball が正しくても取り出しで壊れていないことを見る）。
set -euo pipefail

VERSION=2.8.1
TARBALL_SHA256=cda53c47fcfb608a37bc400d4765e2d7d66524a6061f8b406cc767d57738096c
declare -A FILE_SHA256=(
  [gdal3.js]=ec11ced2b626f9738015c3c4e9f3d670d00213a9083c5a06074d39624e6e8921
  [gdal3WebAssembly.wasm]=350eec4ce9ae4bc10bcafd8621463e057abdbb8f8372f0d8e0af06e6b8561835
  [gdal3WebAssembly.data]=e473e1e9f20af114bbb491d9cf7ef154986708a7ec763b22181c5e5f012f889e
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="$ROOT/web/gdal3/$VERSION"

sha256() { sha256sum "$1" | cut -d' ' -f1; }

# 既に揃っていれば何もしない
ok=1
for f in "${!FILE_SHA256[@]}"; do
  if [ ! -f "$DEST/$f" ] || [ "$(sha256 "$DEST/$f")" != "${FILE_SHA256[$f]}" ]; then ok=0; break; fi
done
if [ "$ok" = 1 ]; then
  echo "gdal3.js $VERSION は揃っている: $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "gdal3.js $VERSION を取得中…"
curl -fsSL -o "$TMP/gdal3.tgz" "https://registry.npmjs.org/gdal3.js/-/gdal3.js-$VERSION.tgz"
actual="$(sha256 "$TMP/gdal3.tgz")"
if [ "$actual" != "$TARBALL_SHA256" ]; then
  echo "tarball の SHA-256 が合わない: $actual（期待 $TARBALL_SHA256）" >&2
  exit 1
fi

mkdir -p "$TMP/x"
tar -xzf "$TMP/gdal3.tgz" -C "$TMP/x" \
  package/LICENSE \
  package/dist/package/gdal3.js \
  package/dist/package/gdal3WebAssembly.wasm \
  package/dist/package/gdal3WebAssembly.data

mkdir -p "$DEST"
for f in "${!FILE_SHA256[@]}"; do
  src="$TMP/x/package/dist/package/$f"
  actual="$(sha256 "$src")"
  if [ "$actual" != "${FILE_SHA256[$f]}" ]; then
    echo "$f の SHA-256 が合わない: $actual（期待 ${FILE_SHA256[$f]}）" >&2
    exit 1
  fi
  cp "$src" "$DEST/$f"
done
# LGPL-2.1-or-later。配る物に条文を添える
cp "$TMP/x/package/LICENSE" "$DEST/LICENSE"

echo "gdal3.js $VERSION を置いた: $DEST"
ls -l "$DEST"
