# 負荷確認用の GeoPackage を生成する。
#
# integration_test/benchmark/ はGeoJSONをメモリ上で組み立てて地図バックエンドを測るが、
# 「実アプリでGeoPackageを開いて表示する」ほうの確認にはファイルが要る。
# 8.5MB の成果物をリポジトリに置くのは避け、必要なときに生成する。
#
# 使い方（geopandas が要る）:
#   python tool/gen_load_test_gpkg.py 10000 40 out.gpkg layer_name
#
# 2026-08-21 の Windows版復活作業では、これで作った1万ポリゴン(40頂点)の
# GeoPackage を release ビルドに読ませて実用範囲であることを確認した。
import math
import sys

import geopandas as gpd
from shapely.geometry import Polygon

COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
VERTS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
OUT = sys.argv[3] if len(sys.argv) > 3 else "load_test.gpkg"
LAYER = sys.argv[4] if len(sys.argv) > 4 else "load_test"

# 基準座標を中心に格子状配置
BASE_LON, BASE_LAT = 139.24, 35.63
COLS = 100
STEP = 0.0020
R = 0.0008

rows = []
for i in range(COUNT):
    cx = BASE_LON + (i % COLS) * STEP
    cy = BASE_LAT + (i // COLS) * STEP
    # 半径を少し揺らして単調な格子に見えないようにする
    r = R * (0.6 + 0.4 * ((i * 37) % 100) / 100.0)
    coords = [
        (cx + r * math.cos(2 * math.pi * v / VERTS),
         cy + r * math.sin(2 * math.pi * v / VERTS))
        for v in range(VERTS)
    ]
    rows.append(
        {
            "geometry": Polygon(coords),
            "name": f"区画{i:05d}",
            "description": f"負荷確認用ポリゴン {i}",
            "area_ha": round(math.pi * r * r * 1_000_000, 3),
        }
    )

gdf = gpd.GeoDataFrame(rows, crs="EPSG:4326")
gdf.to_file(OUT, layer=LAYER, driver="GPKG")

print(f"wrote {OUT} layer={LAYER} count={len(gdf)} verts/poly={VERTS}")
print("bounds:", gdf.total_bounds)
