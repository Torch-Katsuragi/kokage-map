// 簡略化のスライダー: 長い線を裏で簡略化している間に線が替わったら、前の線の結果を使わない
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/widgets/feature_editor/shared/simplification_controls.dart';

void main() {
  testWidgets('裏で簡略化している間に線が替わったら、前の線の結果で上書きしない', (tester) async {
    // 前の線: 裏（Isolate）で簡略化する長さ。ほぼ真っすぐなので両端の 2 点になる
    final long = [for (var i = 0; i < 600; i++) LatLng(35, 135 + i * 0.0001)];
    // 今の線: その場で簡略化する短い線（折れ曲がりがあるので 3 点残る）
    const short = [LatLng(35, 135), LatLng(35.01, 135.01), LatLng(35, 135.02)];
    final results = <List<LatLng>>[];

    Widget host(List<LatLng> line) => MaterialApp(
          home: Scaffold(
            body: SimplificationControls(originalLine: line, initialTolerance: 5, onChanged: results.add),
          ),
        );

    await tester.pumpWidget(host(long));
    await tester.pump(); // 初回の簡略化（裏で始まる）
    await tester.pumpWidget(host(short));
    await tester.pump(); // 線が替わった → その場で簡略化
    expect(results.last, short);

    // 前の線の裏の簡略化が後から届いても、今の線の結果のまま
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await tester.pump();
    expect(results.last, short);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
