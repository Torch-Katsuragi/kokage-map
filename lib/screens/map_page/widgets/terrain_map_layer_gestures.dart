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

/// 地図のジェスチャ（指・マウス・ホイール）→ カメラ。
///
/// 3D: 1 本指 = 回転（左右で方位、上下で傾き）、2 本指 = 平面移動と拡縮と回転（松本の指定・2026-09-08、回転は 2026-09-13）。
/// 2D: 1 本指 = 移動、2 本指 = 移動・拡縮・回転（3D 導入前と同じ。松本 2026-09-13）。
/// マウスは 左ドラッグ = 移動、右ドラッグ or Ctrl + 左 = 回転・傾き、ホイール = 拡縮（MapLibre の慣例。2 本指が無いので）
mixin _TerrainGestures on ConsumerState<TerrainMapLayer> {
  TerrainCamera get _camera;
  TerrainWorld get _world;
  Size get _size;
  bool get _flat;
  bool get _penLock;
  set _gesturing(bool v);
  void _refresh();

  /// 今の 1 本指ドラッグをツールに渡している最中
  bool _toolDrag = false;
  double _scaleStart = 1;
  double _bearingStart = 0;
  double _pitchStart = 0;
  Offset _focalStart = Offset.zero;

  /// 今のポインタがマウスか（web / PC）
  bool _mouse = false;
  Offset? _rightDragLast;

  static const double _maxPitch = _TerrainMapLayerState._maxPitchDeg * math.pi / 180;
  static final double _minScale = TerrainCamera.scaleForZoom(8);
  static final double _maxScale = TerrainCamera.scaleForZoom(22);

  Offset get _screenCenter => Offset(_size.width / 2, _size.height / 2);

  /// 透視のとき、画面座標 [screen] の視線が「カメラ中心の高さの平面」に当たる点（カメラ中心基準）。
  /// 地平線の上や遠すぎる点は靄の先で打ち切るので、空をつまんで動かしても飛ばない
  Offset _groundUnder(Offset screen) {
    final ch = _world.elevationAt(_camera.centerX, _camera.centerY) ?? 0;
    return _camera.groundPointPerspective(screen, ch, ch, maxDistance: _camera.eyeDistance * TerrainCamera.fogEndFactor);
  }

  /// 地面の点。透視なら視線と中心の高さの平面の交点、真上なら画面中心からのずれを地面の m に
  Offset _groundAt(Offset screen) =>
      _camera.perspective ? _groundUnder(screen) : _camera.unprojectPan(screen - _screenCenter);

  /// [change] でカメラを変えても、画面の [screen] の下の地面が動かないように中心をずらす
  void _keepGroundUnder(Offset screen, void Function() change) {
    final before = _groundAt(screen);
    change();
    final after = _groundAt(screen);
    _camera.centerX += before.dx - after.dx;
    _camera.centerY += before.dy - after.dy;
  }

  /// 地面を [from] から [to] へ（画面座標）指に付いて来させる
  void _dragGround(Offset from, Offset to) {
    if (_camera.perspective && _size != Size.zero) {
      final a = _groundUnder(from);
      final b = _groundUnder(to);
      _camera.centerX += a.dx - b.dx;
      _camera.centerY += a.dy - b.dy;
    } else {
      final move = _camera.unprojectPan(to - from);
      _camera.centerX -= move.dx;
      _camera.centerY -= move.dy;
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (_penLock && d.pointerCount == 1) {
      // 真上ロック中の 1 本指は描画（2D と同じ経路。座標は TerrainProjection を通る）
      _toolDrag = true;
      ref.read(currentToolProvider).onScaleStart(d, widget.mapState);
      return;
    }
    _toolDrag = false;
    _scaleStart = _camera.scale;
    _bearingStart = _camera.bearing;
    _pitchStart = _camera.pitch;
    _focalStart = d.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_toolDrag) {
      if (d.pointerCount == 1) ref.read(currentToolProvider).onScaleUpdate(d, widget.mapState);
      return;
    }
    if (d.pointerCount >= 2) {
      final ready = _size != Size.zero;
      final prev = d.localFocalPoint - d.focalPointDelta;
      if (_camera.perspective && ready) {
        // 透視: 指の下の地面（中心の高さの平面）を指に付いて来させる。拡縮も焦点の下を留める
        final from = _groundUnder(prev);
        _camera.scale = (_scaleStart * d.scale).clamp(_minScale, _maxScale);
        final to = _groundUnder(d.localFocalPoint);
        _camera.centerX += from.dx - to.dx;
        _camera.centerY += from.dy - to.dy;
      } else {
        // 真上: 焦点の下を留めて拡縮し、焦点の動きだけ移動
        void zoom() => _camera.scale = (_scaleStart * d.scale).clamp(_minScale, _maxScale);
        ready ? _keepGroundUnder(d.localFocalPoint, zoom) : zoom();
        _dragGround(prev, d.localFocalPoint);
      }
      if (d.rotation.abs() > 1e-6 && ready) {
        // 2 本指の回転（2D / 3D 共通）: 指の下の地面を留めたまま方位を回す（画面の時計回り = 地図も時計回り）
        _keepGroundUnder(d.localFocalPoint, () => _camera.bearing = _bearingStart - d.rotation);
        _gesturing = true;
      }
    } else if (_flat || (_mouse && !HardwareKeyboard.instance.isControlPressed)) {
      // マウスの左ドラッグは移動（回転は右ドラッグか Ctrl + 左）
      _dragGround(d.localFocalPoint - d.focalPointDelta, d.localFocalPoint);
    } else {
      final delta = d.focalPoint - _focalStart;
      _camera.bearing = _bearingStart + delta.dx * 0.006;
      _camera.pitch = (_pitchStart - delta.dy * 0.004).clamp(0.0, _maxPitch);
      _gesturing = true;
    }
    _refresh();
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_toolDrag) {
      _toolDrag = false;
      ref.read(currentToolProvider).onScaleEnd(d, widget.mapState);
      return;
    }
    _gesturing = false;
    _refresh();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _mouse = e.kind == PointerDeviceKind.mouse;
      // 右ボタンのドラッグは ScaleGestureRecognizer が拾わないので生のポインタで回す
      _rightDragLast = _mouse && (e.buttons & kSecondaryButton) != 0 ? e.localPosition : null;
    } else if (e is PointerMoveEvent && _rightDragLast != null) {
      final delta = e.localPosition - _rightDragLast!;
      _rightDragLast = e.localPosition;
      _rotateBy(delta);
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (_rightDragLast != null) {
        _rightDragLast = null;
        _gesturing = false;
        _refresh();
      }
    }
    // ペンロック中の生のポインタ（2D のジェスチャ層と同じく、描画の滑らかさのためにバッファへ）
    if (!_penLock) return;
    final tool = ref.read(currentToolProvider);
    if (e is PointerDownEvent || e is PointerMoveEvent) {
      tool.addPointerToBuffer(e.localPosition);
    } else if (e is PointerUpEvent) {
      tool.clearPointerBuffer();
    }
  }

  /// 画面上の移動量 [delta] を方位・傾きに（1 本指・右ドラッグ・Ctrl + 左ドラッグで共通）。2D では方位だけ
  void _rotateBy(Offset delta) {
    _camera.bearing += delta.dx * 0.006;
    if (!_flat) _camera.pitch = (_camera.pitch - delta.dy * 0.004).clamp(0.0, _maxPitch);
    _gesturing = true;
    _refresh();
  }

  /// ホイール = 拡縮（カーソルの下を留める）
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || _size == Size.zero) return;
    final dz = -e.scrollDelta.dy / 400; // 1 ノッチ ≒ 0.25 段
    _keepGroundUnder(e.localPosition, () => _camera.zoom = (_camera.zoom + dz).clamp(8, 22));
    _refresh();
  }
}
