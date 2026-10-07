// GpsInfo / GpsSurveySample: 測量の記録に書く形が以前の Map と同じであること
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/gps_info.dart';

void main() {
  final ts = DateTime(2026, 10, 7, 9, 30);
  final collected = DateTime(2026, 10, 7, 9, 30, 1);

  test('内蔵 GPS の点は外部 GNSS の値を書かない', () {
    final sample = GpsSurveySample(
      GpsInfo(
        sourceType: GpsSourceType.internal,
        latitude: 34.1,
        longitude: 135.9,
        altitude: 300.0,
        accuracy: 4.0,
        speed: 0.0,
        bearing: 90.0,
        timestamp: ts,
        isGpsActive: true,
      ),
      collected,
    );
    final map = sample.toMap();
    expect(map.keys.toList(), [
      'latitude', 'longitude', 'altitude', 'accuracy', 'speed', 'bearing', 'timestamp',
      'sourceType', 'sourceName', 'selectedDevice', 'collectedAt',
    ]);
    expect(map['timestamp'], ts.toIso8601String());
    expect(map['sourceType'], 'GPS');
    expect(map['collectedAt'], collected.toIso8601String());
  });

  test('外部 GNSS の点は入っている値だけ書く', () {
    final map = GpsSurveySample(
      GpsInfo(
        sourceType: GpsSourceType.external,
        selectedDevice: 'R1',
        latitude: 34.1,
        longitude: 135.9,
        timestamp: ts,
        isGpsActive: true,
        satelliteCount: 12,
        hdop: 0.8,
        gpsQuality: 2,
        fixType: 'DGPS',
        nmea: r'$GPGGA,...',
      ),
      collected,
    ).toMap();
    expect(map['sourceType'], 'GNSS');
    expect(map['selectedDevice'], 'R1');
    expect(map['satelliteCount'], 12);
    expect(map['nmea'], r'$GPGGA,...');
    expect(map.containsKey('pdop'), isFalse);
    expect(map.containsKey('correctionSource'), isFalse);
  });

  test('isActive は位置があって GPS が動いているとき', () {
    const base = GpsInfo(sourceType: GpsSourceType.internal, latitude: 1, longitude: 2);
    expect(base.isActive, isFalse);
    const active = GpsInfo(sourceType: GpsSourceType.internal, latitude: 1, longitude: 2, isGpsActive: true);
    expect(active.isActive, isTrue);
    expect(active.toMap()['isActive'], isTrue);
  });

  test('表示の比較は時刻を見ない', () {
    final a = GpsInfo(sourceType: GpsSourceType.internal, latitude: 1, longitude: 2, timestamp: ts);
    final b = GpsInfo(sourceType: GpsSourceType.internal, latitude: 1, longitude: 2, timestamp: collected);
    expect(a.sameDisplayAs(b), isTrue);
    final c = GpsInfo(sourceType: GpsSourceType.internal, latitude: 1, longitude: 2.000001, timestamp: ts);
    expect(a.sameDisplayAs(c), isFalse);
  });
}
