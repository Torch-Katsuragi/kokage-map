// MapSurfaceHandle（MapSurfaceController の実装）の契約テスト
//
// 背景:
//   地図の組み立てより GPS の初回フィックスのほうが先に届くことがある。
//   以前は組み上がる前の move() が黙って捨てられ、呼び出し側は
//   「ジャンプ済み」のフラグだけ立てていたため、**起動時に現在地へ飛ばない**という不具合になっていた。
//   2026-10-04 に MapLibre を外し、保留は地図面（MapSurface）を attach した時点で流す形になった。
//   2026-10-11 に旧 RMapController の jumpOverride / fitOverride を MapSurface の attach に置き換えた。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/core/map_surface_handle.dart';

/// 呼ばれた操作を記録するだけの地図面。投影は 1° = 1000 px の素直な平面
class _FakeSurface implements MapSurface {
  // スナップショット（PDF）はここでは使わない
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final jumps = <({LatLng center, double zoom, bool animate})>[];
  final fits = <({List<LatLng> coords, EdgeInsets padding})>[];
  final looks = <({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate})>[];

  @override
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true}) async =>
      jumps.add((center: center, zoom: zoom, animate: animate));

  @override
  Future<void> fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) async =>
      fits.add((coords: coordinates, padding: padding));

  @override
  Future<void> lookAt({LatLng? center, double? zoom, double? bearingDeg, double? pitchDeg, bool animate = true}) async =>
      looks.add((center: center, zoom: zoom, bearingDeg: bearingDeg, pitchDeg: pitchDeg, animate: animate));

  @override
  Offset project(LatLng p) => Offset(p.longitude * 1000, -p.latitude * 1000);

  @override
  LatLng? unproject(Offset o) => o.dy > 0 ? null : LatLng(-o.dy / 1000, o.dx / 1000);
}

