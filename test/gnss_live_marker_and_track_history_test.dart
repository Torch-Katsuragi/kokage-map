// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/gps_position_record.dart';
import 'package:root_maps/providers/service_providers.dart';
import 'package:root_maps/services/device_connection_log_service.dart';
import 'package:root_maps/services/gps_history_recorder.dart';
import 'package:root_maps/services/gps_manager_service.dart';
import 'package:root_maps/services/ntrip/gnss_fix_sound_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _nmeaWithChecksum(String body) {
  var xor = 0;
  for (final c in body.codeUnits) {
    xor ^= c;
  }
  return '\$$body*${xor.toRadixString(16).toUpperCase().padLeft(2, '0')}\r\n';
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      (_) async => null,
    );
  }

  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocaleSettings.setLocaleSync(AppLocale.ja);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DeviceConnectionLogService.instance.resetForTesting();
    GpsManagerService().resetForTesting();
    tmp = await Directory.systemTemp.createTemp('gnss_live_track_');
  });

  tearDown(() async {
    GpsManagerService().resetForTesting();
    if (tmp.existsSync()) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });

  test(
    '外部GNSS接続中は測量操作なしでも currentExternalMarker と externalGnssFixStream が更新され、切断・NoFixで即座に消える',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final manager = container.read(gpsManagerServiceProvider);
      manager.debugFixSoundMonitor = GnssFixSoundMonitor(
        onPlayAsset: (_) async {},
      );
      manager.externalConnectOverride = (_) async {
        manager.ensureExternalServiceForTesting.debugSetConnected(true);
      };

      final receivedFixes = <GpsInfo>[];
      final sub = manager.externalGnssFixStream.listen(receivedFixes.add);
      addTearDown(sub.cancel);

      await manager.initialize();
      await manager.switchGpsSource(
        GpsSourceType.external,
        const BluetoothDevice(address: 'AA:BB:CC:DD:EE:FF', name: 'DG-PRO1RWS'),
      );
      expect(manager.currentExternalMarker, isNull);

      // RTK FLOAT (5) の NMEA が流れる → 測量ボタンを押さなくてもマーカーとストリームが立つ
      final floatGga = _nmeaWithChecksum(
        'GNGGA,030001.00,3356.4740,N,13557.6740,E,5,14,0.8,140.5,M,38.1,M,1.2,0001',
      );
      manager.ensureExternalServiceForTesting
          .debugReceive(Uint8List.fromList(ascii.encode(floatGga)));
      await Future<void>.delayed(Duration.zero);

      expect(manager.currentExternalMarker, isNotNull);
      expect(manager.currentExternalMarker!.gpsQuality, 5);
      expect(manager.currentExternalMarker!.deviceName, 'DG-PRO1RWS');
      expect(receivedFixes, hasLength(1));
      expect(receivedFixes.single.gpsQuality, 5);

      // RTK FIX (4) へ昇格 → マーカー品質も即座に 4 へ変わる
      await Future<void>.delayed(const Duration(milliseconds: 520));
      final fixGga = _nmeaWithChecksum(
        'GNGGA,030002.00,3356.4742,N,13557.6742,E,4,18,0.5,140.8,M,38.1,M,1.0,0001',
      );
      manager.ensureExternalServiceForTesting
          .debugReceive(Uint8List.fromList(ascii.encode(fixGga)));
      await Future<void>.delayed(Duration.zero);

      expect(manager.currentExternalMarker!.gpsQuality, 4);
      expect(receivedFixes, hasLength(2));
      expect(receivedFixes.last.nmea, contains('GNGGA'));

      // 切断時は古いマーカーが地図に残らない
      await manager.ensureExternalServiceForTesting
          .debugSimulateUnexpectedDisconnect('link_loss');
      expect(manager.currentExternalMarker, isNull);
    },
  );

  test(
    'gps_history.gpkg 内に gps_tracks と並んで gnss_tracks / gnss_track_details が詳細保管され、クラッシュ後も復元される',
    () async {
      final globalDir = '${tmp.path}/global';
      final supportDir = '${tmp.path}/support';

      final recorder = GpsHistoryRecorder.forTesting()
        ..ntripMountpointProvider = () => 'KII_BASE';
      await recorder.initialize(globalDir, supportDir, deviceIdOverride: 'dev01');

      final internalStream = StreamController<GpsPositionRecord>();
      final gnssStream = StreamController<GpsInfo>();
      addTearDown(() async {
        await internalStream.close();
        await gnssStream.close();
      });

      recorder.startRecording(internalStream.stream);
      recorder.startExternalGnssRecording(gnssStream.stream);

      final baseTime = DateTime.now();

      // 端末内蔵GPSを2点流す
      for (var i = 0; i < 2; i++) {
        internalStream.add(
          GpsPositionRecord(
            latitude: 33.9400 + i * 0.0002,
            longitude: 135.9600,
            accuracy: 6.0,
            timestamp: baseTime.add(Duration(seconds: i * 2)),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      // 外部GNSSを3点流す（2点目→3点目は同一座標だが FLOAT(5)→FIX(4) への昇格なので捨てずに残る！）
      final gnssSamples = [
        GpsInfo(
          sourceType: GpsSourceType.external,
          selectedDevice: 'DG-PRO1RWS',
          latitude: 33.9410,
          longitude: 135.9610,
          altitude: 152.3,
          accuracy: 0.45,
          accuracySource: 'gst',
          gpsQuality: 5,
          fixType: 'RTK Float',
          correctionSource: 'RTK Float',
          satelliteCount: 15,
          hdop: 0.7,
          pdop: 1.3,
          vdop: 1.1,
          nmea: r'$GNGGA,01*00',
          timestamp: baseTime,
        ),
        GpsInfo(
          sourceType: GpsSourceType.external,
          selectedDevice: 'DG-PRO1RWS',
          latitude: 33.9411,
          longitude: 135.9611,
          altitude: 152.4,
          accuracy: 0.30,
          accuracySource: 'gst',
          gpsQuality: 5,
          fixType: 'RTK Float',
          correctionSource: 'RTK Float',
          satelliteCount: 16,
          hdop: 0.6,
          pdop: 1.2,
          vdop: 1.0,
          nmea: r'$GNGGA,02*00',
          timestamp: baseTime.add(const Duration(seconds: 2)),
        ),
        // ポール静止のまま RTK FIX(4) に昇格
        GpsInfo(
          sourceType: GpsSourceType.external,
          selectedDevice: 'DG-PRO1RWS',
          latitude: 33.9411,
          longitude: 135.9611,
          altitude: 152.42,
          accuracy: 0.014,
          accuracySource: 'gst',
          gpsQuality: 4,
          fixType: 'RTK Fixed',
          correctionSource: 'RTK Fixed',
          satelliteCount: 18,
          hdop: 0.5,
          pdop: 1.0,
          vdop: 0.85,
          nmea: r'$GNGGA,03*00',
          timestamp: baseTime.add(const Duration(seconds: 4)),
        ),
      ];
      for (final s in gnssSamples) {
        gnssStream.add(s);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      await recorder.flushPendingWrites();
      expect(recorder.todayGnssPoints, hasLength(3));
      await recorder.stop();

      // gps_history.gpkg に gps_tracks と gnss_tracks の両レイヤが存在する
      final historyGpkg = GeoPackageFile(
        const ['gps_history.gpkg'],
        absolutePath: '$globalDir/gps_history.gpkg',
      );
      final layers = await historyGpkg.getLayerNames();
      expect(layers, containsAll(['gps_tracks', 'gnss_tracks']));
      await historyGpkg.dispose();

      // さらに2点流した直後に Consolidation せずクラッシュ（dispose）させる
      final crashStream = StreamController<GpsInfo>();
      addTearDown(crashStream.close);
      recorder.startExternalGnssRecording(crashStream.stream);
      for (var i = 0; i < 2; i++) {
        crashStream.add(
          GpsInfo(
            sourceType: GpsSourceType.external,
            selectedDevice: 'DG-PRO1RWS',
            latitude: 33.9412 + i * 0.0001,
            longitude: 135.9612,
            altitude: 153.0,
            accuracy: 0.012,
            accuracySource: 'gst',
            gpsQuality: 4,
            fixType: 'RTK Fixed',
            satelliteCount: 19,
            hdop: 0.5,
            nmea: '\$GNGGA,crash$i*00',
            timestamp: baseTime.add(Duration(seconds: 10 + i * 2)),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await recorder.flushPendingWrites();
      recorder.dispose();

      // 次回起動時に raw バッファから未反映2点も含めて全5点が gnss_track_details に完全復元される
      final restarted = GpsHistoryRecorder.forTesting();
      await restarted.initialize(globalDir, supportDir, deviceIdOverride: 'dev01');
      addTearDown(restarted.dispose);

      final today = GpsHistoryRecorder.dateKey(DateTime.now());
      final dates = await restarted.getAvailableDates();
      expect(dates, containsAll([today, '$today [GNSS]']));

      final gnssPts = await restarted.getPointsForDate('$today [GNSS]');
      expect(gnssPts, hasLength(5));
      expect(gnssPts[2].gpsQuality, 4);
      expect(gnssPts[2].fixType, 'RTK Fixed');
      expect(gnssPts[2].accuracy, closeTo(0.014, 1e-6));
      expect(gnssPts[2].accuracySource, 'gst');
      expect(gnssPts[2].satelliteCount, 18);
      expect(gnssPts[2].hdop, closeTo(0.5, 1e-6));
      expect(gnssPts[2].pdop, closeTo(1.0, 1e-6));
      expect(gnssPts[2].vdop, closeTo(0.85, 1e-6));
      expect(gnssPts[2].gnssDevice, 'DG-PRO1RWS');
      expect(gnssPts[2].ntripMountpoint, 'KII_BASE');
      expect(gnssPts[2].rawGga, r'$GNGGA,03*00');
      // 同一座標の静止2点（index 1, 2）は details には全5点残しつつ、LineString ジオメトリ上は重複頂点を除去した4頂点になる
      expect(restarted.lastConsolidatedGnssLine, hasLength(4));
    },
  );

  test(
    '器械点にGNSSを据えて1秒ごとに静止エポックを蓄えながら、同時に TruPulse 360R でトラバース測量できる',
    () async {
      final globalDir = '${tmp.path}/parallel_global';
      final supportDir = '${tmp.path}/parallel_support';

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final manager = container.read(gpsManagerServiceProvider);
      manager.debugFixSoundMonitor = GnssFixSoundMonitor(
        onPlayAsset: (_) async {},
      );
      manager.externalConnectOverride = (_) async {
        manager.ensureExternalServiceForTesting.debugSetConnected(true);
      };

      final recorder = GpsHistoryRecorder.forTesting()
        ..ntripMountpointProvider = () => 'RTK2GO_MOUNT';
      await recorder.initialize(globalDir, supportDir, deviceIdOverride: 'field01');
      recorder.startExternalGnssRecording(manager.externalGnssFixStream);

      await manager.initialize();
      await manager.switchGpsSource(
        GpsSourceType.external,
        const BluetoothDevice(address: 'AA:BB:CC:11:22:33', name: 'DG-PRO1RWS'),
      );

      // 5エポック連続で完全同一座標の1Hz RTK FIX（Bluetooth の ±40ms ジッター込み: 960ms / 1040ms 間隔）を流す
      final t0 = DateTime.utc(2026, 11, 17, 11, 0, 0);
      final offsetsMs = [0, 960, 2000, 2970, 4010];
      for (var i = 0; i < offsetsMs.length; i++) {
        // GpsManagerService の externalGnssFixStream 相当で静止1秒エポックが届く状況を検証
        final gga = _nmeaWithChecksum(
          'GNGGA,11000$i.00,3356.4740,N,13557.6740,E,4,18,0.5,152.40,M,38.1,M,1.0,0001',
        );
        manager.ensureExternalServiceForTesting
            .debugReceive(Uint8List.fromList(ascii.encode(gga)));
        if (i < offsetsMs.length - 1) {
          final waitMs = offsetsMs[i + 1] - offsetsMs[i];
          await Future<void>.delayed(Duration(milliseconds: waitMs));
        }
      }

      await recorder.flushPendingWrites();
      await recorder.stop();

      final today = GpsHistoryRecorder.dateKey(DateTime.now());
      final savedEpochs = await recorder.getPointsForDate('$today [GNSS]');
      // 静止していて座標がミリ単位で同一でも、960ms ジッターに負けず 5秒間で全5エポックが gnss_track_details に溜まる！
      expect(savedEpochs, hasLength(5));
      expect(savedEpochs.every((p) => p.gpsQuality == 4), isTrue);
      expect(savedEpochs.every((p) => p.ntripMountpoint == 'RTK2GO_MOUNT'), isTrue);
      expect(t0.year, 2026);
      recorder.dispose();
    },
  );

  test(
    'AIエージェント協働: gps_history.gpkg 内の device_connection_events に接続・切断・再接続上限停止が記録され、過去日マージでPC側へ統合される',
    () async {
      final phoneGlobal = '${tmp.path}/phone_global';
      final phoneSupport = '${tmp.path}/phone_support';
      final remoteGpkgPath = '${tmp.path}/appdata_remote/gps_history.gpkg';
      await Directory('${tmp.path}/appdata_remote').create(recursive: true);

      final phoneRecorder = GpsHistoryRecorder.forTesting();
      await phoneRecorder.initialize(
        phoneGlobal,
        phoneSupport,
        deviceIdOverride: 'pixel9',
      );

      // リアルタイムで記録された接続・切断イベントが gps_history.gpkg の SQLite テーブルへ直書きされる
      final pastTs = DateTime.now().subtract(const Duration(days: 2));
      DeviceConnectionLogService.instance.record(
        category: DeviceConnectionCategory.gnss,
        type: DeviceConnectionEventType.connected,
        deviceName: 'DG-PRO1RWS',
        deviceAddress: 'AA:BB:CC:11:22:33',
        timestamp: pastTs,
      );
      DeviceConnectionLogService.instance.record(
        category: DeviceConnectionCategory.gnss,
        type: DeviceConnectionEventType.reconnectFailed,
        deviceName: 'DG-PRO1RWS',
        deviceAddress: 'AA:BB:CC:11:22:33',
        detail: 'auto_reconnect_stopped_after_5_attempts (power_off_or_out_of_range)',
        timestamp: pastTs.add(const Duration(minutes: 30)),
      );
      await phoneRecorder.flushPendingWrites();

      final phoneFile = GeoPackageFile(
        const ['gps_history.gpkg'],
        absolutePath: '$phoneGlobal/gps_history.gpkg',
      );
      final phoneDb = await phoneFile.getDatabase();
      final localEvents = await phoneDb.query(
        GpsHistoryRecorder.connectionEventsTableName,
        orderBy: 'id ASC',
      );
      expect(localEvents, hasLength(2));
      expect(localEvents[0]['category'], 'gnss');
      expect(localEvents[0]['event_type'], 'connected');
      expect(localEvents[0]['device_name'], 'DG-PRO1RWS');
      expect(localEvents[0]['device_id'], 'pixel9');
      expect(
        localEvents[1]['detail'],
        contains('auto_reconnect_stopped_after_5_attempts'),
      );
      await phoneFile.dispose();

      // AppData/kmap 経由の過去日統合を実行すると、リモート GPKG にも接続イベントが同期される
      final exportRes = await phoneRecorder.mergePastDaysWith(remoteGpkgPath);
      expect(exportRes.changedRemote, isTrue);
      await phoneRecorder.stop();
      phoneRecorder.dispose();

      // 別端末（またはPC側）の GpsHistoryRecorder がリモートから取り込むと 1つの gps_history.gpkg で全履歴を参照できる
      final pcGlobal = '${tmp.path}/pc_global';
      final pcSupport = '${tmp.path}/pc_support';
      final pcRecorder = GpsHistoryRecorder.forTesting();
      await pcRecorder.initialize(
        pcGlobal,
        pcSupport,
        deviceIdOverride: 'pc01',
      );
      final importRes = await pcRecorder.mergePastDaysWith(remoteGpkgPath);
      expect(importRes.changedLocal, isTrue);
      pcRecorder.dispose();

      final pcFile = GeoPackageFile(
        const ['gps_history.gpkg'],
        absolutePath: '$pcGlobal/gps_history.gpkg',
      );
      final pcDb = await pcFile.getDatabase();
      final syncedEvents = await pcDb.query(
        GpsHistoryRecorder.connectionEventsTableName,
        orderBy: 'timestamp ASC',
      );
      expect(syncedEvents, hasLength(2));
      expect(syncedEvents[0]['device_id'], 'pixel9');
      expect(syncedEvents[1]['event_type'], 'reconnectFailed');
      await pcFile.dispose();
    },
  );
}
