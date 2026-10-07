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
/// 地図のカメラの窓口
///
/// 地図は 3D（`TerrainMapLayer`）だけになった。MapLibre は 2026-10-04 に外した。
/// ここは最後のカメラを覚えておき、移動は 3D が置く [jumpOverride] / [fitOverride] へ流すだけ。
/// 3D がまだ組み上がっていない間の操作は保留し、差し替え先が置かれた時点で流す。
library;

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

/// カメラ情報（最後に覚えた値）
class KMapCamera {
  final LatLng center;
  final double zoom;
  final double bearing;

  const KMapCamera({required this.center, required this.zoom, required this.bearing});

  /// 旧 flutter_map の名前。bearing と同じ
  double get rotation => bearing;
}

class RMapController {
  /// 差し替え先が置かれる前に呼ばれたカメラ操作の保留分（最後の1件だけ持つ）。
  ///
  /// 地図の組み立てより GPS の初回フィックスのほうが先に届くことがある。
  /// 黙って捨てると「起動時に現在地へ飛ばない」という形で表面化する。
  void Function()? _pendingCameraAction;

  static const _fallbackCenter = LatLng(35.681236, 139.767125);

  LatLng? _lastCenter;
  double _lastZoom = 16;
  double _lastBearing = 0;

  /// 最後に覚えたカメラ（3D を組み立てるときの初期値）
  LatLng? get lastCenter => _lastCenter;

  void rememberCamera(LatLng center, double zoom, double bearing) {
    _lastCenter = center;
    _lastZoom = zoom;
    _lastBearing = bearing;
  }

  KMapCamera get camera => KMapCamera(center: _lastCenter ?? _fallbackCenter, zoom: _lastZoom, bearing: _lastBearing);

  /// 3D のカメラを動かす差し替え先。置いた瞬間に保留分（起動時の現在位置ジャンプなど）を流す
  set jumpOverride(void Function(LatLng center, double zoom, double? bearing, {required bool animate})? f) {
    _jumpOverride = f;
    if (f == null) return;
    final pending = _pendingCameraAction;
    _pendingCameraAction = null;
    pending?.call();
  }

  void Function(LatLng center, double zoom, double? bearing, {required bool animate})? _jumpOverride;

  /// 3D の「ここへ寄せる」
  void Function(List<LatLng> coordinates, EdgeInsets padding)? fitOverride;

  /// カメラ移動。
  ///
  /// Returns: 即座に反映されたら true。差し替え先が無ければ false を返して保留する（呼び出しは失われない）。
  bool move(LatLng center, double zoom) {
    rememberCamera(center, zoom, _lastBearing);
    final override = _jumpOverride;
    if (override == null) {
      _pendingCameraAction = () => move(center, zoom);
      return false;
    }
    override(center, zoom, null, animate: false);
    return true;
  }

  /// カメラ移動 + 回転（[move] と同じく保留あり）
  bool moveAndRotate(LatLng center, double zoom, double rotation) {
    rememberCamera(center, zoom, rotation);
    final override = _jumpOverride;
    if (override == null) {
      _pendingCameraAction = () => moveAndRotate(center, zoom, rotation);
      return false;
    }
    override(center, zoom, rotation, animate: false);
    return true;
  }

  /// アニメーション付きカメラ移動
  Future<void> animateTo({LatLng? center, double? zoom, double? bearing}) async {
    if (center == null && zoom == null) return;
    final override = _jumpOverride;
    if (override == null) {
      _pendingCameraAction = () => animateTo(center: center, zoom: zoom, bearing: bearing);
      return;
    }
    override(center ?? _lastCenter ?? _fallbackCenter, zoom ?? _lastZoom, bearing, animate: true);
  }

  /// 座標リストに合わせてカメラを寄せる
  void fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) {
    if (coordinates.isEmpty) return;
    final override = fitOverride;
    if (override == null) {
      _pendingCameraAction = () => fitCoordinates(coordinates, padding: padding);
      return;
    }
    override(coordinates, padding);
  }

  void dispose() {
    _pendingCameraAction = null;
    _jumpOverride = null;
    fitOverride = null;
  }
}
