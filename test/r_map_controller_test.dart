// RMapController のカメラ操作保留（地図が組み上がる前の呼び出し）のテスト
//
// 背景:
//   地図の組み立てより GPS の初回フィックスのほうが先に届くことがある。
//   以前は組み上がる前の move() が黙って捨てられ、呼び出し側は
//   「ジャンプ済み」のフラグだけ立てていたため、**起動時に現在地へ飛ばない**という不具合になっていた。
//   2026-10-04 に MapLibre を外し、保留は 3D が置く jumpOverride / fitOverride へ流す形になった。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/core/r_map_controller.dart';

void main() {
  const tokyo = LatLng(35.6812, 139.7671);
  const kitayama = LatLng(33.9707, 135.8534);

  late List<({LatLng center, double zoom, double? bearing, bool animate})> jumps;
  void Function(LatLng, double, double?, {required bool animate}) recorder() =>
      (c, z, b, {required animate}) => jumps.add((center: c, zoom: z, bearing: b, animate: animate));

  setUp(() => jumps = []);

  group('RMapController のカメラ操作保留', () {
    test('組み上がる前の move() は false を返し、jumpOverride を置いた時点で流れる', () {
      final controller = RMapController();
      expect(controller.move(tokyo, 16), isFalse);
      expect(jumps, isEmpty);

      controller.jumpOverride = recorder();
      expect(jumps, hasLength(1));
      expect(jumps.single.center, tokyo);
      expect(jumps.single.zoom, 16);
      expect(jumps.single.animate, isFalse);
    });

    test('組み上がった後の move() は true を返し、即座に流れる', () {
      final controller = RMapController()..jumpOverride = recorder();
      expect(controller.move(kitayama, 15), isTrue);
      expect(jumps.single.center, kitayama);
    });

    test('保留は最後の1件だけ実行される（カメラ操作は上書きが正しい）', () {
      final controller = RMapController()
        ..move(tokyo, 16)
        ..move(kitayama, 15);
      controller.jumpOverride = recorder();
      expect(jumps, hasLength(1));
      expect(jumps.single.center, kitayama);
    });

    test('moveAndRotate() も保留され、bearing まで復元される', () {
      final controller = RMapController();
      expect(controller.moveAndRotate(kitayama, 15, 45), isFalse);
      controller.jumpOverride = recorder();
      expect(jumps.single.bearing, 45);
    });

    test('fitCoordinates() は fitOverride に流れ、置く前なら jumpOverride の時点で流れる', () {
      final fits = <List<LatLng>>[];
      final controller = RMapController()..fitCoordinates([tokyo, kitayama]);
      controller.fitOverride = (c, _) {
        fits.add(c);
      };
      controller.jumpOverride = recorder();
      expect(fits.single, [tokyo, kitayama]);
      expect(jumps, isEmpty);
    });

    test('camera は最後に覚えたカメラを返す', () {
      final controller = RMapController()..rememberCamera(kitayama, 14, 30);
      expect(controller.camera.center, kitayama);
      expect(controller.camera.zoom, 14);
      expect(controller.camera.rotation, 30);
      expect(controller.lastCenter, kitayama);
    });

    test('dispose すると保留は破棄される', () {
      final controller = RMapController()
        ..move(tokyo, 16)
        ..dispose();
      controller.jumpOverride = recorder();
      expect(jumps, isEmpty);
    });

    test('animateTo() は animate つきで流れ、中心が無ければ最後の中心を使う', () async {
      final controller = RMapController()
        ..rememberCamera(tokyo, 12, 0)
        ..jumpOverride = recorder();
      await controller.animateTo(zoom: 17);
      expect(jumps.single.center, tokyo);
      expect(jumps.single.zoom, 17);
      expect(jumps.single.animate, isTrue);
    });
  });

  test('EdgeInsets を渡せる（型の確認）', () {
    final controller = RMapController();
    EdgeInsets? got;
    controller.fitOverride = (_, p) {
      got = p;
    };
    controller.fitCoordinates([tokyo], padding: const EdgeInsets.all(8));
    expect(got, const EdgeInsets.all(8));
  });
}
