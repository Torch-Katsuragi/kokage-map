// GNSS の品質の記録と足切り: NMEA（GGA の品質番号・GST）から品質を読む・平均化の集計・
// 足切り・地物のメタデータ（kmaps_metadata）への往復・情報パネルの要約
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/bluetooth_gnss_service.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/gnss_quality.dart';
import 'package:root_maps/models/gps_info.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void _feed(BluetoothGnssService s, String text) =>
    s.debugReceive(Uint8List.fromList(utf8.encode(text)));

const _ggaFixed = r'$GNGGA,123519,3412.3456,N,13554.3210,E,4,12,0.6,545.4,M,46.9,M,1.0,0001*47';
const _ggaFloat = r'$GNGGA,123519,3412.3456,N,13554.3210,E,5,10,0.9,545.4,M,46.9,M,1.0,0001*47';
const _gst = r'$GNGST,123519.00,0.5,0.03,0.02,45.0,0.012,0.016,0.030*4A';

GnssSample _sample({
  double lat = 34.0,
  double lon = 135.0,
  double? acc,
  int? sats,
  double? hdop,
  int? quality,
  bool external = true,
  DateTime? time,
}) =>
    GnssSample(
      latitude: lat,
      longitude: lon,
      accuracy: acc,
      satellites: sats,
      hdop: hdop,
      gpsQuality: quality,
      isExternal: external,
      device: external ? 'R1' : null,
      time: time,
    );

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.ja);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('NMEA から品質', () {
    test('GGA の品質番号 4 は RTK FIX、5 は RTK FLOAT', () {
      final s = BluetoothGnssService();
      _feed(s, '$_ggaFixed\n');
      expect(s.gpsQuality, 4);
      expect(GnssFix.fromGgaQuality(s.gpsQuality), GnssFix.rtkFixed);
      expect(s.satelliteCount, 12);
      expect(s.accuracySource, 'hdop');
      expect(s.accuracy, closeTo(0.6, 1e-9)); // HDOP × 1

      final f = BluetoothGnssService();
      _feed(f, '$_ggaFloat\n');
      expect(GnssFix.fromGgaQuality(f.gpsQuality), GnssFix.rtkFloat);
    });

    test('品質番号の対応（推測航法などは測位とみなさない）', () {
      expect(GnssFix.fromGgaQuality(null), isNull);
      expect(GnssFix.fromGgaQuality(0), GnssFix.none);
      expect(GnssFix.fromGgaQuality(1), GnssFix.gps);
      expect(GnssFix.fromGgaQuality(2), GnssFix.dgps);
      expect(GnssFix.fromGgaQuality(9), GnssFix.dgps);
      expect(GnssFix.fromGgaQuality(6), GnssFix.none);
      expect(GnssFix.rtkFixed.atLeast(GnssFix.rtkFloat), isTrue);
      expect(GnssFix.dgps.atLeast(GnssFix.rtkFloat), isFalse);
    });

    test('GST があれば緯度・経度の標準偏差から精度を出す', () {
      final s = BluetoothGnssService();
      _feed(s, '$_ggaFixed\n$_gst\n');
      expect(s.accuracySource, 'gst');
      expect(s.accuracy, closeTo(0.02, 1e-9)); // √(0.012² + 0.016²)
    });

    test('壊れた GST は無視する', () {
      final s = BluetoothGnssService();
      _feed(s, '$_ggaFixed\n\$GNGST,1,2,3\n\$GNGST,1,2,3,4,5,,,*00\n');
      expect(s.accuracySource, 'hdop');
    });

    test('測量の記録の 1 件（GpsSurveySample）から読む', () {
      final map = GpsSurveySample(
        GpsInfo(
          sourceType: GpsSourceType.external,
          selectedDevice: 'R1',
          latitude: 34.1,
          longitude: 135.9,
          accuracy: 0.02,
          accuracySource: 'gst',
          satelliteCount: 12,
          hdop: 0.6,
          gpsQuality: 4,
        ),
        DateTime(2026, 10, 11, 9),
      ).toMap();
      final s = GnssSample.fromMap(map)!;
      expect(s.fix, GnssFix.rtkFixed);
      expect(s.accuracySource, 'gst');
      expect(s.satellites, 12);
      expect(s.device, 'R1');
      expect(s.time, DateTime(2026, 10, 11, 9));

      // 端末の GPS は種類が分からないので単独測位とみなす
      final phone = GnssSample.fromMap({'latitude': 1.0, 'longitude': 2.0, 'sourceType': 'GPS', 'accuracy': 3.0})!;
      expect(phone.fix, GnssFix.gps);
      expect(phone.accuracySource, GnssAccuracySource.device);
    });
  });

  group('平均化の集計', () {
    final t0 = DateTime(2026, 10, 11, 9);
    final samples = [
      _sample(acc: 0.02, sats: 12, hdop: 0.6, quality: 4, time: t0),
      _sample(lat: 34.00001, acc: 0.04, sats: 11, hdop: 0.7, quality: 5, time: t0.add(const Duration(seconds: 2))),
      _sample(lat: 33.99999, acc: 0.03, sats: 13, hdop: 0.5, quality: 4, time: t0.add(const Duration(seconds: 4))),
    ];

    test('種類・衛星数は最も悪い回、DOP は最大、精度は平均、時間は最初から最後', () {
      final q = GnssQuality.aggregate(samples);
      expect(q.source, 'GNSS');
      expect(q.device, 'R1');
      expect(q.fix, GnssFix.rtkFloat);
      expect(q.satellites, 11);
      expect(q.hdop, 0.7);
      expect(q.hAccuracy, closeTo(0.03, 1e-12));
      expect(q.averagingCount, 3);
      expect(q.averagingSeconds, 4.0);
      expect(q.time, t0.add(const Duration(seconds: 4)));
    });

    test('ばらつき: 中心からの水平距離の二乗平均平方根', () {
      final q = GnssQuality.aggregate(samples);
      // 緯度 ±0.00001 度（約 1.1 m）が 2 回、中心が 1 回 → √(2/3) × 1.1 m
      expect(q.spread, closeTo(1.10574 * 0.8165, 0.01));
      expect(GnssQuality.aggregate([samples.first]).spread, isNull);
    });

    test('秒数を渡せばそれを使う', () {
      expect(GnssQuality.aggregate(samples, seconds: 10).averagingSeconds, 10);
    });
  });

  group('足切り', () {
    const gate = GnssQualityGate(maxAccuracy: 0.05, minFix: GnssFix.rtkFixed, minSatellites: 10);

    test('既定は何もしない', () {
      expect(GnssQualityGate.off.isActive, isFalse);
      final r = applyGate(GnssQualityGate.off, [_sample(external: false)]);
      expect(r.accepted, hasLength(1));
      expect(r.reasons, isEmpty);
    });

    test('満たさない条件を画面の言葉で返す', () {
      expect(gate.check(_sample(acc: 0.02, sats: 12, quality: 4)), isEmpty);
      expect(gate.check(_sample(acc: 0.3, sats: 12, quality: 4)), ['精度 ±0.30 m（上限 0.05 m）']);
      expect(gate.check(_sample(acc: 0.02, sats: 8, quality: 5)), [
        '測位 RTK FLOAT（RTK FIX 以上が必要）',
        '衛星 8（10 以上が必要）',
      ]);
      // 値が分からなければ満たさない（端末の GPS の衛星数など）
      expect(gate.check(_sample(acc: 0.02, quality: 4)), ['衛星 不明（10 以上が必要）']);
      expect(
        const GnssQualityGate(minFix: GnssFix.gps).check(_sample(external: false, acc: 4)),
        isEmpty,
      );
    });

    test('厳しくすれば満たさない回を外し、全部外れたら記録しない', () {
      final r = applyGate(gate, [
        _sample(acc: 0.02, sats: 12, quality: 4),
        _sample(acc: 0.3, sats: 12, quality: 4),
        _sample(acc: 0.5, sats: 12, quality: 4),
      ]);
      expect(r.accepted, hasLength(1));
      expect(r.rejected, 2);
      expect(r.reasons, ['精度 ±0.30 m（上限 0.05 m）']); // 条件ごとに最初の 1 回だけ
      expect(r.isRejected, isFalse);

      final none = applyGate(gate, [_sample(acc: 0.3, sats: 12, quality: 4)]);
      expect(none.isRejected, isTrue);
    });

    test('警告だけにすれば外さずに理由を返す', () {
      final warn = applyGate(gate.copyWith(strict: false), [_sample(acc: 0.3, sats: 12, quality: 4)]);
      expect(warn.accepted, hasLength(1));
      expect(warn.rejected, 0);
      expect(warn.reasons, hasLength(1));
    });

    test('設定の JSON 往復と条件の解除', () {
      expect(GnssQualityGate.fromJson(jsonDecode(jsonEncode(gate.toJson())) as Map), gate);
      final cleared = gate.copyWith(maxAccuracy: () => null, minFix: () => null, minSatellites: () => null);
      expect(cleared.isActive, isFalse);
      expect(GnssQualityGate.fromJson(const {}), GnssQualityGate.off);
    });
  });

  group('要約', () {
    test('点: 「RTK FIX・12 衛星・±0.02 m・平均 10 回」', () {
      const q = GnssQuality(
        source: 'GNSS',
        fix: GnssFix.rtkFixed,
        satellites: 12,
        hAccuracy: 0.02,
        averagingCount: 10,
      );
      expect(q.summary(), 'RTK FIX・12 衛星・±0.02 m・平均 10 回');
      const phone = GnssQuality(source: 'GPS', hAccuracy: 3.24);
      expect(phone.summary(), 'GNSS(端末)・±3.2 m・単発');
      const dropped = GnssQuality(source: 'GNSS', fix: GnssFix.dgps, averagingCount: 5, rejected: 2, hAccuracy: 12);
      expect(dropped.summary(), 'DGPS・±12 m・平均 5 回・除外 2 回');
    });

    test('線・面: 頂点の精度の最悪と中央値・最低の種類。ペンの点は数えない', () {
      Map<String, dynamic> rec(double acc, GnssFix fix) => {
            'quality': GnssQuality(source: 'GNSS', fix: fix, hAccuracy: acc).toJson(),
          };
      final metadata = {
        'drawing_points': [
          rec(0.02, GnssFix.rtkFixed),
          rec(0.05, GnssFix.rtkFloat),
          rec(0.03, GnssFix.rtkFixed),
          {'latitude': 1.0, 'longitude': 2.0, 'data_source': 'pen_tool'},
        ],
      };
      expect(
        summarizeFeatureQuality(metadata, isPoint: false),
        'GNSS 測量 3/4 点・最悪 ±0.05 m・中央値 ±0.03 m・最低 RTK FLOAT',
      );
      expect(summarizeFeatureQuality(null, isPoint: false), isNull);
      expect(
        summarizeFeatureQuality({
          'drawing_points': [
            {'data_source': 'pen_tool'},
          ],
        }, isPoint: false),
        isNull,
      );
    });

    test('quality の無い以前の記録は残っている測位から組み立てる', () {
      final legacy = {
        'pointNumber': 1,
        'sampleCount': 2,
        'usedGpsData': [
          {'latitude': 34.0, 'longitude': 135.0, 'accuracy': 0.02, 'sourceType': 'GNSS', 'gpsQuality': 4, 'satelliteCount': 12},
          {'latitude': 34.0, 'longitude': 135.0, 'accuracy': 0.04, 'sourceType': 'GNSS', 'gpsQuality': 4, 'satelliteCount': 14},
        ],
      };
      final q = GnssQuality.ofSurveyRecord(legacy)!;
      expect(q.summary(), 'RTK FIX・12 衛星・±0.03 m・平均 2 回');
      // usedGpsData すら無い記録は、その 1 件を測位とみなす
      final bare = GnssQuality.ofSurveyRecord({
        'latitude': 1.0,
        'longitude': 2.0,
        'accuracy': 3.0,
        'data_source': 'gps_survey',
      })!;
      expect(bare.hAccuracy, 3.0);
    });

    test('記録の JSON 往復', () {
      final q = GnssQuality(
        source: 'GNSS',
        device: 'R1',
        fix: GnssFix.rtkFixed,
        satellites: 12,
        hdop: 0.61234,
        pdop: 1.2,
        hAccuracy: 0.0201,
        hAccuracySource: 'gst',
        averagingCount: 10,
        averagingSeconds: 9.96,
        spread: 0.0123,
        time: DateTime.utc(2026, 10, 11, 9),
        rejected: 1,
        warnings: const ['x'],
      );
      final json = jsonDecode(jsonEncode(q.toJson())) as Map<String, dynamic>;
      expect(json, {
        'source': 'GNSS',
        'device': 'R1',
        'fix': 'rtk_fixed',
        'sats': 12,
        'hdop': 0.61,
        'pdop': 1.2,
        'hacc': 0.02,
        'hacc_src': 'gst',
        'avg_n': 10,
        'avg_s': 10.0,
        'spread': 0.012,
        'time': '2026-10-11T09:00:00.000Z',
        'rejected': 1,
        'warnings': ['x'],
      });
      final back = GnssQuality.fromJson(json);
      expect(back.toJson(), q.toJson());
    });
  });

  group('点のメタデータ（kmaps_metadata）', () {
    late Directory tmp;
    late GeoPackageFile gpkg;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gnss_quality_');
      gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    });

    tearDown(() async {
      await gpkg.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('GPS 測量の点の記録を線・面の頂点と同じ形で残し、読み直して要約できる', () async {
      final layer = (await PointLayerNode.createIn(GeoPackageNode(gpkg), 'points'))!;
      const p = LatLng(34.0, 135.0);
      final quality = GnssQuality.aggregate([
        _sample(acc: 0.02, sats: 12, quality: 4),
        _sample(acc: 0.02, sats: 12, quality: 4),
      ], seconds: 2);
      final record = {
        'pointNumber': 1,
        'sampleCount': 2,
        'quality': quality.toJson(),
      };
      final point = await PointFeatureNode.createIn(layer, p, '', '', metadata: {
        'drawing_points': [record],
      });
      expect(point, isNotNull);

      await layer.updateChildren();
      final reloaded = layer.children.whereType<PointFeatureNode>().single;
      final stored = (reloaded.metadata!['drawing_points'] as List).single as Map;
      expect(stored['quality'], quality.toJson());
      expect(
        summarizeFeatureQuality(reloaded.metadata, isPoint: true),
        'RTK FIX・12 衛星・±0.02 m・平均 2 回',
      );
    });
  });
}
