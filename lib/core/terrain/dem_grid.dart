// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
import 'dart:math' as math;
import 'dart:typed_data';

/// 規則格子の DEM（標高場）
///
/// 座標は 2D 地図と同じ Web Mercator（m）。標高は真のメートルで持ち、
/// 描画時に緯度の倍率 `1/cos(φ)` を掛ける（[TerrainCamera.zScale]）。
/// 格子は左下 ([originX], [originY]) から東・北へ [cellSize] 刻み。
class DemGrid {
  DemGrid({
    required this.cols,
    required this.rows,
    required this.originX,
    required this.originY,
    required this.cellSize,
    required this.heights,
  }) : assert(heights.length == cols * rows);

  /// 東西方向の格子点数
  final int cols;

  /// 南北方向の格子点数
  final int rows;

  /// 左下の格子点の Mercator x（m）
  final double originX;

  /// 左下の格子点の Mercator y（m）
  final double originY;

  /// 格子間隔（Mercator m）
  final double cellSize;

  /// 標高（m）。行優先、南から北へ
  final Float32List heights;

  double get width => (cols - 1) * cellSize;
  double get height => (rows - 1) * cellSize;

  (double, double)? _range;

  /// 標高の最小・最大（初回に 1 度だけ走査。65k 点で数 ms）
  (double, double) get heightRange => _range ??= _scanRange();

  (double, double) _scanRange() {
    var minH = double.infinity, maxH = -double.infinity;
    final h = heights;
    for (var i = 0; i < h.length; i++) {
      final v = h[i];
      if (v < minH) minH = v;
      if (v > maxH) maxH = v;
    }
    return (minH, maxH);
  }

  double heightAtIndex(int c, int r) => heights[r * cols + c];

  /// 双一次補間で任意点の標高を返す。格子外は端の値
  double elevationAt(double x, double y) {
    final fx = ((x - originX) / cellSize).clamp(0.0, cols - 1.0);
    final fy = ((y - originY) / cellSize).clamp(0.0, rows - 1.0);
    final c0 = fx.floor().clamp(0, cols - 2);
    final r0 = fy.floor().clamp(0, rows - 2);
    final tx = fx - c0;
    final ty = fy - r0;
    final h00 = heightAtIndex(c0, r0);
    final h10 = heightAtIndex(c0 + 1, r0);
    final h01 = heightAtIndex(c0, r0 + 1);
    final h11 = heightAtIndex(c0 + 1, r0 + 1);
    return (h00 * (1 - tx) + h10 * tx) * (1 - ty) +
        (h01 * (1 - tx) + h11 * tx) * ty;
  }

  /// スパイク用の合成地形。尾根と谷をいくつか重ねた起伏
  ///
  /// [relief] は最大起伏の目安（m）。実際の山地に近い 300m 程度を既定にする
  factory DemGrid.synthetic({
    int cols = 401,
    int rows = 401,
    double cellSize = 5,
    double originX = 0,
    double originY = 0,
    double relief = 300,
    int seed = 1,
  }) {
    final rnd = math.Random(seed);
    // 周波数・向き・振幅の違う波を足して山塊を作る
    final waves = List.generate(6, (i) {
      final wavelength = 400.0 * math.pow(1.7, i); // 400m 〜 5.7km
      return (
        kx: math.cos(rnd.nextDouble() * math.pi) / wavelength * 2 * math.pi,
        ky: math.sin(rnd.nextDouble() * math.pi) / wavelength * 2 * math.pi,
        phase: rnd.nextDouble() * 2 * math.pi,
        amp: 1.0 / (i + 1),
      );
    });
    final heights = Float32List(cols * rows);
    var minH = double.infinity;
    var maxH = -double.infinity;
    for (var r = 0; r < rows; r++) {
      final y = r * cellSize;
      for (var c = 0; c < cols; c++) {
        final x = c * cellSize;
        var h = 0.0;
        for (final w in waves) {
          h += w.amp * math.sin(w.kx * x + w.ky * y + w.phase);
        }
        // 谷を鋭く、尾根を丸く（指数で歪める）
        h = h.abs() * h.sign;
        heights[r * cols + c] = h;
        if (h < minH) minH = h;
        if (h > maxH) maxH = h;
      }
    }
    final span = maxH - minH;
    for (var i = 0; i < heights.length; i++) {
      heights[i] = (heights[i] - minH) / span * relief + 200;
    }
    return DemGrid(
      cols: cols,
      rows: rows,
      originX: originX,
      originY: originY,
      cellSize: cellSize,
      heights: heights,
    );
  }
}
