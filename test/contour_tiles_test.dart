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
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:root_maps/core/terrain/contour_tiles.dart';

/// 等高線タイルの置き場所。DEM の格子点はピクセルの中心なので、線は格子の座標に半セル足した所に来る
void main() {
  const cells = 64;
  const cellSize = 10.0; // タイル 640 m → 256 px（0.4 px/m）
  const n = cells + 4;

  Set<int> nonEmptyColumns(img.Image im) => {
        for (var y = 0; y < im.height; y++)
          for (var x = 0; x < im.width; x++)
            if (im.getPixel(x, y).a > 0) x,
      };
  Set<int> nonEmptyRows(img.Image im) => {
        for (var y = 0; y < im.height; y++)
          for (var x = 0; x < im.width; x++)
            if (im.getPixel(x, y).a > 0) y,
      };

  test('東西に傾く面: 100 m の線は格子 10 列目 = (10 + 0.5) セル → 42 px', () {
    final heights = Float32List(n * n);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        heights[r * n + c] = c * cellSize; // 高さ = 東西の位置（m）
      }
    }
    final png = renderContourTilePng(ContourTileArgs(
      heights: heights,
      cols: n,
      rows: n,
      cellSize: cellSize,
      col0: 0,
      row0: 0,
      cells: cells,
      interval: 100,
    ));
    final cols = nonEmptyColumns(img.decodePng(png)!);
    expect(cols, contains(42));
    expect(cols, isNot(contains(40)));
  });

  test('南北に傾く面: 100 m の線は格子 10 行目 → 上から (640 - 105) × 0.4 = 214 px', () {
    final heights = Float32List(n * n);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        heights[r * n + c] = r * cellSize; // 高さ = 南からの位置（m）
      }
    }
    final png = renderContourTilePng(ContourTileArgs(
      heights: heights,
      cols: n,
      rows: n,
      cellSize: cellSize,
      col0: 0,
      row0: 0,
      cells: cells,
      interval: 100,
    ));
    final rows = nonEmptyRows(img.decodePng(png)!);
    expect(rows, contains(214));
    expect(rows, isNot(contains(216)));
  });
}
