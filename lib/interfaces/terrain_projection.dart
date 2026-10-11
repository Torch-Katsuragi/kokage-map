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

import 'package:flutter/widgets.dart' show EdgeInsets;
import 'package:latlong2/latlong.dart';

import '../core/terrain/dem_tiles.dart' show TileProgress, TileRange;

/// 3D 地形モード中の投影（地図面の窓口のうち「投影・逆投影」）
///
/// `IMapState.offsetToLatLng` / `latLngToOffset` が 3D 中はこれを通る。
/// ツール（選択・投げ縄・パン）は投影が正しければ描画系を知らずに動く。
abstract class TerrainProjection {
  /// 画面座標 → 視線と地形の交点。地形の外なら null
  LatLng? unproject(Offset screen);

  /// 地図座標 → 画面座標（地形の高さで持ち上げて投影）
  Offset project(LatLng latLng);

  /// カメラを [center]・[zoom] へ動かす（方位・傾きは保つ）。2D の jumpTo と同じ約束
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true});

  /// [coordinates] が画面に収まるように動かす（レイヤのダブルタップなど）。2D の fitCoordinates と同じ約束
  Future<void> fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero});

  /// 外からの指示でカメラを合わせる（`LaunchRequest`）。null の項目は今のまま。
  /// [bearingDeg] は北が 0・時計回り、[pitchDeg] は 0 が真上
  Future<void> lookAt({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate = true});

  /// 地図面の大きさ（論理 px）
  Size get viewportSize;

  /// 窓口「スナップショット」: [range]（タイルの範囲）を真上から見た絵。北が上で、幅は `range.width × 256` px。
  /// 背景地図の層・オーバーレイ画像・地物（面・線・点）を描く。傾き・方位・選択・ラベルは入らない
  /// （ラベルは向きに合わせて呼び出し側が描く）。[strokeScale] は線の太さ・点の大きさの倍率（印刷の解像度に合わせる）
  Future<Image> snapshotTopDown(TileRange range, {double strokeScale = 1, TileProgress? onProgress});
}
