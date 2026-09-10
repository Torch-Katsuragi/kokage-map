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

/// `TerrainGpuRenderer` の 1 フレームの内訳（計測用）
class TerrainGpuStats {
  /// mvp の計算とユニフォームの書き込み
  Duration uniform = Duration.zero;

  /// コマンドの積み込みから submit まで（Dart 側の CPU 時間。GPU の実行時間ではない）
  Duration encode = Duration.zero;

  int drawCalls = 0;
  int terrainVertices = 0;
  int polygonVertices = 0;

  @override
  String toString() =>
      'gpu uniform=${uniform.inMicroseconds / 1000}ms encode=${encode.inMicroseconds / 1000}ms '
      'draws=$drawCalls terrainV=$terrainVertices polyV=$polygonVertices';
}
