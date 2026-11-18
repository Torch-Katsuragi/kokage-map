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
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/bluetooth_gnss_service.dart';
import 'package:root_maps/models/ntrip_config.dart';
import 'package:root_maps/providers/tool_providers.dart';
import 'package:root_maps/screens/map_page/widgets/gps_status_panel.dart';
import 'package:root_maps/services/gps_manager_service.dart';
import 'package:root_maps/services/ntrip/gnss_fix_sound_monitor.dart';
import 'package:root_maps/services/ntrip/ntrip_client_service.dart';
import 'package:root_maps/services/ntrip/ntrip_socket.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNtripSocket implements NtripSocket {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>.broadcast();
  final List<int> writtenBytes = <int>[];
  bool closed = false;

  String get writtenText => ascii.decode(writtenBytes, allowInvalid: true);

  void pushAscii(String s) => incoming.add(Uint8List.fromList(ascii.encode(s)));
  void pushBytes(List<int> b) => incoming.add(Uint8List.fromList(b));

  @override
  Stream<Uint8List> get stream => incoming.stream;

  @override
  void write(List<int> bytes) {
    writtenBytes.addAll(bytes);
  }

  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      scheduleMicrotask(() => unawaited(incoming.close()));
    }
  }
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.ja);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('GnssFixSoundMonitor & WAV assets', () {
    test('WAV sound assets exist and have valid RIFF/WAVE headers', () {
      for (final rel in [
        'assets/${GnssFixSoundMonitor.rtkFixedAsset}',
        'assets/${GnssFixSoundMonitor.rtkLostAsset}',
      ]) {
        final f = File(rel);
        expect(f.existsSync(), isTrue, reason: '$rel must exist');
        final bytes = f.readAsBytesSync();
        expect(bytes.length, greaterThan(1000));
        expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
        expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
      }
    });

    test('plays fixed chime on entering RTK FIX, lost alert on drop/disconnect, and honors cooldown & mute',
        () async {
      final played = <String>[];
      var now = DateTime(2026, 11, 16, 12, 0, 0);
      final monitor = GnssFixSoundMonitor(
        onPlayAsset: (asset) async => played.add(asset),
        clock: () => now,
      );

      // 初期状態（RTK Float = 5）では鳴らない
      await monitor.onExternalFixState(enabled: true, connected: true, gpsQuality: 5);
      expect(played, isEmpty);

      // Float -> RTK Fixed (4): 上昇チャイム
      await monitor.onExternalFixState(enabled: true, connected: true, gpsQuality: 4);
      expect(played, [GnssFixSoundMonitor.rtkFixedAsset]);

      // 同じ RTK Fixed が続いても鳴らない
      now = now.add(const Duration(seconds: 3));
      await monitor.onExternalFixState(enabled: true, connected: true, gpsQuality: 4);
      expect(played, hasLength(1));

      // RTK Fixed -> Float (5): 下降アラート
      await monitor.onExternalFixState(enabled: true, connected: true, gpsQuality: 5);
      expect(played.last, GnssFixSoundMonitor.rtkLostAsset);
      expect(played, hasLength(2));

      // 1.5秒クールダウン内のチャタリングでは鳴らない
      now = now.add(const Duration(milliseconds: 500));
      await monitor.onExternalFixState(enabled: true, connected: true, gpsQuality: 4);
      expect(played, hasLength(2));

      // クールダウン経過後に Float へ落ちて再度 Fix へ入ると鳴る
      now = now.add(const Duration(seconds: 2));
      await monitor.onExternalFixState(enabled: true, connected: true, gpsQuality: 2);
      expect(played.last, GnssFixSoundMonitor.rtkLostAsset);
      expect(played, hasLength(3));

      // ミュート（enabled: false）の間は鳴らないが内部状態は追従する
      now = now.add(const Duration(seconds: 2));
      await monitor.onExternalFixState(enabled: false, connected: true, gpsQuality: 4);
      expect(played, hasLength(3));

      // ミュート解除後に Bluetooth が不意に切断されたら喪失アラートが鳴る
      now = now.add(const Duration(seconds: 2));
      await monitor.onExternalFixState(enabled: true, connected: false, gpsQuality: null);
      expect(played.last, GnssFixSoundMonitor.rtkLostAsset);
      expect(played, hasLength(4));

      // 手動 reset 後は切断しても誤発報しない
      now = now.add(const Duration(seconds: 2));
      await monitor.onExternalFixState(enabled: true, connected: true, gpsQuality: 4);
      expect(played, hasLength(5));
      monitor.reset();
      now = now.add(const Duration(seconds: 2));
      await monitor.onExternalFixState(enabled: true, connected: false, gpsQuality: null);
      expect(played, hasLength(5));
    });
  });

  group('RTCM3 inspector, SOURCETABLE parser, and GGA formatter', () {
    test('Rtcm3StreamInspector validates CRC-24Q across split chunks and ignores bogus 0xD3 bytes', () {
      final inspector = Rtcm3StreamInspector();
      final f1005 = Rtcm3StreamInspector.buildTestFrame(1005, extraPayloadBytes: 17);
      final f1077 = Rtcm3StreamInspector.buildTestFrame(1077, extraPayloadBytes: 40);
      final f1097 = Rtcm3StreamInspector.buildTestFrame(1097, extraPayloadBytes: 32);
      final f1117 = Rtcm3StreamInspector.buildTestFrame(1117, extraPayloadBytes: 24);

      final combined = Uint8List.fromList([
        0xD3, 0x00, 0x04, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, // CRC不一致の偽フレーム
        ...f1005,
        ...f1077,
        ...f1097,
        ...f1117,
      ]);

      // 7バイトずつの細切れチャンクで流し込んでも全4フレームを正確に復元できること
      for (var i = 0; i < combined.length; i += 7) {
        final end = (i + 7 < combined.length) ? i + 7 : combined.length;
        inspector.addChunk(Uint8List.sublistView(combined, i, end));
      }

      expect(inspector.validFrames, 4);
      expect(inspector.sortedMessageTypes, [1005, 1077, 1097, 1117]);
    });

    test('NtripMountpoint parses SOURCETABLE and computes geodesic distance from user location', () {
      const table = 'SOURCETABLE 200 OK\r\n'
          'Server: SNIP\r\n\r\n'
          'CAS;rtk2go.com;2101;SNIP;0;USA;34.0;-118.0;http://rtk2go.com\r\n'
          'STR;SHINGU_RTK;Shingu;RTCM 3.3;1005(10),1077(1),1127(1);2;GPS+GLO+GAL+BDS+QZS;SNIP;JPN;33.72;135.99;0;0;u-blox;none;N;N;9600;\r\n'
          'STR;SAPPORO_RTK;Sapporo;RTCM 3.2;1005(10),1074(1);2;GPS+GLO;SNIP;JPN;43.06;141.35;0;0;Trimble;none;B;N;9600;\r\n'
          'STR;VRS_AUTO;NearestVRS;RTCM 3.3;;2;GPS+GLO+GAL+QZS;NET;JPN;0.00;0.00;1;1;VRS;none;B;Y;9600;\r\n'
          'ENDSOURCETABLE\r\n';

      final list = NtripMountpoint.parseSourcetable(table);
      expect(list, hasLength(3));
      expect(list[0].mountpoint, 'SHINGU_RTK');
      expect(list[0].requiresNmea, isFalse);
      expect(list[2].mountpoint, 'VRS_AUTO');
      expect(list[2].requiresNmea, isTrue);
      expect(list[2].stationLocation, isNull); // (0, 0) は VRS なので距離計算対象外

      const kitayama = LatLng(33.94, 135.96);
      final dShingu = list[0].distanceKmFrom(kitayama)!;
      final dSapporo = list[1].distanceKmFrom(kitayama)!;
      expect(dShingu, lessThan(30));
      expect(dSapporo, greaterThan(1000));
    });

    test('NtripGgaFormatter builds valid NMEA GGA accepted by BluetoothGnssService', () {
      final gga = NtripGgaFormatter.buildGga(
        latitude: 33.94125,
        longitude: 135.96250,
        altitude: 182.4,
        quality: 1,
        satellites: 12,
        hdop: 0.8,
        utcTime: DateTime.utc(2026, 11, 16, 9, 5, 3),
      );
      expect(gga.startsWith(r'$GPGGA,090503.00,'), isTrue);
      expect(gga.endsWith('\r\n'), isTrue);

      final gnss = BluetoothGnssService();
      gnss.debugReceive(Uint8List.fromList(ascii.encode(gga)));
      expect(gnss.latitude, closeTo(33.94125, 1e-5));
      expect(gnss.longitude, closeTo(135.96250, 1e-5));
      expect(gnss.altitude, closeTo(182.4, 1e-6));
      expect(gnss.satelliteCount, 12);
      expect(gnss.latestGgaSentence, gga.trim());
    });
  });

  group('NtripClientService protocol & GpsStatusPanel integration', () {
    test('ICY 200 OK single-CRLF stream forwards RTCM3 to BluetoothGnssService and sends GGA uplink',
        () async {
      late _FakeNtripSocket fakeSock;
      final client = NtripClientService.forTesting(
        connector: (host, port, {required useTls, required timeout}) async {
          expect(host, 'rtk2go.com');
          expect(port, 2101);
          expect(useTls, isFalse);
          return fakeSock = _FakeNtripSocket();
        },
      );
      addTearDown(client.dispose);

      final gnss = BluetoothGnssService()..recordDebugRtcm = true;
      client.onRtcmData = gnss.sendRtcm;
      client.ggaProvider = () => NtripGgaFormatter.buildGga(latitude: 33.94, longitude: 135.96);

      await client.connect(
        const NtripConfig(
          host: 'rtk2go.com',
          port: 2101,
          mountpoint: 'KUMANO_BASE',
          username: 'tester@example.com',
          password: 'none',
          sendGga: true,
          ggaIntervalSeconds: 30,
        ),
      );

      // RTK2go 必須の NTRIP User-Agent と Basic 認証ヘッダが送られていること
      expect(fakeSock.writtenText, contains('GET /KUMANO_BASE HTTP/1.0\r\n'));
      expect(fakeSock.writtenText, contains('User-Agent: NTRIP KokageMap/'));
      expect(fakeSock.writtenText, contains('Authorization: Basic '));

      // 単一 CRLF の ICY 200 OK 直後に 0xD3 RTCM3 フレームが続くケース
      final frame1005 = Rtcm3StreamInspector.buildTestFrame(1005);
      final frame1077 = Rtcm3StreamInspector.buildTestFrame(1077);
      fakeSock.pushBytes([
        ...ascii.encode('ICY 200 OK\r\n'),
        ...frame1005,
        ...frame1077,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.status, NtripStatus.streaming);
      expect(client.validRtcmFrames, 2);
      expect(client.messageTypes, [1005, 1077]);
      expect(gnss.debugSentRtcm, hasLength(1));
      expect(gnss.debugSentRtcm.first.length, frame1005.length + frame1077.length);
      // ストリーム開始直後に初回の $GPGGA アップリンクが送信されていること
      expect(fakeSock.writtenText, contains(r'$GPGGA,'));

      await client.disconnect();
      expect(client.status, NtripStatus.disconnected);
    });

    test('HTTP/1.1 200 OK chunked transfer strips chunk headers before forwarding RTCM3', () async {
      late _FakeNtripSocket fakeSock;
      final client = NtripClientService.forTesting(
        connector: (_, _, {required useTls, required timeout}) async => fakeSock = _FakeNtripSocket(),
      );
      addTearDown(client.dispose);

      final forwarded = BytesBuilder();
      client.onRtcmData = forwarded.add;

      await client.connect(
        const NtripConfig(host: 'caster.example.jp', port: 2101, mountpoint: 'VRS_RTCM3', sendGga: false),
      );

      final frame = Rtcm3StreamInspector.buildTestFrame(1117, extraPayloadBytes: 10);
      final hexLen = frame.length.toRadixString(16);
      fakeSock.pushBytes([
        ...ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: gnss/data\r\nTransfer-Encoding: chunked\r\n\r\n'),
        ...ascii.encode('$hexLen\r\n'),
        ...frame,
        ...ascii.encode('\r\n'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.status, NtripStatus.streaming);
      expect(client.validRtcmFrames, 1);
      expect(client.messageTypes, [1117]);
      expect(forwarded.toBytes(), equals(frame));
    });

    test('401 Unauthorized and SOURCETABLE typo stop immediately without reconnect loop', () async {
      var connectCount = 0;
      late _FakeNtripSocket fakeSock;
      final client = NtripClientService.forTesting(
        connector: (_, _, {required useTls, required timeout}) async {
          connectCount++;
          return fakeSock = _FakeNtripSocket();
        },
      );
      addTearDown(client.dispose);

      await client.connect(
        const NtripConfig(host: 'rtk2go.com', port: 2101, mountpoint: 'WRONG_MOUNT'),
      );
      fakeSock.pushAscii('SOURCETABLE 200 OK\r\nENDSOURCETABLE\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.status, NtripStatus.error);
      expect(client.errorMessage, t.ntrip.errMountpointNotFound);
      expect(connectCount, 1);

      await client.connect(
        const NtripConfig(host: 'private.example.jp', port: 2101, mountpoint: 'MOUNT1'),
      );
      fakeSock.pushAscii('HTTP/1.0 401 Unauthorized\r\n\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.status, NtripStatus.error);
      expect(client.errorMessage, t.ntrip.errAuth);
      expect(connectCount, 2);
    });

    testWidgets('GpsStatusPanel displays live NTRIP mountpoint & frame count when External GNSS is active',
        (tester) async {
      late _FakeNtripSocket fakeSock;
      final ntrip = NtripClientService.forTesting(
        connector: (_, _, {required useTls, required timeout}) async => fakeSock = _FakeNtripSocket(),
      );
      addTearDown(ntrip.dispose);

      await ntrip.connect(
        const NtripConfig(host: 'rtk2go.com', port: 2101, mountpoint: 'SHINGU_RTK', sendGga: false),
      );
      fakeSock.pushBytes([
        ...ascii.encode('ICY 200 OK\r\n'),
        ...Rtcm3StreamInspector.buildTestFrame(1005),
        ...Rtcm3StreamInspector.buildTestFrame(1077),
      ]);
      await tester.pump(const Duration(milliseconds: 20));

      final container = ProviderContainer();
      addTearDown(container.dispose);

      const info = GpsInfo(
        sourceType: GpsSourceType.external,
        selectedDevice: 'DG-PRO1RWS',
        latitude: 33.94,
        longitude: 135.96,
        accuracy: 0.01,
        accuracySource: 'gst',
        isGpsActive: true,
        isInitialized: true,
        isExternalConnected: true,
        satelliteCount: 16,
        hdop: 0.6,
        gpsQuality: 4,
        fixType: 'RTK Fixed',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Stack(
                  children: [
                    GpsStatusPanel(
                      tool: container.read(gpsToolProvider),
                      ntripService: ntrip,
                      infoOverride: info,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('RTK FIX'), findsOneWidget);
      expect(find.text('NTRIP: SHINGU_RTK (2)'), findsOneWidget);

      await ntrip.disconnect();
      await tester.pump();
    });
  });
}
