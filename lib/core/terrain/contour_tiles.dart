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

import 'package:image/image.dart' as img;

import 'contours.dart';
import 'dem_grid.dart';

/// 等高線のラスタタイル（松本 2026-09-13「メッシュから計算した後はタイルとしてキャッシュして、背景地図として扱う」）
///
/// 標高タイル（DEM）から marching squares で線を引き、256×256 の透明 PNG にする。
/// `BaseMapService` の生成プロバイダ（[BaseMapProvider.contourOverlay]）として背景地図と同じタイルキャッシュに入り、
/// 3D のテクスチャに基図の上へ合成される。間隔はズームで決まり（地理院地図の刻み）、設定は「重ねる／重ねない」だけ。
/// 形として持ち上げるのをやめたので、傾けると線は絵として粗くなる（引いた段では気にならない）
class ContourTiles {
  ContourTiles._();

  /// タイルのズーム（テクスチャの段 = 表示ズーム）→ 間隔（m）。地理院地図に寄せる:
  /// 2 万 5 千分 1（z15〜16）= 10 m、5 千分 1（z17）= 5 m、2 千 5 百分 1（z18）= 2 m、z19 以上は 1 m（DEM1A）。引くと 20〜200 m
  static double intervalForZoom(int z) {
    if (z >= 19) return 1;
    return switch (z) {
      18 => 2,
      17 => 5,
      16 => 10,
      15 => 10,
      14 => 20,
      13 => 50,
      12 => 100,
      _ => 200,
    };
  }

  /// 何本ごとに主曲線（太く）にするか
  static const majorEvery = 5;

  /// 絵を変えたら上げる（タイルキャッシュのプロバイダ ID に入る。古い絵が残らないように）
  static const version = 2; // v1 は z16 が 5 m で詰まりすぎた（2026-09-13）
}

/// isolate へ渡す引数（DEM の格子の一部を、要求されたタイルの範囲として描く）
class ContourTileArgs {
  const ContourTileArgs({
    required this.heights,
    required this.cols,
    required this.rows,
    required this.cellSize,
    required this.col0,
    required this.row0,
    required this.cells,
    required this.interval,
    this.size = 256,
  });

  /// DEM の格子（南が 0 行目）
  final Float32List heights;
  final int cols;
  final int rows;
  final double cellSize;

  /// タイルの南西の角にあたる格子の位置（セル）と、タイルが覆うセル数（1 辺）
  final int col0;
  final int row0;
  final int cells;

  final double interval;
  final int size;
}

/// 等高線のタイルを PNG（RGBA、線以外は透明）にする。isolate で走る（純 Dart）
Uint8List renderContourTilePng(ContourTileArgs a) {
  // タイルの範囲 + 東・北に 1 サンプル（線が縁で切れないように）。格子の外は縁を延ばす
  final n = a.cells + 1;
  final sub = Float32List(n * n);
  for (var r = 0; r < n; r++) {
    final sr = (a.row0 + r).clamp(0, a.rows - 1);
    for (var c = 0; c < n; c++) {
      final sc = (a.col0 + c).clamp(0, a.cols - 1);
      sub[r * n + c] = a.heights[sr * a.cols + sc];
    }
  }
  final dem = DemGrid(cols: n, rows: n, originX: 0, originY: 0, cellSize: a.cellSize, heights: sub);
  final byLevel = ContourExtractor.extract(dem, interval: a.interval);
  final image = img.Image(width: a.size, height: a.size, numChannels: 4);
  final scale = a.size / (a.cells * a.cellSize); // m → px
  final extentM = a.cells * a.cellSize;
  final minor = img.ColorRgba8(0x6D, 0x4C, 0x41, 170);
  final major = img.ColorRgba8(0x5D, 0x40, 0x37, 230);
  for (final e in byLevel.entries) {
    final isMajor = ((e.key / a.interval).round() % ContourTiles.majorEvery) == 0;
    for (final seg in e.value) {
      img.drawLine(
        image,
        x1: (seg[0].dx * scale).round(),
        y1: ((extentM - seg[0].dy) * scale).round(),
        x2: (seg[1].dx * scale).round(),
        y2: ((extentM - seg[1].dy) * scale).round(),
        color: isMajor ? major : minor,
        antialias: true,
        thickness: isMajor ? 2 : 1,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image, level: 6));
}