void main() {
  const tokyo = LatLng(35.6812, 139.7671);
  const kitayama = LatLng(33.9707, 135.8534);

  late _FakeSurface surface;
  setUp(() => surface = _FakeSurface());

  group('MapSurfaceHandle のカメラ操作保留', () {
    test('組み上がる前の move() は false を返し、attach した時点で流れる', () {
      final controller = MapSurfaceHandle();
      expect(controller.isAttached, isFalse);
      expect(controller.move(tokyo, 16), isFalse);
      expect(surface.jumps, isEmpty);

      controller.attach(surface);
      expect(controller.isAttached, isTrue);
      expect(surface.jumps, hasLength(1));
      expect(surface.jumps.single.center, tokyo);
      expect(surface.jumps.single.zoom, 16);
      expect(surface.jumps.single.animate, isFalse);
    });

    test('組み上がった後の move() は true を返し、即座に流れる', () {
      final controller = MapSurfaceHandle()..attach(surface);
      expect(controller.move(kitayama, 15), isTrue);
      expect(surface.jumps.single.center, kitayama);
    });

    test('保留は最後の1件だけ実行される（カメラ操作は上書きが正しい）', () {
      final controller = MapSurfaceHandle()
        ..move(tokyo, 16)
        ..move(kitayama, 15);
      controller.attach(surface);
      expect(surface.jumps, hasLength(1));
      expect(surface.jumps.single.center, kitayama);
    });

    test('moveAndRotate() も保留される。方位は覚えるが、地図面へは中心とズームだけ渡す', () {
      final controller = MapSurfaceHandle();
      expect(controller.moveAndRotate(kitayama, 15, 45), isFalse);
      expect(controller.camera.bearing, 45);
      controller.attach(surface);
      expect(surface.jumps.single.center, kitayama);
      expect(surface.jumps.single.zoom, 15);
    });

    test('fitCoordinates() は地図面に流れ、attach 前なら attach の時点で流れる', () {
      final controller = MapSurfaceHandle()..fitCoordinates([tokyo, kitayama]);
      expect(surface.fits, isEmpty);
      controller.attach(surface);
      expect(surface.fits.single.coords, [tokyo, kitayama]);
      expect(surface.jumps, isEmpty);
    });

    test('fitCoordinates() は空なら何もしない', () {
      MapSurfaceHandle()
        ..attach(surface)
        ..fitCoordinates([]);
      expect(surface.fits, isEmpty);
    });

    test('camera は最後に覚えたカメラを返す', () {
      final controller = MapSurfaceHandle()..rememberCamera(kitayama, 14, 30);
      expect(controller.camera.center, kitayama);
      expect(controller.camera.zoom, 14);
      expect(controller.camera.rotation, 30);
      expect(controller.lastCenter, kitayama);
    });

    test('一度も覚えていなければ lastCenter は null、camera は既定の位置', () {
      final controller = MapSurfaceHandle();
      expect(controller.lastCenter, isNull);
      expect(controller.camera.zoom, 16);
    });

    test('dispose すると保留は破棄される', () {
      final controller = MapSurfaceHandle()
        ..move(tokyo, 16)
        ..dispose();
      controller.attach(surface);
      expect(surface.jumps, isEmpty);
    });

    test('外したあとの操作は保留され、付け直した時点で流れる（組み立て直し）', () {
      final controller = MapSurfaceHandle()
        ..attach(surface)
        ..attach(null);
      expect(controller.isAttached, isFalse);
      expect(controller.moveAndRotate(tokyo, 12, 10), isFalse);
      expect(surface.jumps, isEmpty);
      final again = _FakeSurface();
      controller.attach(again);
      expect(again.jumps.single.center, tokyo);
    });

    test('animateTo() は animate つきで流れ、中心が無ければ最後の中心を使う', () async {
      final controller = MapSurfaceHandle()
        ..rememberCamera(tokyo, 12, 0)
        ..attach(surface);
      await controller.animateTo(zoom: 17);
      expect(surface.jumps.single.center, tokyo);
      expect(surface.jumps.single.zoom, 17);
      expect(surface.jumps.single.animate, isTrue);
    });

    test('animateTo() は中心もズームも無ければ何もしない', () async {
      final controller = MapSurfaceHandle()..attach(surface);
      await controller.animateTo(bearing: 90);
      expect(surface.jumps, isEmpty);
    });

    test('jumpTo() は attach 中なら animate を渡して待ち、camera は書き換えない', () async {
      final controller = MapSurfaceHandle()
        ..rememberCamera(tokyo, 12, 0)
        ..attach(surface);
      await controller.jumpTo(kitayama, 15, animate: false);
      expect(surface.jumps.single, (center: kitayama, zoom: 15.0, animate: false));
      expect(controller.camera.center, tokyo);
    });

    test('jumpTo() は attach 前なら保留される', () async {
      final controller = MapSurfaceHandle();
      await controller.jumpTo(kitayama, 15);
      controller.attach(surface);
      expect(surface.jumps.single, (center: kitayama, zoom: 15.0, animate: true));
    });

    test('lookAt() は attach 中だけ流れ、attach 前は保留しない', () async {
      final controller = MapSurfaceHandle();
      await controller.lookAt(center: tokyo, pitchDeg: 30);
      controller.attach(surface);
      expect(surface.looks, isEmpty);
      await controller.lookAt(center: kitayama, zoom: 14, bearingDeg: 90, pitchDeg: 30, animate: false);
      expect(surface.looks.single, (center: kitayama, zoom: 14.0, bearingDeg: 90.0, pitchDeg: 30.0, animate: false));
    });
  });

  group('MapSurfaceHandle の投影', () {
    test('attach 前は投影も逆投影も null', () {
      final controller = MapSurfaceHandle();
      expect(controller.toScreenLocation(tokyo), isNull);
      expect(controller.toLatLng(const Offset(10, -10)), isNull);
    });

    test('attach 中は地図面の投影をそのまま返す（地形に当たらなければ null）', () {
      final controller = MapSurfaceHandle()..attach(surface);
      expect(controller.toScreenLocation(const LatLng(1, 2)), const Offset(2000, -1000));
      expect(controller.toLatLng(const Offset(2000, -1000)), const LatLng(1, 2));
      expect(controller.toLatLng(const Offset(0, 5)), isNull);
    });
  });

  test('EdgeInsets を渡せる', () {
    MapSurfaceHandle()
      ..attach(surface)
      ..fitCoordinates([tokyo], padding: const EdgeInsets.all(8));
    expect(surface.fits.single.padding, const EdgeInsets.all(8));
  });
}
