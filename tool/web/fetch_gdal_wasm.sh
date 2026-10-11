#!/usr/bin/env bash
# web 版の GDAL（GDAL 3.13 + PROJ 9.9 の WebAssembly）を web/gdal3/<組>/ に置く。設計は docs/technical/gdal.md「web」
#
#   bash tool/web/fetch_gdal_wasm.sh
#
# 中身は third_party/gdal/build_web.sh で自分たちが焼いたもの（Android の libgdal.so と同じ版・同じドライバの組）。
# 40 MB ほどあるのでリポジトリには入れず（web/gdal3/<組>/ は .gitignore 済み）、GitHub の Release
# （タグ gdal-wasm-<組>）に上げたものを取ってくる。どのファイルも SHA-256 で照合する。
# `flutter build web` の前に一度回す。CI の build (web) とデプロイ手順（docs/technical/web-hosting.md）にも入れてある。
#
# 手元で build_web.sh を回したときは同じ場所に書き出されるので、このスクリプトは「揃っている」で終わる。
#
# 組を変えるとき（焼き直したとき）:
#   1. build_web.sh の BUILD を上げて焼く。最後に出る SHA256SUMS を下の FILE_SHA256 に写し、BUILD を揃える
#   2. Release を作って 4 ファイルを上げる（人の作業。gh を使うなら）:
#        gh release create gdal-wasm-<組> web/gdal3/<組>/{gdal.js,gdal.wasm,gdal.data,LICENSE} \
#          --title "GDAL WebAssembly <組>" --notes "third_party/gdal/build_web.sh で焼いたもの"
#   3. lib/core/gdal/gdal_web.dart の kGdalWasmBuild を揃え、web/gdal3/<旧組>/ を消す
set -euo pipefail

BUILD=3.13.3-1
BASE_URL="${GDAL_WASM_BASE_URL:-https://github.com/Torch-Katsuragi/kokage-map/releases/download/gdal-wasm-$BUILD}"
declare -A FILE_SHA256=(
  [gdal.js]=6f3af2af5739568e078afcde559c7cf17ef5c8605f6292a18ed5beefdc91c924
  [gdal.wasm]=f0423d88d011c8486e0c56a88f50c3b789284457d87035e0799783c04a95dc22
  [gdal.data]=b664291f33753f95f44713485cfa7469452ca4d844ee7fbaf15111b2d25dfba6
  [LICENSE]=e7f3e020f6783249720b6b6a4da3a0988212e267539d0b28e103b43a7c2fc91f
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="$ROOT/web/gdal3/$BUILD"

sha256() { sha256sum "$1" | cut -d' ' -f1; }

# 既に揃っていれば何もしない
ok=1
for f in "${!FILE_SHA256[@]}"; do
  if [ ! -f "$DEST/$f" ] || [ "$(sha256 "$DEST/$f")" != "${FILE_SHA256[$f]}" ]; then ok=0; break; fi
done
if [ "$ok" = 1 ]; then
  echo "GDAL の WASM（$BUILD）は揃っている: $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "GDAL の WASM（$BUILD）を取得中: $BASE_URL"
for f in "${!FILE_SHA256[@]}"; do
  curl -fsSL -o "$TMP/$f" "$BASE_URL/$f"
  actual="$(sha256 "$TMP/$f")"
  if [ "$actual" != "${FILE_SHA256[$f]}" ]; then
    echo "$f の SHA-256 が合わない: $actual（期待 ${FILE_SHA256[$f]}）" >&2
    exit 1
  fi
done
mkdir -p "$DEST"
for f in "${!FILE_SHA256[@]}"; do cp "$TMP/$f" "$DEST/$f"; done

echo "GDAL の WASM（$BUILD）を置いた: $DEST"
ls -l "$DEST"
