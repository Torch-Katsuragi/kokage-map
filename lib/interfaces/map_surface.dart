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
/// 地図面の窓口（seam ①: カメラ＋投影）。設計は `docs/technical/scene-model.md`
///
/// - [MapSurface]: 描画系（`TerrainMapLayer`）が実装する口。組み上がったら attach、外れたら detach される
/// - [MapSurfaceController]: アプリ側（ツール・地図ページの mixin・ホルダー経由の画面）が使う口。
///   地図面が組み上がる前の操作を保留し、最後のカメラを覚えておく（実装は `MapSurfaceHandle`）
///
/// 当たり判定は地図面の外（ツールが [MapSurfaceController.toScreenLocation] / [MapSurfaceController.toLatLng] と
/// フィーチャの座標で Dart 側で計算する）。スナップショットはまだ使い道が無いので口を持たない。
library;

import 'dart:ui';

import 'package:flutter/widgets.dart' show EdgeInsets;
import 'package:latlong2/latlong.dart';

/// カメラ情報（最後に覚えた値）
class KMapCamera {
  final LatLng center;
  final double zoom;

  /// 北が 0・時計回りの度
  final double bearing;

  const KMapCamera({required this.center, required this.zoom, required this.bearing});

  /// 旧 flutter_map の名前。bearing と同じ
  double get rotation => bearing;
}

/// 描画系が実装する地図面（投影・逆投影とカメラの移動）
///
/// `IMapState.offsetToLatLng` / `latLngToOffset` は attach 中はこれを通る。
/// ツール（選択・投げ縄・パン）は投影が正しければ描画系を知らずに動く。
abstract interface class MapSurface {
  /// 画面座標 → 視線と地形の交点。地形の外なら null
  LatLng? unproject(Offset screen);

  /// 地図座標 → 画面座標（地形の高さで持ち上げて投影）
  Offset project(LatLng latLng);

  /// カメラを [center]・[zoom] へ動かす（方位・傾きは保つ）
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true});

  /// [coordinates] が画面に収まるように動かす（レイヤのダブルタップなど）
  Future<void> fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero});

  /// 外からの指示でカメラを合わせる（`LaunchRequest`）。null の項目は今のまま。
  /// [bearingDeg] は北が 0・時計回り、[pitchDeg] は 0 が真上
  Future<void> lookAt({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate = true});
}

/// アプリ側が使う地図面の窓口（カメラの読み書きと投影・逆投影）
///
/// 地図面がまだ組み上がっていない（[isAttached] が false）間:
/// - カメラ操作は最後の 1 件だけ保留し、組み上がった時点で流す（[lookAt] だけは保留しない）
/// - 投影は null を返す
abstract interface class MapSurfaceController {
  /// 地図面が組み上がっているか
  bool get isAttached;

  /// 最後に覚えたカメラ（地図面がまだ無ければ既定の位置）
  KMapCamera get camera;

  /// 最後に覚えたカメラの中心。一度も覚えていなければ null
  LatLng? get lastCenter;

  /// 地図座標 → 画面座標。地図面がまだ無ければ null
  Offset? toScreenLocation(LatLng latLng);

  /// 画面座標 → 地図座標。地図面がまだ無い・地形に当たらない（空・地図の外）なら null
  LatLng? toLatLng(Offset screen);

  /// カメラ移動。即座に反映されたら true。地図面が無ければ false を返して保留する（呼び出しは失われない）
  bool move(LatLng center, double zoom);

  /// カメラ移動 + 回転（[move] と同じく保留あり）。⚠ 地図面へは方位を渡さない（覚えるだけ）
  bool moveAndRotate(LatLng center, double zoom, double rotation);

  /// 地図面のカメラを動かして待つ。地図面が無ければ保留して、すぐ返る（[camera] は書き換えない）
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true});

  /// アニメーション付きカメラ移動（中心もズームも無ければ何もしない）
  Future<void> animateTo({LatLng? center, double? zoom, double? bearing});

  /// 座標リストに合わせてカメラを寄せる
  void fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero});

  /// 外からの指示でカメラを合わせる。地図面が無ければ何もしない（保留は呼び出し側が持つ）
  Future<void> lookAt({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate = true});
}
