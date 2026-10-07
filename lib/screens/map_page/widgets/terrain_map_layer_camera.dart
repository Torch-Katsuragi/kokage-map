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
part of 'terrain_map_layer.dart';

typedef _CameraPose = ({double bearing, double pitch, double centerX, double centerY, double zoom});

/// カメラの動かし方: 滑らかに動かすアニメ、コンパスの 2D / 3D・北・眺めモード、ズームボタン、
/// 外から呼ばれる [TerrainProjection]（投影と、jumpTo・lookAt・fitCoordinates）
mixin _TerrainCameraControl on ConsumerState<TerrainMapLayer> implements TerrainProjection {
  TerrainCamera get _camera;
  TerrainWorld get _world;
  TerrainWorldPainter get _painter;
  TerrainGpuWorldRenderer? get _gpu;
  Size get _size;
  bool get _flat;
  set _flat(bool v);
  bool get _penLock;
  set _pitchBeforePen(double? v);
  set _gesturing(bool v);
  void _refresh();

  /// 3D に戻したときの傾き（2D に入る前のもの。無ければ [_default3dPitchDeg]）
  double? _pitchBefore2d;
  static const _default3dPitchDeg = 50.0;

  // カメラのアニメ（コンパスタップ・ペンの真上ロック）。作るのは initState（vsync が State 側にある）
  late final AnimationController _anim;
  _CameraPose? _animFrom;
  _CameraPose? _animTo;

  /// 指定した項目だけ 350ms で滑らかに動かす（方位は近い方へ回る）。動き終わるまで待てる
  TickerFuture _animateTo({double? bearing, double? pitch, double? centerX, double? centerY, double? zoom}) {
    var b = bearing ?? _camera.bearing;
    // 近い方へ回る
    var d = b - _camera.bearing;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    b = _camera.bearing + d;
    _animFrom = (bearing: _camera.bearing, pitch: _camera.pitch, centerX: _camera.centerX, centerY: _camera.centerY, zoom: _camera.zoom);
    _animTo = (bearing: b, pitch: pitch ?? _camera.pitch, centerX: centerX ?? _camera.centerX, centerY: centerY ?? _camera.centerY, zoom: zoom ?? _camera.zoom);
    return _anim.forward(from: 0);
  }

  void _onAnimTick() {
    final a = _animFrom;
    final z = _animTo;
    if (a == null || z == null) return;
    final t = Curves.easeInOutCubic.transform(_anim.value);
    double lerp(double x, double y) => x + (y - x) * t;
    _camera
      ..bearing = lerp(a.bearing, z.bearing)
      ..pitch = lerp(a.pitch, z.pitch)
      ..centerX = lerp(a.centerX, z.centerX)
      ..centerY = lerp(a.centerY, z.centerY)
      ..zoom = lerp(a.zoom, z.zoom);
    _gesturing = _anim.isAnimating;
    _refresh();
  }

  /// コンパスのタップ: 2D ⇄ 3D。2D は真上に固定（眺めモードも解く）。3D は 2D に入る前の傾きに戻す
  void _toggleMode() {
    if (ref.read(currentToolProvider).name == 'Edit') return; // 編集中は 2D のまま
    if (_flat) {
      _flat = false;
      final p = _pitchBefore2d ?? _default3dPitchDeg * math.pi / 180;
      if (_penLock) {
        _pitchBeforePen = p; // ペンを離したときにこの傾きへ
      } else {
        _animateTo(pitch: p);
      }
    } else {
      _enterFlat();
      _animateTo(pitch: 0);
    }
    ref.read(mapFlashProvider.notifier).show(_flat ? t.map.flash.mode2d : t.map.flash.mode3d);
    ref.read(tutorialProvider.notifier).report(const MapModeToggled());
    setState(() {});
  }

  /// 2D に入る（真上に固定し眺めモードも解く。傾きは 3D に戻すときのために覚える）。カメラを寝かせるのは呼び出し側
  void _enterFlat() {
    _flat = true;
    _pitchBefore2d = _camera.pitch > 0.02 ? _camera.pitch : null;
    _camera.perspective = false;
    _pitchBeforePen = 0;
  }

  /// 2D・北が上に（知らせもフラッシュも出さない。チュートリアルの章の始め）
  void _resetToFlatNorth() {
    if (!_flat) _enterFlat();
    if (_camera.pitch == 0 && _camera.bearing == 0) {
      setState(() {});
      return;
    }
    _animateTo(pitch: 0, bearing: 0);
    setState(() {});
  }

  /// コンパスのダブルタップ: 北を上に（モードはそのまま）
  void _resetNorth() {
    _animateTo(bearing: 0);
    ref.read(mapFlashProvider.notifier).show(t.map.flash.northUp);
  }

  /// 眺めモード（透視投影）の切替。コンパスの長押し（3D のときだけ）。GPU 経路のみ（純 Dart は正射影の線形性に頼る）
  void _togglePerspective() {
    if (_gpu == null || _flat) return;
    setState(() => _camera.perspective = !_camera.perspective);
    ref.read(mapFlashProvider.notifier).show(_camera.perspective ? t.map.flash.perspectiveOn : t.map.flash.perspectiveOff);
    _refresh();
  }

  // ── TerrainProjection ───────────────────────────────

  @override
  LatLng? unproject(Offset screen) {
    if (_size == Size.zero) return null;
    final p = _painter.unproject(screen, _size);
    if (p == null) return null;
    return LatLng(WebMercator.latFromY(p.dy), WebMercator.lonFromX(p.dx));
  }

  @override
  Offset project(LatLng latLng) {
    final x = WebMercator.xFromLon(latLng.longitude);
    final y = WebMercator.yFromLat(latLng.latitude);
    return _painter.toScreen(x, y, _world.elevationAt(x, y) ?? 0, _size);
  }

  @override
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true}) async {
    final x = WebMercator.xFromLon(center.longitude);
    final y = WebMercator.yFromLat(center.latitude);
    if (!animate) {
      _camera
        ..centerX = x
        ..centerY = y
        ..zoom = zoom;
      _refresh();
      return;
    }
    await _animateTo(centerX: x, centerY: y, zoom: zoom);
  }

  @override
  Future<void> lookAt({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate = true}) async {
    final x = center == null ? null : WebMercator.xFromLon(center.longitude);
    final y = center == null ? null : WebMercator.yFromLat(center.latitude);
    final b = bearingDeg == null ? null : bearingDeg * math.pi / 180;
    final p = pitchDeg == null ? null : (pitchDeg.clamp(0.0, _TerrainMapLayerState._maxPitchDeg)) * math.pi / 180;
    if (p != null && p > 0.02 && _flat) _flat = false; // 傾きを頼まれたら 3D（CLI / URL の pitch）
    if (p != null && _flat) return lookAt(center: center, zoom: zoom, bearingDeg: bearingDeg, animate: animate);
    if (!animate) {
      if (x != null) _camera.centerX = x;
      if (y != null) _camera.centerY = y;
      if (zoom != null) _camera.zoom = zoom;
      if (b != null) _camera.bearing = b;
      if (p != null) _camera.pitch = p;
      _refresh();
      return;
    }
    await _animateTo(centerX: x, centerY: y, zoom: zoom, bearing: b, pitch: p);
  }

  @override
  Future<void> fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) async {
    if (coordinates.isEmpty) return;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final c in coordinates) {
      final x = WebMercator.xFromLon(c.longitude);
      final y = WebMercator.yFromLat(c.latitude);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    final center = LatLng(WebMercator.latFromY((minY + maxY) / 2), WebMercator.lonFromX((minX + maxX) / 2));
    if (_size == Size.zero) return jumpTo(center, _camera.zoom);
    // 1 点なら寄るだけ。幅は真上から見た Mercator m（傾いていると画面の地面は広いので余裕がある）
    final spanX = math.max(maxX - minX, 20.0);
    final spanY = math.max(maxY - minY, 20.0);
    final w = math.max(_size.width - padding.horizontal, 50.0);
    final h = math.max(_size.height - padding.vertical, 50.0);
    final scale = math.min(w / spanX, h / spanY); // px / m
    final zoom = (math.log(scale * 2 * math.pi * WebMercator.radius / 256) / math.ln2).clamp(2.0, 18.0);
    return jumpTo(center, zoom);
  }

  /// ズームボタン（web / PC 向け。画面中心を留めて 1 段）
  void _zoomBy(double delta) {
    _camera.zoom = (_camera.zoom + delta).clamp(8, 22);
    _refresh();
    setState(() {});
  }
}
