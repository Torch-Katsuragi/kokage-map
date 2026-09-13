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
import 'package:root_maps/core/terrain/dem_tiles.dart';

/// DEM の穴埋め: 台地（先頭の有効値の板）にならず、周りから補間される
void main() {
  const nan = double.nan;

  test('行の中の穴は左右の間を補間', () {
    final h = Float32List.fromList([10, nan, nan, 40]);
    fillInvalidHeights(h, cols: 4);
    expect(h, [10, 20, 30, 40]);
  });

  test('行の端の穴は近い方の値', () {
    final h = Float32List.fromList([nan, 5, 7, nan]);
    fillInvalidHeights(h, cols: 4);
    expect(h, [5, 5, 7, 7]);
  });

  test('先頭（南）の行が丸ごと無効でも台地にならず、上下の行から補間される', () {
    // 4 列 × 4 行。0〜1 行目が川（無効）、上（有効な行）しか無いので写す
    final h = Float32List.fromList([
      nan, nan, nan, nan, //
      nan, nan, nan, nan, //
      100, 100, 100, 100, //
      120, 120, 120, 120, //
    ]);
    fillInvalidHeights(h, cols: 4);
    expect(h.sublist(0, 8), everyElement(100));
    // 上下に有効な行があれば間を補間（旧実装は 50 の板）
    final g = Float32List.fromList([
      50, 50, 50, 50, //
      nan, nan, nan, nan, //
      nan, nan, nan, nan, //
      80, 80, 80, 80, //
    ]);
    fillInvalidHeights(g, cols: 4);
    expect(g.sublist(4, 8), everyElement(60));
    expect(g.sublist(8, 12), everyElement(70));
  });

  test('全部無効なら 0', () {
    final h = Float32List.fromList([nan, nan, nan, nan]);
    fillInvalidHeights(h, cols: 2);
    expect(h, everyElement(0));
  });

  test('cols 無しは従来（直前の値）', () {
    final h = Float32List.fromList([nan, 3, nan, 9]);
    fillInvalidHeights(h);
    expect(h, [3, 3, 3, 9]);
  });
}
