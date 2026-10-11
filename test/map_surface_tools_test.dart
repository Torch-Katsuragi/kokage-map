// ツールは地図面を MapSurfaceController 越しにしか触らない（2026-10-11）
//
// 描画系の代わりに平面の Web Mercator で投影する偽の地図面を attach し、
// てのひらツールのホイール拡縮・中ボタンのドラッグが「指の下の地点を留める」約束を守るかを見る。
// 地図ページの IMapState と同じく、投影 3 つは mapController を通す
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/core/map_surface_handle.dart';
import 'package:root_maps/interfaces/map_state_interface.dart';
import 'package:root_maps/providers/tool_providers.dart';

const _size = Size(800, 600);

/// 真上・北が上の Web Mercator。カメラは [handle] が覚えている値を読む（本物の地図面も動くたびに覚えさせる）
class _FlatSurface implements MapSurface {
  // スナップショット（PDF）はここでは使わない
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  _FlatSurface(this.handle);
  final MapSurfaceHandle handle;
  final jumps = <({LatLng center, double zoom, bool animate})>[];

  static Offset _merc(LatLng p, double world) {
    final lat = p.latitude * math.pi / 180;
    return Offset((p.longitude + 180) / 360 * world, (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * world);
  }

  double get _world => 256 * math.pow(2, handle.camera.zoom).toDouble();

  @override
  Offset project(LatLng latLng) {
    final c = _merc(handle.camera.center, _world);
    return _merc(latLng, _world) - c + _size.center(Offset.zero);
  }

  @override
  LatLng? unproject(Offset screen) {
    final m = _merc(handle.camera.center, _world) + (screen - _size.center(Offset.zero));
    final lon = m.dx / _world * 360 - 180;
    final n = math.pi - 2 * math.pi * m.dy / _world;
    return LatLng(180 / math.pi * math.atan((math.exp(n) - math.exp(-n)) / 2), lon);
  }

  @override
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true}) async =>
      jumps.add((center: center, zoom: zoom, animate: animate));

  @override
  Future<void> fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) async {}

  @override
  Future<void> lookAt({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate = true}) async {}
}

/// 地図ページの IMapState と同じ配線（投影は mapController を通し、地図面が無ければ中心で代える）
class _FakeMap implements IMapState {
  _FakeMap(this.mapController);

  @override
  final MapSurfaceHandle mapController;

  @override
  LatLng offsetToLatLng(Offset offset) => mapController.toLatLng(offset) ?? mapController.camera.center;

  @override
  LatLng? tryOffsetToLatLng(Offset offset) => mapController.toLatLng(offset);

  @override
  Offset latLngToOffset(LatLng latlng) => mapController.toScreenLocation(latlng) ?? _size.center(Offset.zero);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  const kitayama = LatLng(33.9707, 135.8534);

  late ProviderContainer container;
  late MapSurfaceHandle handle;
  late _FlatSurface surface;
  late _FakeMap map;

  setUp(() {
    container = ProviderContainer();
    handle = MapSurfaceHandle()..rememberCamera(kitayama, 15, 0);
    surface = _FlatSurface(handle);
    handle.attach(surface);
    map = _FakeMap(handle);
  });
  tearDown(() => container.dispose());

  test('ホイールで寄るとズームが上がり、カーソルの下の地点はカーソルの下に留まる', () {
    const cursor = Offset(600, 150);
    final under = map.offsetToLatLng(cursor);
    container.read(panToolProvider).onPointerSignal(
          const PointerScrollEvent(position: cursor, scrollDelta: Offset(0, -100)),
          map,
        );
    expect(surface.jumps, hasLength(1));
    expect(surface.jumps.single.animate, isFalse);
    expect(handle.camera.zoom, closeTo(16, 1e-9));
    final after = map.latLngToOffset(under);
    expect(after.dx, closeTo(cursor.dx, 0.5));
    expect(after.dy, closeTo(cursor.dy, 0.5));
  });

  test('中ボタンのドラッグは地図を指と同じだけ動かす（ズームは変えない）', () {
    final pan = container.read(panToolProvider);
    final grabbed = map.offsetToLatLng(const Offset(400, 300));
    pan.onMiddleButtonDown(const PointerDownEvent(position: Offset(400, 300), buttons: kMiddleMouseButton), map);
    pan.onMiddleButtonMove(const PointerMoveEvent(position: Offset(500, 340), buttons: kMiddleMouseButton), map);
    pan.onMiddleButtonUp(const PointerUpEvent(position: Offset(500, 340)), map);
    expect(surface.jumps, hasLength(1));
    expect(handle.camera.zoom, 15);
    final after = map.latLngToOffset(grabbed);
    expect(after.dx, closeTo(500, 0.5));
    expect(after.dy, closeTo(340, 0.5));
  });

  test('地図面が外れている間の操作は保留され、付け直すと最後の 1 件が流れる', () {
    handle.attach(null);
    final pan = container.read(panToolProvider);
    pan.onMiddleButtonDown(const PointerDownEvent(position: Offset(400, 300), buttons: kMiddleMouseButton), map);
    pan.onMiddleButtonMove(const PointerMoveEvent(position: Offset(420, 300), buttons: kMiddleMouseButton), map);
    expect(surface.jumps, isEmpty);
    handle.attach(surface);
    expect(surface.jumps, hasLength(1));
  });
}
