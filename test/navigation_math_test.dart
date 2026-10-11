// 地点への誘導の計算: 楕円体の距離・方位・相対角・到着・地物の目標点
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/utils/navigation_math.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('距離（Vincenty, WGS84）', () {
    test('赤道上の経度 1° と子午線の緯度 1°', () {
      expect(NavigationMath.distanceMeters(const LatLng(0, 0), const LatLng(0, 1)), closeTo(111319.49, 0.05));
      expect(NavigationMath.distanceMeters(const LatLng(0, 0), const LatLng(1, 0)), closeTo(110574.39, 0.05));
    });

    test('北緯 35° で緯度 0.001°（約 111 m）は丸めずに出る', () {
      final d = NavigationMath.distanceMeters(const LatLng(35, 135), const LatLng(35.001, 135));
      expect(d, closeTo(110.94, 0.02));
    });

    test('同じ点は 0', () {
      expect(NavigationMath.distanceMeters(const LatLng(34, 136), const LatLng(34, 136)), 0);
    });
  });

  group('方位（真北から時計回り 0〜360°）', () {
    const o = LatLng(35, 135);
    test('東西南北', () {
      expect(NavigationMath.bearingDeg(o, const LatLng(35.01, 135)), closeTo(0, 1e-9));
      expect(NavigationMath.bearingDeg(o, const LatLng(35, 135.01)), closeTo(90, 0.01));
      expect(NavigationMath.bearingDeg(o, const LatLng(34.99, 135)), closeTo(180, 1e-9));
      expect(NavigationMath.bearingDeg(o, const LatLng(35, 134.99)), closeTo(270, 0.01));
    });

    test('南西は 180〜270 の間に入る（負にならない）', () {
      final b = NavigationMath.bearingDeg(o, const LatLng(34.99, 134.99));
      expect(b, inExclusiveRange(180, 270));
    });

    test('8 方位', () {
      expect(NavigationMath.octant(0), 0);
      expect(NavigationMath.octant(350), 0);
      expect(NavigationMath.octant(44), 1);
      expect(NavigationMath.octant(90), 2);
      expect(NavigationMath.octant(200), 4);
      expect(NavigationMath.octant(315), 7);
    });
  });

  group('相対角（向いている方位から見た目標。右が正）', () {
    test('向きと同じなら 0、右手なら正、左手なら負', () {
      expect(NavigationMath.relativeDeg(90, 90), 0);
      expect(NavigationMath.relativeDeg(120, 90), 30);
      expect(NavigationMath.relativeDeg(60, 90), -30);
    });

    test('0°/360° をまたぐ', () {
      expect(NavigationMath.relativeDeg(10, 350), closeTo(20, 1e-9));
      expect(NavigationMath.relativeDeg(350, 10), closeTo(-20, 1e-9));
    });

    test('真後ろは 180（-180 ではない）', () {
      expect(NavigationMath.relativeDeg(270, 90), 180);
    });
  });

  group('到着: max(5 m, GPS の精度) 以内', () {
    test('精度が良い（または不明）なら 5 m', () {
      expect(NavigationMath.isArrived(4.9, null), isTrue);
      expect(NavigationMath.isArrived(5.1, null), isFalse);
      expect(NavigationMath.isArrived(4.9, 3), isTrue);
      expect(NavigationMath.isArrived(5.1, 3), isFalse);
    });

    test('精度が悪ければ精度の値まで広げる', () {
      expect(NavigationMath.isArrived(8, 10), isTrue);
      expect(NavigationMath.isArrived(11, 10), isFalse);
    });

    test('着いたあとは半径の 2 倍より離れたら戻す', () {
      expect(NavigationMath.shouldRearm(9, null), isFalse);
      expect(NavigationMath.shouldRearm(11, null), isTrue);
      expect(NavigationMath.shouldRearm(19, 10), isFalse);
      expect(NavigationMath.shouldRearm(21, 10), isTrue);
    });
  });

  group('地物の目標点', () {
    test('線上のいちばん近い所（端で止まる）', () {
      const line = [LatLng(35, 135), LatLng(35, 135.01)];
      final p = NavigationMath.nearestPointOnLine(const LatLng(35.0005, 135.005), line)!;
      expect(p.latitude, closeTo(35, 1e-7));
      expect(p.longitude, closeTo(135.005, 1e-7));
      final end = NavigationMath.nearestPointOnLine(const LatLng(35, 135.02), line)!;
      expect(end.longitude, closeTo(135.01, 1e-7));
    });

    test('いちばん近い頂点', () {
      const pts = [LatLng(35, 135), LatLng(35.001, 135), LatLng(35.001, 135.001)];
      expect(NavigationMath.nearestVertex(const LatLng(35.0011, 135.0002), pts), const LatLng(35.001, 135));
      expect(NavigationMath.nearestVertex(const LatLng(35, 135), const []), isNull);
    });

    test('面の重心は面積で重み付け（辺の途中の頂点に引っ張られない）', () {
      // 正方形の下の辺の途中に頂点が 1 つ多い。頂点の平均なら南へずれる
      const ring = [
        LatLng(35, 135),
        LatLng(35, 135.0005),
        LatLng(35, 135.001),
        LatLng(35.001, 135.001),
        LatLng(35.001, 135),
        LatLng(35, 135),
      ];
      final c = NavigationMath.polygonCentroid(ring)!;
      expect(c.latitude, closeTo(35.0005, 1e-7));
      expect(c.longitude, closeTo(135.0005, 1e-7));
    });

    test('面積の無い面は頂点の平均', () {
      final c = NavigationMath.polygonCentroid(const [LatLng(35, 135), LatLng(35, 135.002)])!;
      expect(c.longitude, closeTo(135.001, 1e-7));
    });
  });
}
