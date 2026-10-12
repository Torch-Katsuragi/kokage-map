// 軌跡の抽出: 日付を替えたとき、前の日の点の読み込みが後から終わっても今の日の点のまま
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/gps_track.dart';
import 'package:root_maps/services/gps_history_recorder.dart';
import 'package:root_maps/widgets/track_extraction_dialog.dart';

class _FakeRecorder extends Fake implements GpsHistoryRecorder {
  final pending = <String, Completer<List<GpsTrackPoint>>>{};

  @override
  Future<List<String>> getAvailableDates() async => ['2026_10_01', '2026_10_02'];

  @override
  Future<List<GpsTrackPoint>> getPointsForDate(String name) => (pending[name] = Completer()).future;
}

List<GpsTrackPoint> _points(int n) => [
      for (var i = 0; i < n; i++)
        GpsTrackPoint(
          latitude: 35,
          longitude: 135 + i * 0.001,
          timestamp: DateTime(2026, 10, 1, 9, i),
          sourceType: 'GPS',
        ),
    ];

/// 進捗の輪が回り続けるので pumpAndSettle は使わない（メニューの開閉が済むまで進める）
Future<void> step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('日付を替えたあとに前の日の読み込みが終わっても、今の日の点のまま', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recorder = _FakeRecorder();
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: TrackExtractionDialog(recorder: recorder)),
      ),
    ));
    await tester.pump();
    expect(recorder.pending.keys, ['2026_10_01']);

    // 10/01 を読んでいる間に 10/02 へ替える
    await tester.tap(find.byType(DropdownButton<String>));
    await step(tester);
    await tester.tap(find.text('2026/10/02').last);
    await step(tester);
    expect(recorder.pending.keys, ['2026_10_01', '2026_10_02']);

    recorder.pending['2026_10_02']!.complete(_points(5));
    await step(tester);
    expect(find.text(t.track.pointsCount(count: '5')), findsOneWidget);

    // 前の日（3 点）の読み込みが後から終わる
    recorder.pending['2026_10_01']!.complete(_points(3));
    await step(tester);
    expect(find.text(t.track.pointsCount(count: '5')), findsOneWidget);
    expect(find.text(t.track.pointsCount(count: '3')), findsNothing);
  });
}
