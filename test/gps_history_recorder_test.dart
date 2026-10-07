// GpsHistoryRecorder: 記録 → 反映（consolidate）と、反映前に落ちたときの復元
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/gps_position_record.dart';
import 'package:root_maps/models/gps_track.dart';
import 'package:root_maps/services/gps_history_recorder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}_${d.month.toString().padLeft(2, '0')}_${d.day.toString().padLeft(2, '0')}';

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => tmp = await Directory.systemTemp.createTemp('gps_history_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('反映した点と、反映前に落ちて raw に残った点を両方 details に残す', () async {
    final recorder = GpsHistoryRecorder.forTesting();
    final global = '${tmp.path}/global';
    final support = '${tmp.path}/support';
    await recorder.initialize(global, support);
    expect(recorder.isInitialized, isTrue);

    final start = DateTime.now();
    var n = 0;
    Future<void> send(StreamController<GpsPositionRecord> c) async {
      c.add(GpsPositionRecord(
        latitude: 34.0 + n * 0.0001,
        longitude: 135.0,
        accuracy: 5,
        timestamp: start.add(Duration(seconds: n)),
      ));
      n++;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // 3 点記録して止める（止めると反映される）
    final first = StreamController<GpsPositionRecord>();
    recorder.startRecording(first.stream);
    for (var i = 0; i < 3; i++) {
      await send(first);
    }
    await recorder.stop();
    final key = _dateKey(DateTime.now());
    expect(await recorder.getPointsForDate(key), hasLength(3));
    expect(recorder.lastConsolidatedLine, hasLength(3));

    // さらに 2 点記録したところで落ちる（反映されずに raw バッファに残る）
    final second = StreamController<GpsPositionRecord>();
    recorder.startRecording(second.stream);
    for (var i = 0; i < 2; i++) {
      await send(second);
    }
    // raw への書き込みは非同期。テストを並列で回すと 100ms では終わっていないことがある
    await Future<void>.delayed(const Duration(milliseconds: 500));
    recorder.dispose(); // 反映せずに閉じる

    // 次の起動で raw に残った 2 点を反映する
    final restarted = GpsHistoryRecorder.forTesting();
    await restarted.initialize(global, support);
    final points = await restarted.getPointsForDate(key);
    expect(points, hasLength(5));
    expect(points.map((p) => p.latitude), [for (var i = 0; i < 5; i++) closeTo(34.0 + i * 0.0001, 1e-9)]);
    expect(restarted.lastConsolidatedLine, hasLength(5));
    restarted.dispose();
  });

  test('区間の名前（日付 / 日付 #n）でその区間の点だけを返す（10 分以上空いたら次の区間）', () {
    final t0 = DateTime(2026, 9, 12, 8);
    GpsTrackPoint at(int minutes) =>
        GpsTrackPoint(latitude: 34, longitude: 135, timestamp: t0.add(Duration(minutes: minutes)), sourceType: 'GPS');
    final day = [at(0), at(1), at(2), at(30), at(31), at(60)];
    expect(GpsHistoryRecorder.segmentOf(day, 1).map((p) => p.timestamp.minute), [0, 1, 2]);
    expect(GpsHistoryRecorder.segmentOf(day, 2).map((p) => p.timestamp.minute), [30, 31]);
    expect(GpsHistoryRecorder.segmentOf(day, 3).map((p) => p.timestamp.hour), [9]);
    expect(GpsHistoryRecorder.segmentOf(day, 4), isEmpty);
    expect(GpsHistoryRecorder.segmentOf(const [], 1), isEmpty);
  });
}
