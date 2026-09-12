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
// こかげマップ: 地形の見た目（傾斜・標高の色分け、等高線）
//
// テクスチャを作るのではなく、GPU が持つ頂点の傾斜・標高からフラグメントシェーダで色を引く。
// 解像度はメッシュに依り、横から見ても粗くならない（松本 2026-09-12 の「上から投影すると
// 横から見たとき粗い」への答え）。色の帯（ランプ）は 256×1 の小さなテクスチャで渡す。
// 等高線は DEM から線として作り、線シェーダで描く（傾けても細いまま）。
//
// 設定は `TerrainSettingsScreen`（SettingsStore）で、ここは描画側が毎フレーム読む静的なスナップショット。


import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

enum TerrainColorMode {
  /// 基図のまま
  none,

  /// 傾斜（急なほど [TerrainAppearance.high] 側）
  slope,

  /// 標高（見えている範囲の低いところが [TerrainAppearance.low]、高いところが [TerrainAppearance.high]）
  elevation,
}

class TerrainAppearance {
  TerrainAppearance._();

  static TerrainColorMode colorMode = TerrainColorMode.none;

  /// 色分けを基図にどれだけ被せるか（0 = 基図のまま、1 = 色分けだけ＝基図なし）
  static double colorStrength = 0.7;

  /// 色の帯（低い／緩い → 中 → 高い／急）
  static Color low = const Color(0xFF2E7D32);
  static Color mid = const Color(0xFFFFF176);
  static Color high = const Color(0xFFB71C1C);

  /// 傾斜モード: この角度で [high]（それ以上は頭打ち）
  static double slopeMaxDeg = 45;

  static bool contours = false;

  /// 等高線の間隔（m）と、何本ごとに主曲線（太く）にするか
  static double contourIntervalM = 10;
  static int contourMajorEvery = 5;
  static Color contourColor = const Color(0xCC6D4C41);
  static double contourWidthPx = 1;

  /// 設定が変わるたびに増える。描画側はこれを見てランプや等高線を作り直す
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void bump() => revision.value++;

  /// 色分けをするか
  static bool get colored => colorMode != TerrainColorMode.none && colorStrength > 0;

  /// ランプを 256×1 の RGBA に（premultiplied でない。alpha は 255）
  static Uint8List rampBytes() {
    final out = Uint8List(256 * 4);
    for (var i = 0; i < 256; i++) {
      final t = i / 255;
      final c = t < 0.5 ? Color.lerp(low, mid, t * 2)! : Color.lerp(mid, high, (t - 0.5) * 2)!;
      out[i * 4] = (c.r * 255).round();
      out[i * 4 + 1] = (c.g * 255).round();
      out[i * 4 + 2] = (c.b * 255).round();
      out[i * 4 + 3] = 255;
    }
    return out;
  }

  /// 主曲線か（[level] は等高線の高さ）
  static bool isMajor(double level) {
    final n = (level / contourIntervalM).round();
    return contourMajorEvery > 0 && n % contourMajorEvery == 0;
  }
}
