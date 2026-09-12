// 隣の縁を借りる（`TerrainTile.updateBorder`）が同じ地形の隣なら段差を作らないこと
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

void main() {
  const n = WebMercator.tileSize;

  /// 世界座標の関数 f(x, y) からタイルの DEM を作る（南が 0 行目）
  TerrainTile tileOf(int z, int x, int y, double Function(double, double) f, {int? sourceZoom}) {
    final span = WebMercator.tileSpan(z);
    final cell = span / n;
    final west = WebMercator.tileWest(x, z);
    final south = WebMercator.tileNorth(y, z) - span;
    final h = Float32List(n * n);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        h[r * n + c] = f(west + c * cell, south + r * cell);
      }
    }
    return TerrainTile(
      key: TileKey(z, x, y),
      raw: DemGrid(cols: n, rows: n, originX: west, originY: south, cellSize: cell, heights: h),
      sourceZoom: sourceZoom,
    );
  }

  double hill(double x, double y) => 300 + 0.05 * x.remainder(5000) + 0.03 * y.remainder(7000);

  test('同じ地形の隣なら借りた縁の段差は 1 セルぶん以下', () {
    final a = tileOf(15, 28760, 13097, hill);
    final east = tileOf(15, 28761, 13097, hill);
    final north = tileOf(15, 28760, 13096, hill);
    final ne = tileOf(15, 28761, 13096, hill);
    a.updateBorder(east, north, ne);
    // 借りた列（256 列目）は東の 0 列目
    expect(a.bordered.heightAtIndex(n, 10), east.raw.heightAtIndex(0, 10));
    expect(a.bordered.heightAtIndex(10, n), north.raw.heightAtIndex(10, 0));
    expect(a.lastSeamM, lessThan(1.0), reason: '隣接列の差は 1 セルの勾配ぶんだけ');
  });

  test('隣が自分より粗い近似なら縁は借りず、自分の縁を延ばす', () {
    final a = tileOf(15, 28760, 13097, hill);
    final coarse = tileOf(15, 28761, 13097, (x, y) => 9999, sourceZoom: 12);
    a.updateBorder(coarse, null, null);
    expect(a.bordered.heightAtIndex(n, 10), a.raw.heightAtIndex(n - 1, 10));
    expect(a.lastSeamM, 0);
  });
}
