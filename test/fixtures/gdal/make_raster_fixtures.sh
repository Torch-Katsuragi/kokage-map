#!/usr/bin/env bash
# test/gdal_raster_overlay_test.dart の小さなラスタを QGIS 同梱の GDAL（gdal_create / gdal_translate）で作り直す。Git Bash 前提。
#   bash test/fixtures/gdal/make_raster_fixtures.sh ["C:/Program Files/QGIS 4.2.2"]
# どれも北山村あたり。QGIS で普通に作ったラスタの形（アプリが書く GeoTIFF の形ではない）:
#   ext_rgb_6674.tif   … RGB、EPSG:6674、LZW、タイル分割（16x16）、40x24
#   ext_gray_4326.tif  … 1 バンド Byte、EPSG:4326、Deflate、nodata=0 の画素あり
#   ext_png.png        … PNG ＋ ワールドファイル（.pgw）＋ .aux.xml（CRS は EPSG:6674）
#   ext_dem_6674.tif   … Float32 の DEM、EPSG:6674、nodata=-9999 の画素あり
set -euo pipefail
Q="${1:-/c/Program Files/QGIS 4.2.2}"
export PATH="$Q/bin:$PATH"
export PROJ_DATA="$(cygpath -w "$Q/share/proj")"
cd "$(dirname "$0")"
rm -f ext_rgb_6674.tif ext_gray_4326.tif ext_png.* ext_dem_6674.tif
T="$(mktemp -d)"

gdal_create -of GTiff -outsize 40 24 -bands 3 -ot Byte -burn 30 -burn 120 -burn 60 -a_srs EPSG:6674 \
  -a_ullr -3700 -229600 -3300 -229840 -co COMPRESS=LZW -co TILED=YES -co BLOCKXSIZE=16 -co BLOCKYSIZE=16 \
  ext_rgb_6674.tif

# 6x4、左上の 2 画素が nodata（0.0005 度格子 ≒ 50 m）
cat > "$T/gray.asc" <<'EOF'
ncols 6
nrows 4
xllcorner 135.958
yllcorner 33.928
cellsize 0.0005
NODATA_value 0
0 0 10 20 30 40
50 60 70 80 90 100
110 120 130 140 150 160
170 180 190 200 210 220
EOF
gdal_translate -q -ot Byte -a_srs EPSG:4326 -co COMPRESS=DEFLATE "$T/gray.asc" ext_gray_4326.tif

# PNG ＋ワールドファイル。GDAL の PNG ドライバはワールドファイルを .wld で書くので .pgw に改名。CRS は .aux.xml に入る
gdal_translate -q -of PNG -co WORLDFILE=YES ext_rgb_6674.tif ext_png.png
mv ext_png.wld ext_png.pgw

# 5x4 の DEM（10 m 格子、標高 300〜480 m、1 画素が nodata）
cat > "$T/dem.asc" <<'EOF'
ncols 5
nrows 4
xllcorner -3700
yllcorner -229680
cellsize 10
NODATA_value -9999
300.5 310 320 330 340
350 360 370 380 390
400 410 -9999 430 440
450 460 470 480 479.5
EOF
gdal_translate -q -ot Float32 -a_srs EPSG:6674 -co COMPRESS=DEFLATE "$T/dem.asc" ext_dem_6674.tif

rm -rf "$T"
rm -f ext_rgb_6674.tif.aux.xml ext_gray_4326.tif.aux.xml ext_dem_6674.tif.aux.xml
ls -la ext_*
