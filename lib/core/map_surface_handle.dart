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
/// [MapSurfaceController] の実装
///
/// 地図面（[MapSurface]、いまは `TerrainMapLayer`）は組み立て直しで付いたり外れたりするので、
/// アプリ側はこれを持ち続ける。最後のカメラを覚えておき、操作は attach 中の地図面へ流す。
/// 地図面がまだ無い間の操作は保留し、[attach] された時点で流す。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../interfaces/map_surface.dart';

export '../interfaces/map_surface.dart' show KMapCamera, MapSurface, MapSurfaceController;

class MapSurfaceHandle implements MapSurfaceController {
  /// 地図面が置かれる前に呼ばれたカメラ操作の保留分（最後の1件だけ持つ）。
  ///
  /// 地図の組み立てより GPS の初回フィックスのほうが先に届くことがある。
  /// 黙って捨てると「起動時に現在地へ飛ばない」という形で表面化する。
  void Function()? _pendingCameraAction;

  static const _fallbackCenter = LatLng(35.681236, 139.767125);

  MapSurface? _surface;

  LatLng? _lastCenter;
  double _lastZoom = 16;
  double _lastBearing = 0;

  /// 地図面を付ける（null で外す）。付けた瞬間に保留分（起動時の現在位置ジャンプなど）を流す
  void attach(MapSurface? surface) {
    _surface = surface;
    if (surface == null) return;
    final pending = _pendingCameraAction;
    _pendingCameraAction = null;
    pending?.call();
  }

  @override
  bool get isAttached => _surface != null;

  @override
  LatLng? get lastCenter => _lastCenter;

  /// 地図面がカメラの変化を知らせる（組み立て直すときの初期値・ホルダー経由の [camera] になる）
  void rememberCamera(LatLng center, double zoom, double bearing) {
    _lastCenter = center;
    _lastZoom = zoom;
    _lastBearing = bearing;
  }

  @override
  KMapCamera get camera => KMapCamera(center: _lastCenter ?? _fallbackCenter, zoom: _lastZoom, bearing: _lastBearing);

  @override
  Offset? toScreenLocation(LatLng latLng) => _surface?.project(latLng);

  @override
  LatLng? toLatLng(Offset screen) => _surface?.unproject(screen);

  @override
  bool move(LatLng center, double zoom) {
    rememberCamera(center, zoom, _lastBearing);
    final surface = _surface;
    if (surface == null) {
      _pendingCameraAction = () => move(center, zoom);
      return false;
    }
    unawaited(surface.jumpTo(center, zoom, animate: false));
    return true;
  }

  @override
  bool moveAndRotate(LatLng center, double zoom, double rotation) {
    rememberCamera(center, zoom, rotation);
    final surface = _surface;
    if (surface == null) {
      _pendingCameraAction = () => moveAndRotate(center, zoom, rotation);
      return false;
    }
    unawaited(surface.jumpTo(center, zoom, animate: false));
    return true;
  }

  @override
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true}) async {
    final surface = _surface;
    if (surface == null) {
      _pendingCameraAction = () => jumpTo(center, zoom, animate: animate);
      return;
    }
    await surface.jumpTo(center, zoom, animate: animate);
  }

  @override
  Future<void> animateTo({LatLng? center, double? zoom, double? bearing}) async {
    if (center == null && zoom == null) return;
    final surface = _surface;
    if (surface == null) {
      _pendingCameraAction = () => animateTo(center: center, zoom: zoom, bearing: bearing);
      return;
    }
    unawaited(surface.jumpTo(center ?? _lastCenter ?? _fallbackCenter, zoom ?? _lastZoom, animate: true));
  }

  @override
  void fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) {
    if (coordinates.isEmpty) return;
    final surface = _surface;
    if (surface == null) {
      _pendingCameraAction = () => fitCoordinates(coordinates, padding: padding);
      return;
    }
    unawaited(surface.fitCoordinates(coordinates, padding: padding));
  }

  @override
  Future<void> lookAt({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate = true}) async {
    await _surface?.lookAt(center: center, zoom: zoom, bearingDeg: bearingDeg, pitchDeg: pitchDeg, animate: animate);
  }

  void dispose() {
    _pendingCameraAction = null;
    _surface = null;
  }
}
