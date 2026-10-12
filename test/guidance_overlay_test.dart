// 地点への誘導の札: 矢印の基準（端末の向き → 進行方向 → 地図の上）と、やめるボタン、行き先ごとの標高
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geopackage/vertex_z.dart';
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

  testWidgets('行き先を替えた直後に前の行き先の標高を出さない。引いている間に替えた結果も捨てる', (tester) async {
    // 標高は呼ばれるたびに Completer を積み、テストが順に返す
    final pending = <(List<(double, double)>, Completer<List<double?>>)>[];
    VertexZ.elevationLookup = (points) {
      final done = Completer<List<double?>>();
      pending.add((points, done));
      return done.future;
    };
    addTearDown(() => VertexZ.elevationLookup = null);
    // 標高が返ってから setState → 描き直し まで回す
    Future<void> settle() async {
      await tester.pump();
      await tester.pump();
    }

    const b = GuidanceTarget(point: LatLng(35, 135.002), label: '杭 13');
    const cc = GuidanceTarget(point: LatLng(35, 135.003), label: '杭 14');
    const d = GuidanceTarget(point: LatLng(35, 135.004), label: '杭 15');

    c.read(guidanceProvider.notifier)
      ..updatePosition(here)
      ..start(east);
    await pump(tester);
    expect(pending, hasLength(1));
    pending.removeAt(0).$2.complete([150, 100]); // 目標 150 m・今 100 m
    await settle();
    expect(find.text(t.guidance.elevationUp(m: '50')), findsOneWidget);

    // 行き先を替える: 引けるまでは「不明」（前の 50 m 登りを出さない）
    c.read(guidanceProvider.notifier).start(b);
    await tester.pump();
    expect(find.text(t.guidance.elevationUp(m: '50')), findsNothing);
    expect(find.text(t.guidance.elevationUnknown), findsOneWidget);
    expect(pending.single.$1, [(135.002, 35.0)]);
    pending.removeAt(0).$2.complete([80]);
    await settle();
    expect(find.text(t.guidance.elevationDown(m: '20')), findsOneWidget);

    // 杭 14 を引いている間に杭 15 へ替える: 杭 14 の標高は杭 15 に使わず、杭 15 を引き直す
    c.read(guidanceProvider.notifier).start(cc);
    await tester.pump();
    c.read(guidanceProvider.notifier).start(d);
    await tester.pump();
    pending.removeAt(0).$2.complete([300]);
    await settle();
    expect(find.text(t.guidance.elevationUnknown), findsOneWidget);
    expect(pending.single.$1, [(135.004, 35.0)]);
    pending.removeAt(0).$2.complete([110]);
    await settle();
    expect(find.text(t.guidance.elevationUp(m: '10')), findsOneWidget);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('スマホ幅（412 dp）・文字 ×$scale でも横にはみ出さず、× は 48 dp で押せる', (tester) async {
      tester.view.physicalSize = const Size(412, 923);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      VertexZ.elevationLookup = (points) async => [for (var i = 0; i < points.length; i++) i == 0 ? 100.0 : 419.0];
      addTearDown(() => VertexZ.elevationLookup = null);
      // 実機で出た札: 37.36 km 先の面、GNSS ±12 m、319 m 下り
      c.read(guidanceProvider.notifier)
        ..updatePosition(here, accuracy: 12)
        ..start(const GuidanceTarget(point: LatLng(35.03, 135.41), label: '面'));
      // 地図画面と同じ置き方（左 56・右 64・最大 360）
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: const Size(412, 923), textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Stack(children: [
                Positioned(
                  top: 8,
                  left: 56,
                  right: 64,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: GuidanceOverlay(heading: heading, mapBearing: mapBearing),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text(t.guidance.accuracy(value: '12')), findsOneWidget);
      expect(find.text(t.guidance.elevationDown(m: '319')), findsOneWidget);
      final close = tester.getSize(find.ancestor(of: find.byIcon(Icons.close), matching: find.byType(IconButton)));
      expect(close.width, greaterThanOrEqualTo(48));
      expect(close.height, greaterThanOrEqualTo(48));
    });
  }

  test('距離の表示', () {
    expect(formatDistance(3.456), '3.5 m');
    expect(formatDistance(123.4), '123 m');
    expect(formatDistance(2345), '2.35 km');
  });
}
