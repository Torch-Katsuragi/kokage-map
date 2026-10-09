#!/usr/bin/env bash
# test/gdal_test.dart の小さな入力を QGIS 同梱の GDAL（ogr2ogr / gdal_create）で作り直す。Git Bash 前提。
#   bash test/fixtures/gdal/make_fixtures.sh ["C:/Program Files/QGIS 4.2.2"]
# 中身は北山村あたりの 3 点（名前は日本語）と、平面直角座標系 VI 系（EPSG:6674）の 8x8 の LZW GeoTIFF。
set -euo pipefail
Q="${1:-/c/Program Files/QGIS 4.2.2}"
export PATH="$Q/bin:$PATH"
export PROJ_DATA="$(cygpath -w "$Q/share/proj")"
cd "$(dirname "$0")"
rm -f points.* sjis_cpg.* sjis_nocpg.* dem_6674.tif

cat > points.geojson <<'EOF'
{"type":"FeatureCollection","features":[
{"type":"Feature","properties":{"name":"スギ1","dbh":32},"geometry":{"type":"Point","coordinates":[135.96,33.93]}},
{"type":"Feature","properties":{"name":"ヒノキ2","dbh":28},"geometry":{"type":"Point","coordinates":[135.961,33.931]}},
{"type":"Feature","properties":{"name":"北山村役場","dbh":0},"geometry":{"type":"Point","coordinates":[135.97,33.94]}}
]}
EOF

# Shift_JIS の shp（.cpg あり）。座標は EPSG:6674
ogr2ogr -f "ESRI Shapefile" -t_srs EPSG:6674 -lco ENCODING=CP932 sjis_cpg.shp points.geojson
# 同じ中身で .cpg なし・DBF の LDID も 0（古いソフトが書いた shp の形）
ogr2ogr -f "ESRI Shapefile" -t_srs EPSG:6674 -lco ENCODING=CP932 sjis_nocpg.shp points.geojson
rm -f sjis_nocpg.cpg
printf '\x00' | dd of=sjis_nocpg.dbf bs=1 seek=29 conv=notrunc status=none

ogr2ogr -f KML points.kml points.geojson
printf 'name,lon,lat\nスギ1,135.96,33.93\nヒノキ2,135.961,33.931\n北山村役場,135.97,33.94\n' > points.csv

# 8x8 の DEM 風ラスタ（EPSG:6674、10m 格子、LZW）
gdal_create -of GTiff -outsize 8 8 -bands 1 -ot Byte -burn 100 -a_srs EPSG:6674 \
  -a_ullr -3700 -229600 -3620 -229680 -co COMPRESS=LZW dem_6674.tif
rm -f *.aux.xml
ls -la
