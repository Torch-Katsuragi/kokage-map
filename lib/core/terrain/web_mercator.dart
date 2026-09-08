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

/// Web Mercator（EPSG:3857）の座標・タイル計算
///
/// 3D 地形の内部座標は 2D 地図と同じ Web Mercator（m）。
/// 標高は真のメートルなので、描画時に [zScaleAt] を掛けて水平の伸びに合わせる。
class WebMercator {
  WebMercator._();

  static const double radius = 6378137.0;
  static const double halfCircumference = math.pi * radius;
  static const int tileSize = 256;

  static double xFromLon(double lonDeg) => radius * lonDeg * math.pi / 180;

  static double yFromLat(double latDeg) =>
      radius * math.log(math.tan(math.pi / 4 + latDeg * math.pi / 360));

  static double lonFromX(double x) => x / radius * 180 / math.pi;

  static double latFromY(double y) =>
      (2 * math.atan(math.exp(y / radius)) - math.pi / 2) * 180 / math.pi;

  /// 緯度 φ での Mercator の伸び `1/cos(φ)`。標高に掛ける倍率
  static double zScaleAt(double latDeg) => 1 / math.cos(latDeg * math.pi / 180);

  /// ズーム z の 1 タイルの一辺（Mercator m）
  static double tileSpan(int z) => 2 * halfCircumference / (1 << z);

  /// ズーム z の 1 ピクセルの一辺（Mercator m）
  static double metersPerPixel(int z) => tileSpan(z) / tileSize;

  /// 経度 → タイル x（小数）
  static double tileXFraction(double lonDeg, int z) => (lonDeg + 180) / 360 * (1 << z);

  /// 緯度 → タイル y（小数、北が 0）
  static double tileYFraction(double latDeg, int z) {
    final lat = latDeg * math.pi / 180;
    return (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * (1 << z);
  }

  /// タイル (tx, ty) の西端の Mercator x
  static double tileWest(int tx, int z) => -halfCircumference + tx * tileSpan(z);

  /// タイル (tx, ty) の北端の Mercator y
  static double tileNorth(int ty, int z) => halfCircumference - ty * tileSpan(z);
}
