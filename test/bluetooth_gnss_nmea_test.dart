// BluetoothGnssService: NMEA の解析（接続せずに受信したことにして確かめる）
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/bluetooth_gnss_service.dart';

void _feed(BluetoothGnssService s, String text) =>
    s.debugReceive(Uint8List.fromList(utf8.encode(text)));

const _gga = r'$GPGGA,123519,3412.3456,N,13554.3210,E,2,08,0.9,545.4,M,46.9,M,,0123*47';
const _rmc = r'$GNRMC,123520,A,3412.3460,S,13554.3220,W,1.0,45.0,071026,,,D*00';
const _gsa = r'$GNGSA,A,3,01,02,42,,,,,,,,,,1.5,0.7,1.2*33';
const _gsv = r'$GPGSV,3,1,12,50,40,200,35,10,20,100,30,,,,,,,,*70';

void main() {
  test('GGA: 位置・品質・HDOP・衛星数・基準局', () {
    final s = BluetoothGnssService();
    var notified = 0;
    s.addListener(() => notified++);
    _feed(s, '$_gga\r\n');

    expect(s.latitude, closeTo(34 + 12.3456 / 60, 1e-12));
    expect(s.longitude, closeTo(135 + 54.3210 / 60, 1e-12));
    expect(s.altitude, 545.4);
    expect(s.gpsQuality, 2);
    expect(s.hdop, 0.9);
    expect(s.accuracy, closeTo(1.8, 1e-12));
    expect(s.satelliteCount, 8);
    expect(s.timestamp, isNotNull);
    expect(s.fixTypeString, 'DGPS');
    expect(notified, 1);
    expect(s.getNmeaBufferAsString(), _gga);
  });

  test('行の途中で切れて届いても 1 行として読む・RMC は南緯西経と速度・方位', () {
    final s = BluetoothGnssService();
    var notified = 0;
    s.addListener(() => notified++);
    _feed(s, _rmc.substring(0, 20));
    expect(s.latitude, isNull);
    _feed(s, '${_rmc.substring(20)}\n');

    expect(s.latitude, closeTo(-(34 + 12.3460 / 60), 1e-12));
    expect(s.longitude, closeTo(-(135 + 54.3220 / 60), 1e-12));
    expect(s.speed, closeTo(0.514444, 1e-9));
    expect(s.bearing, 45.0);
    expect(notified, 1);
  });

  test('通知は 500ms に 1 回まで', () {
    final s = BluetoothGnssService();
    var notified = 0;
    s.addListener(() => notified++);
    _feed(s, '$_gga\n$_rmc\n$_gga\n');
    expect(notified, 1);
  });

  test('GSA: DOP と使用衛星の SBAS', () {
    final s = BluetoothGnssService();
    _feed(s, '$_gsa\n$_gga\n');
    expect(s.pdop, 1.5);
    expect(s.vdop, 1.2);
    expect(s.hdop, 0.9); // GGA があとから上書き
    expect(s.fixTypeString, 'DGPS(MSAS)');
    expect(s.correctionSource, 'MSAS');
  });

  test('GSV: 視野内の SBAS 衛星と PRN', () {
    final s = BluetoothGnssService();
    _feed(s, '$_gsv\n$_gga\n');
    expect(s.fixTypeString, 'DGPS(MSAS)');
    expect(s.correctionSource, 'MSAS (PRN 137, MTSAT-2)');
  });

  test('知らない文・壊れた文は無視する', () {
    final s = BluetoothGnssService();
    _feed(s, '\$GPVTG,45.0,T,,M,1.0,N,1.9,K*00\n\$GPGGA,1,2\ngarbage\n');
    expect(s.latitude, isNull);
    expect(s.getNmeaBufferAsString().split('\n'), hasLength(3));
  });

  test('NMEA は直近 20 文だけ持つ', () {
    final s = BluetoothGnssService();
    for (var i = 0; i < 25; i++) {
      _feed(s, '\$GPTXT,$i\n');
    }
    final lines = s.getNmeaBufferAsString().split('\n');
    expect(lines, hasLength(20));
    expect(lines.first, r'$GPTXT,5');
  });

  test('推定精度は GGA の品質番号どおり（RTK 固定解がいちばん良い）', () {
    double acc(int q) => BluetoothGnssService.calculateAccuracy(q, 1.0);
    expect(acc(4), 1.0); // RTK 固定解
    expect(acc(5), 2.0); // RTK 浮動解
    expect(acc(2), 2.0); // DGPS
    expect(acc(9), 2.0); // SBAS
    expect(acc(1), 5.0); // 単独
    expect(acc(6), 5.0); // 推測航法
    expect(acc(0), 50.0);
  });
}
