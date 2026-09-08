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
import 'dart:ui';

import 'dem_grid.dart';

/// DEM から等高線を引く（marching squares）
///
/// 出力は DEM 原点基準の 2D 折れ線。標高は等高線の高さそのものなので、
/// 持ち上げると地表にぴったり乗る（`LiftedPolyline.lift` で DEM を引き直しても同じ値になる）。
/// セルごとの線分を出すだけで、つなぎ合わせはしない（描画には十分。ラベル付けは別途）。
class ContourExtractor {
  ContourExtractor._();

  /// [interval] ごとの等高線を、高さ → 線分リスト（2 点の折れ線）で返す
  ///
  /// [step] で格子を間引ける（広域で線が多すぎるとき）。
  static Map<double, List<List<Offset>>> extract(
    DemGrid dem, {
    required double interval,
    int step = 1,
  }) {
    final cols = (dem.cols - 1) ~/ step + 1;
    final rows = (dem.rows - 1) ~/ step + 1;
    final cell = dem.cellSize * step;
    double h(int c, int r) => dem.heightAtIndex(c * step, r * step);
    var minH = double.infinity;
    var maxH = -double.infinity;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final v = h(c, r);
        if (v < minH) minH = v;
        if (v > maxH) maxH = v;
      }
    }
    final result = <double, List<List<Offset>>>{};
    final first = (minH / interval).ceil() * interval;
    for (var level = first; level <= maxH; level += interval) {
      final segments = <List<Offset>>[];
      for (var r = 0; r + 1 < rows; r++) {
        for (var c = 0; c + 1 < cols; c++) {
          // 角: 0=SW 1=SE 2=NE 3=NW
          final v = [h(c, r), h(c + 1, r), h(c + 1, r + 1), h(c, r + 1)];
          var code = 0;
          for (var i = 0; i < 4; i++) {
            if (v[i] >= level) code |= 1 << i;
          }
          if (code == 0 || code == 15) continue;
          final x0 = c * cell;
          final y0 = r * cell;
          // 辺上の交点（辺 0=南 1=東 2=北 3=西）
          Offset edgePoint(int e) {
            final (a, b) = switch (e) { 0 => (0, 1), 1 => (1, 2), 2 => (3, 2), _ => (0, 3) };
            final t = (v[a] == v[b]) ? 0.5 : ((level - v[a]) / (v[b] - v[a])).clamp(0.0, 1.0);
            return switch (e) {
              0 => Offset(x0 + t * cell, y0),
              1 => Offset(x0 + cell, y0 + t * cell),
              2 => Offset(x0 + t * cell, y0 + cell),
              _ => Offset(x0, y0 + t * cell),
            };
          }

          // 鞍点（5, 10）は中心の値で分ける
          final edges = _edgesFor(code, (v[0] + v[1] + v[2] + v[3]) / 4 >= level);
          for (var i = 0; i + 1 < edges.length; i += 2) {
            segments.add([edgePoint(edges[i]), edgePoint(edges[i + 1])]);
          }
        }
      }
      if (segments.isNotEmpty) result[level] = segments;
    }
    return result;
  }

  /// marching squares の辺の組（コード → 交わる辺の並び）
  static List<int> _edgesFor(int code, bool centerHigh) => switch (code) {
        1 => const [3, 0],
        2 => const [0, 1],
        3 => const [3, 1],
        4 => const [1, 2],
        5 => centerHigh ? const [3, 2, 0, 1] : const [3, 0, 1, 2],
        6 => const [0, 2],
        7 => const [3, 2],
        8 => const [2, 3],
        9 => const [0, 2],
        10 => centerHigh ? const [0, 3, 2, 1] : const [0, 1, 2, 3],
        11 => const [2, 1],
        12 => const [1, 3],
        13 => const [0, 1],
        14 => const [3, 0],
        _ => const [],
      };
}
