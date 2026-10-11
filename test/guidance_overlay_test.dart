// 地点への誘導の札: 矢印の基準（端末の向き → 進行方向 → 地図の上）と、やめるボタン
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/providers/guidance_providers.dart';
import 'package:root_maps/screens/map_page/widgets/guidance_overlay.dart';

void main() {
  const here = LatLng(35, 135);
  // 目標は真東（方位 ≒ 90°）
  const east = GuidanceTarget(point: LatLng(35, 135.001), label: '杭 12');

  late ProviderContainer c;
  late ValueNotifier<double?> heading;
  late ValueNotifier<double> mapBearing;

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: GuidanceOverlay(heading: heading, mapBearing: mapBearing)),
        ),
      ));

  /// 矢印の回し（度）
  double arrowDeg(WidgetTester tester) {
    final rot = tester.widget<Transform>(
      find.ancestor(of: find.byIcon(Icons.navigation), matching: find.byType(Transform)).first,
    );
    // Transform.rotate の行列から角度を戻す
    final m = rot.transform.storage;
    return math.atan2(m[1], m[0]) * 180 / math.pi;
  }

  setUp(() {
    c = ProviderContainer();
    heading = ValueNotifier<double?>(null);
    mapBearing = ValueNotifier<double>(0);
    addTearDown(() {
      c.dispose();
      heading.dispose();
      mapBearing.dispose();
    });
  });

  testWidgets('案内していなければ何も出さない', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.navigation), findsNothing);
  });

  testWidgets('端末の向きがあればそれを基準に回す（東を向けば正面、北を向けば右 90°）', (tester) async {
    c.read(guidanceProvider.notifier)
      ..updatePosition(here, accuracy: 3, courseDeg: 180)
      ..start(east);
    heading.value = 90;
    await pump(tester);
    expect(find.text('杭 12'), findsOneWidget);
    expect(arrowDeg(tester), closeTo(0, 0.1));

    heading.value = 0;
    await tester.pump();
    expect(arrowDeg(tester), closeTo(90, 0.1));
  });

  testWidgets('向きが無ければ進行方向、それも無ければ地図の上', (tester) async {
    c.read(guidanceProvider.notifier)
      ..updatePosition(here, accuracy: 3, courseDeg: 180)
      ..start(east);
    await pump(tester);
    expect(arrowDeg(tester), closeTo(-90, 0.1)); // 南へ歩いていれば東は左手

    c.read(guidanceProvider.notifier).updatePosition(here, accuracy: 3);
    mapBearing.value = 45;
    await tester.pump();
    expect(arrowDeg(tester), closeTo(45, 0.1));
  });

  testWidgets('× で案内をやめる', (tester) async {
    c.read(guidanceProvider.notifier)
      ..updatePosition(here)
      ..start(east);
    await pump(tester);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(c.read(guidanceProvider).active, isFalse);
    expect(find.byIcon(Icons.navigation), findsNothing);
  });

  test('距離の表示', () {
    expect(formatDistance(3.456), '3.5 m');
    expect(formatDistance(123.4), '123 m');
    expect(formatDistance(2345), '2.35 km');
  });
}
