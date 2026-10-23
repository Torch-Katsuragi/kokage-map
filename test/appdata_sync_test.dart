// AppData/kmap 端末間データ統合のユニットテスト:
// 1. GpsHistoryRecorder.mergePastDaysWith（前日以前のみ統合・当日除外・2台同日記録の非混線・べき等性）
// 2. AppDataSyncService.mergeSettings3Way（設定の3-wayマージ・初回参加時のリモート優先）
// 3. AppDataSyncService.mergeSharedFolders3Way（共有フォルダURLリストの3-wayマージ・削除維持・同名衝突時のピンポン防止）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/google_drive/appdata_sync_service.dart';
import 'package:root_maps/services/gps_history_recorder.dart';
import 'package:root_maps/services/shared_map_link.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _insertDayTrack(
  String gpkgPath, {
  required String deviceId,
  required String dateKey,
  required List<LatLng> points,
  DateTime? baseTime,
}) async {
  final file = GeoPackageFile([p.basename(gpkgPath)], absolutePath: gpkgPath);
  try {
    final fid = await file.addLine('gps_tracks', points, name: dateKey);
    final db = await file.getDatabase();
    if (fid != null) {
      await db.update(
        'gps_tracks',
        {'device_id': deviceId},
        where: 'fid = ?',
        whereArgs: [fid],
      );
    }
    final t0 = baseTime ?? DateTime(2026, 9, 12, 9, 0);
    await db.transaction((txn) async {
      for (var i = 0; i < points.length; i++) {
        await txn.insert('gps_track_details', {
          'track_date': dateKey,
          'point_index': i,
          'timestamp': t0.add(Duration(seconds: i * 10)).toIso8601String(),
          'latitude': points[i].latitude,
          'longitude': points[i].longitude,
          'altitude': 100.0,
          'accuracy': 5.0,
          'speed': 1.0,
          'bearing': 0.0,
          'source_type': 'GPS',
          'device_id': deviceId,
        });
      }
    });
  } finally {
    await file.dispose();
  }
}

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async => tmp = await Directory.systemTemp.createTemp('appdata_sync_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('GPS前日以前統合: 過去日だけ双方向統合し、当日分は触れず、同日2台でもジグザグ混線しない', () async {
    final globalA = p.join(tmp.path, 'devA_global');
    final supportA = p.join(tmp.path, 'devA_support');
    final globalB = p.join(tmp.path, 'devB_global');
    final supportB = p.join(tmp.path, 'devB_support');
    final remoteGpkgPath = p.join(tmp.path, 'remote_gps_history.gpkg');

    final recA = GpsHistoryRecorder.forTesting();
    final recB = GpsHistoryRecorder.forTesting();
    await recA.initialize(globalA, supportA, deviceIdOverride: 'devA1111');
    await recB.initialize(globalB, supportB, deviceIdOverride: 'devB2222');

    final todayKey = GpsHistoryRecorder.dateKey(DateTime.now());
    const pastSharedDay = '2026_09_10';
    const pastOnlyADay = '2026_09_08';

    // 端末A: 2026_09_08 (Aのみ), 2026_09_10 (AとB同日), 今日 (統合対象外)
    final gpkgA = p.join(globalA, 'gps_history.gpkg');
    await _insertDayTrack(
      gpkgA,
      deviceId: 'devA1111',
      dateKey: pastOnlyADay,
      points: const [LatLng(33.90, 135.90), LatLng(33.91, 135.91)],
    );
    await _insertDayTrack(
      gpkgA,
      deviceId: 'devA1111',
      dateKey: pastSharedDay,
      points: const [LatLng(34.00, 135.00), LatLng(34.01, 135.01), LatLng(34.02, 135.02)],
    );
    await _insertDayTrack(
      gpkgA,
      deviceId: 'devA1111',
      dateKey: todayKey,
      points: const [LatLng(35.00, 136.00), LatLng(35.01, 136.01)],
    );

    // 端末B: 2026_09_10 (Aと同日・同時刻に別ルートを記録)
    final gpkgB = p.join(globalB, 'gps_history.gpkg');
    await _insertDayTrack(
      gpkgB,
      deviceId: 'devB2222',
      dateKey: pastSharedDay,
      points: const [LatLng(36.00, 137.00), LatLng(36.50, 137.50)],
    );

    // 1. 端末Aが初回同期（過去日2日分をリモートへ書き出し、今日分は書き出さない）
    final resA1 = await recA.mergePastDaysWith(remoteGpkgPath);
    expect(resA1.changedRemote, isTrue);
    expect(resA1.exportedDays, 2);
    expect(resA1.importedDays, 0);

    // 2. 端末Bが同期（Aの過去日2日分を取り込み、Bの 2026_09_10 をリモートへ書き出す）
    final resB1 = await recB.mergePastDaysWith(remoteGpkgPath);
    expect(resB1.changedLocal, isTrue);
    expect(resB1.changedRemote, isTrue);
    expect(resB1.importedDays, 2);
    expect(resB1.exportedDays, 1);

    // 3. 端末Aが再同期（Bの 2026_09_10 を取り込む）
    final resA2 = await recA.mergePastDaysWith(remoteGpkgPath);
    expect(resA2.changedLocal, isTrue);
    expect(resA2.changedRemote, isFalse);
    expect(resA2.importedDays, 1);

    // 4. べき等性確認: もう一度同期しても何も変わらない
    final resA3 = await recA.mergePastDaysWith(remoteGpkgPath);
    expect(resA3.changedLocal, isFalse);
    expect(resA3.changedRemote, isFalse);

    // 5. 端末Bには端末Aの「今日分」が入っていないことを確認
    final datesB = await recB.getAvailableDates();
    expect(datesB, isNot(contains(todayKey)));
    expect(datesB, contains(pastOnlyADay));

    // 6. 2026_09_10 は端末A上で自端末分（3点）と端末B分（2点）が別々に取得でき、混線しない
    final datesA = await recA.getAvailableDates();
    expect(datesA, contains(pastSharedDay));
    expect(datesA, contains('$pastSharedDay [devB]'));

    final ptsSelf = await recA.getPointsForDate(pastSharedDay);
    expect(ptsSelf.map((p) => p.latitude), [34.00, 34.01, 34.02]);

    final ptsOther = await recA.getPointsForDate('$pastSharedDay [devB]');
    expect(ptsOther.map((p) => p.latitude), [36.00, 36.50]);

    recA.dispose();
    recB.dispose();
  });

  test('設定3-wayマージ: ローカル変更の送信とリモート変更の適用、および初回参加時のリモート優先', () {
    final base = <String, Object?>{
      'track_recording_settings': '{"intervalSeconds":1}',
      'basemap_provider_id': 'gsi_std',
    };
    final local = <String, Object?>{
      'track_recording_settings': '{"intervalSeconds":5}', // ローカルで変更
      'basemap_provider_id': 'gsi_std',
    };
    final remote = <String, Object?>{
      'track_recording_settings': '{"intervalSeconds":1}',
      'basemap_provider_id': 'gsi_photo', // 他端末で変更
    };

    final res = AppDataSyncService.mergeSettings3Way(
      local: local,
      base: base,
      remote: remote,
    );

    expect(res.shouldUpload, isTrue);
    expect(res.merged['track_recording_settings'], '{"intervalSeconds":5}');
    expect(res.merged['basemap_provider_id'], 'gsi_photo');
    expect(res.toApplyLocally, {'basemap_provider_id': 'gsi_photo'});

    // 初回参加（base が空）のときは既存リモート値を優先して取り込み、上書きしない
    final initRes = AppDataSyncService.mergeSettings3Way(
      local: {'basemap_provider_id': 'gsi_std'},
      base: const {},
      remote: {'basemap_provider_id': 'gsi_photo'},
    );
    expect(initRes.shouldUpload, isFalse);
    expect(initRes.toApplyLocally, {'basemap_provider_id': 'gsi_photo'});
  });

  test('共有フォルダURLリスト3-wayマージ: 新規追加のクローンとローカル削除の伝播、クローン失敗時の非削除', () {
    const entryA = SharedMapEntry(
      driveId: 'idA',
      folderName: '林班A',
      driveUrl: 'https://drive.google.com/drive/folders/idA',
      isReadOnly: false,
    );
    const entryB = SharedMapEntry(
      driveId: 'idB',
      folderName: '林班B',
      driveUrl: 'https://drive.google.com/drive/folders/idB',
      isReadOnly: true,
    );
    const entryC = SharedMapEntry(
      driveId: 'idC',
      folderName: '林班C',
      driveUrl: 'https://drive.google.com/drive/folders/idC',
      isReadOnly: false,
    );

    // 前回同期時に idA, idB があった状態から:
    // - この端末で idA を削除
    // - 他端末で idC が追加された
    final res = AppDataSyncService.mergeSharedFolders3Way(
      local: {'idB': entryB},
      baseIds: {'idA', 'idB'},
      remote: {'idA': entryA, 'idB': entryB, 'idC': entryC},
    );

    expect(res.shouldUpload, isTrue);
    expect(res.merged.keys, unorderedEquals(['idB', 'idC']));
    expect(res.toClone.map((e) => e.driveId), ['idC']);

    // idC のクローンが失敗し updatedLocal が {'idB'} のままだった場合、
    // 次回同期（baseIds = {'idB'}）で idC が誤って削除されず再度 toClone に入ることを確認
    final retryRes = AppDataSyncService.mergeSharedFolders3Way(
      local: {'idB': entryB},
      baseIds: {'idB'},
      remote: {'idB': entryB, 'idC': entryC},
    );
    expect(retryRes.shouldUpload, isFalse);
    expect(retryRes.merged.keys, unorderedEquals(['idB', 'idC']));
    expect(retryRes.toClone.map((e) => e.driveId), ['idC']);
  });
}
