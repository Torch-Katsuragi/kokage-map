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

/// CS立体図（曲率×傾斜×標高の微地形表現タイル）の端末内自動生成。
///
/// 公開されている地域別 CS 立体図タイルは対象県が限られ色味も不統一だが、
/// こかげマップが既に持つ全国＋地域別 0.25〜1m 高精細 DEM カスケード（`DemTiles`）から
/// `TerrainWorker` 内で直接計算することで、日本全国どこでも（オフラインでも）
/// 樹冠下の作業道・崩壊跡・尾根谷の微地形を 256×256 PNG タイルとして生成・キャッシュする。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class CsReliefTiles {
  CsReliefTiles._();

  /// 絵の配色・計算式を変えたら上げる（古いキャッシュ `cs_relief_v*` は `BaseMapService` が自動で消す）
  static const version = 1;
}

class CsReliefTileArgs {
  const CsReliefTileArgs({
    required this.heights,
    required this.cols,
    required this.rows,
    required this.cellSize,
    required this.col0,
    required this.row0,
    required this.cells,
    this.size = 256,
  });

  /// DEM の格子（南が 0 行目）
  final Float32List heights;
  final int cols;
  final int rows;
  final double cellSize;

  /// タイルの南西角にあたる格子位置と 1 辺のセル数
  final int col0;
  final int row0;
  final int cells;
  final int size;
}

/// `TerrainWorker` で走らせるトップレベル関数: DEM 格子から 256×256 の CS立体図 PNG を生成する
Uint8List renderCsReliefTilePng(CsReliefTileArgs a) {
  final out = img.Image(width: a.size, height: a.size, numChannels: 4);
  final h = a.heights;
  final cols = a.cols;
  final rows = a.rows;
  final cs = math.max(a.cellSize, 0.25);

  double sampleClamped(int c, int r) {
    final cc = c.clamp(0, cols - 1);
    final rr = r.clamp(0, rows - 1);
    final v = h[rr * cols + cc];
    return v.isFinite ? v : 0.0;
  }

  // 256px 出力の各ピクセルに対応する DEM 座標（北が py=0、南が row=0 なので反転）
  final scale = a.cells / a.size;

  for (var py = 0; py < a.size; py++) {
    // py=0 が北端 (row0 + cells - 0.5)
    final fy = a.row0 + a.cells - (py + 0.5) * scale;
    final r = fy.floor();
    for (var px = 0; px < a.size; px++) {
      final fx = a.col0 + (px + 0.5) * scale;
      final c = fx.floor();

      final zC = sampleClamped(c, r);
      final zW = sampleClamped(c - 1, r);
      final zE = sampleClamped(c + 1, r);
      final zS = sampleClamped(c, r - 1);
      final zN = sampleClamped(c, r + 1);
      final zNW = sampleClamped(c - 1, r + 1);
      final zNE = sampleClamped(c + 1, r + 1);
      final zSW = sampleClamped(c - 1, r - 1);
      final zSE = sampleClamped(c + 1, r - 1);

      // Horn 法による傾斜角（rad → 0..1 正規化）
      final dzdx = ((zNE + 2.0 * zE + zSE) - (zNW + 2.0 * zW + zSW)) / (8.0 * cs);
      final dzdy = ((zNW + 2.0 * zN + zNE) - (zSW + 2.0 * zS + zSE)) / (8.0 * cs);
      final slopeDeg = math.atan(math.sqrt(dzdx * dzdx + dzdy * dzdy)) * (180.0 / math.pi);
      final slopeT = (slopeDeg / 55.0).clamp(0.0, 1.0);

      // 多重スケール風ラプラシアン曲率（凸＝尾根 > 0、凹＝谷 < 0）
      // 1 セル近傍と対角平均を組み合わせて階段ノイズを抑える
      final meanCross = 0.25 * (zW + zE + zS + zN);
      final meanDiag = 0.25 * (zNW + zNE + zSW + zSE);
      final curvRaw = ((zC - meanCross) * 0.65 + (zC - meanDiag) * 0.35) / cs;
      // セルサイズに応じて感度を調整（0.5m〜10m DEM で同じ立体感になるよう正規化）
      final gain = (2.8 * math.sqrt(cs)).clamp(1.5, 10.0);
      final curv = (curvRaw * gain).clamp(-1.0, 1.0);

      // CS 立体図の配色合成:
      // 1) 標高＋傾斜ベース層（緩斜面＝淡いアイボリー、急斜面＝赤褐色）
      // 2) 曲率レイヤ（凸＝暖色赤茶〜明ベージュ、凹＝紺青〜水色）を乗算合成
      final baseR = _lerp(245.0, 128.0, slopeT);
      final baseG = _lerp(242.0, 82.0, slopeT);
      final baseB = _lerp(232.0, 62.0, slopeT);

      double curvR, curvG, curvB;
      if (curv >= 0) {
        // 尾根（凸）: アイボリー → 朱赤茶
        curvR = _lerp(242.0, 232.0, curv);
        curvG = _lerp(238.0, 122.0, curv);
        curvB = _lerp(228.0, 92.0, curv);
      } else {
        // 谷（凹）: アイボリー → 深い青藍
        final t = -curv;
        curvR = _lerp(242.0, 68.0, t);
        curvG = _lerp(238.0, 118.0, t);
        curvB = _lerp(228.0, 198.0, t);
      }

      // 乗算合成＋わずかな明度補正で見やすさを確保
      final rOut = ((baseR * curvR) / 238.0).round().clamp(0, 255);
      final gOut = ((baseG * curvG) / 238.0).round().clamp(0, 255);
      final bOut = ((baseB * curvB) / 238.0).round().clamp(0, 255);

      out.setPixelRgba(px, py, rOut, gOut, bOut, 255);
    }
  }
  return img.encodePng(out, level: 1);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
