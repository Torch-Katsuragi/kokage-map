// PartyLocationStore の受信マージ・送信・復帰backfillテスト
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/gps_position_record.dart';
import 'package:root_maps/models/party/peer_position.dart';
import 'package:root_maps/models/party/peer_track.dart';
import 'package:root_maps/services/party/party_connection_monitor.dart';
import 'package:root_maps/services/party/party_location_store.dart';
import 'package:root_maps/services/party/peer_source.dart';

class _FakePeerSource implements PeerSource {
  final peersCtrl = StreamController<Map<String, PeerPosition>>.broadcast();
  final tracksCtrl =
      StreamController<Map<String, List<PeerTrack>>>.broadcast();
  final srvCtrl = StreamController<bool>.broadcast();
  final published = <PeerPosition>[];
  final publishedTracks = <Map<String, Object?>>[];
  int onlineCalls = 0;
  int offlineCalls = 0;
  int clearCalls = 0;

  @override
  Stream<Map<String, PeerPosition>> get peers => peersCtrl.stream;
  @override
  Stream<Map<String, List<PeerTrack>>> get tracks => tracksCtrl.stream;
  @override
  Stream<bool> get serverConnected => srvCtrl.stream;
  @override
  Future<void> publishPosition(PeerPosition position) async =>
      published.add(position);
  @override
  Future<void> clearPosition() async => clearCalls++;
  @override
  Future<void> publishTrack({
    required String encodedPolyline,
    required int fromMs,
    required int toMs,
  }) async =>
      publishedTracks.add({'pts': encodedPolyline, 'from': fromMs, 'to': toMs});
  @override
  Future<void> goOnline() async => onlineCalls++;
  @override
  Future<void> goOffline() async => offlineCalls++;
  @override
  Future<void> dispose() async {}
}

GpsPositionRecord _rec(double lat, double lng, {double? speed}) =>
    GpsPositionRecord(
      latitude: lat,
      longitude: lng,
      speed: speed,
      timestamp: DateTime(2026, 6, 23, 12),
      receivedAt: DateTime(2026, 6, 23, 12),
    );

void main() {
  group('PartyLocationStore', () {
    late _FakePeerSource source;
    late StreamController<bool> ifCtrl;
    late StreamController<GpsPositionRecord> ownCtrl;
    late PartyConnectionMonitor monitor;
    late PartyLocationStore store;

    PartyLocationStore build({GapProvider? gapProvider}) {
      monitor = PartyConnectionMonitor(
        hasInterface: ifCtrl.stream,
        serverConnected: source.serverConnected,
        requestOnline: source.goOnline,
        requestOffline: source.goOffline,
        timerFactory: (d, cb) => Timer(const Duration(days: 1), () {}),
      );
      return PartyLocationStore(
        peerSource: source,
        monitor: monitor,
        ownPositions: ownCtrl.stream,
        selfUid: 'self',
        gapProvider: gapProvider,
      );
    }

    Future<void> goOnline() async {
      ifCtrl.add(true);
      source.srvCtrl.add(true);
      await pumpEventQueue();
    }

    setUp(() {
      source = _FakePeerSource();
      ifCtrl = StreamController<bool>.broadcast();
      ownCtrl = StreamController<GpsPositionRecord>.broadcast();
    });

    tearDown(() async {
      await store.dispose();
      await ifCtrl.close();
      await ownCtrl.close();
      await source.peersCtrl.close();
      await source.tracksCtrl.close();
      await source.srvCtrl.close();
    });

    test('peersStream は自分を除外する', () async {
      store = build();
      store.start();
      source.peersCtrl.add({
        'self': const PeerPosition(
            uid: 'self', latitude: 1, longitude: 1, serverTimeMs: 0),
        'other': const PeerPosition(
            uid: 'other', latitude: 2, longitude: 2, serverTimeMs: 0),
      });
      await pumpEventQueue();
      expect(store.peers.keys, ['other']);
    });

    test('tracksStream は自分を除外する', () async {
      store = build();
      store.start();
      const track = PeerTrack(uid: 'x', points: [], fromMs: 0, toMs: 1);
      source.tracksCtrl.add({
        'self': [track],
        'other': [track],
      });
      await pumpEventQueue();
      expect(store.tracks.keys, ['other']);
    });

    test('online のとき自分の位置を publish する', () async {
      store = build();
      store.start();
      await goOnline();
      ownCtrl.add(_rec(35.0, 139.0));
      await pumpEventQueue();
      expect(source.published, hasLength(1));
      expect(source.published.first.uid, 'self');
    });

    test('offline のときは publish しない', () async {
      store = build();
      store.start();
      // online にしない
      ownCtrl.add(_rec(35.0, 139.0));
      await pumpEventQueue();
      expect(source.published, isEmpty);
    });

    test('ゴーストON で送信を止め、サーバー上の自位置を消す', () async {
      store = build();
      store.start();
      await goOnline();
      ownCtrl.add(_rec(35.0, 139.0));
      await pumpEventQueue();
      expect(source.published, hasLength(1));

      // ゴーストON: clearPosition が呼ばれ、以後は送信しない
      await store.setGhost(true);
      expect(store.ghost, isTrue);
      expect(source.clearCalls, 1);

      ownCtrl.add(_rec(35.01, 139.01));
      await pumpEventQueue();
      expect(source.published, hasLength(1), reason: 'ゴースト中は送信しない');
    });

    test('ゴーストOFF で online なら直近位置を即再送信する', () async {
      store = build();
      store.start();
      await goOnline();
      ownCtrl.add(_rec(35.0, 139.0));
      await pumpEventQueue();
      await store.setGhost(true);
      // ゴースト中も最新の自位置は追跡される
      ownCtrl.add(_rec(35.5, 139.5));
      await pumpEventQueue();
      final before = source.published.length;

      await store.setGhost(false);
      expect(store.ghost, isFalse);
      expect(source.published.length, before + 1, reason: '解除時に即再送信');
      expect(source.published.last.latitude, 35.5);
    });

    test('ゴースト中は復帰時も backfill しない', () async {
      var gapCalls = 0;
      store = build(gapProvider: (from, to) async {
        gapCalls++;
        return GapTrack(encodedPolyline: 'abc', fromMs: from, toMs: to);
      });
      store.start();
      await goOnline();
      ownCtrl.add(_rec(35.0, 139.0));
      await pumpEventQueue();
      await store.setGhost(true);
      final before = source.published.length;

      // 圏外→復帰
      source.srvCtrl.add(false);
      await pumpEventQueue();
      source.srvCtrl.add(true);
      await pumpEventQueue();

      expect(gapCalls, 0, reason: 'ゴースト中は backfill しない');
      expect(source.published.length, before, reason: 'ゴースト中は復帰送信もしない');
    });

    test('復帰時に最新位置を送信し圏外区間を backfill する', () async {
      var gapCalls = 0;
      store = build(gapProvider: (from, to) async {
        gapCalls++;
        return GapTrack(encodedPolyline: 'abc', fromMs: from, toMs: to);
      });
      store.start();
      await goOnline();
      ownCtrl.add(_rec(35.0, 139.0));
      await pumpEventQueue();
      final sentWhileOnline = source.published.length;

      // 圏外へ（サーバー断）
      source.srvCtrl.add(false);
      await pumpEventQueue();
      expect(monitor.state, PartyConnectionState.connecting);

      // 復帰
      source.srvCtrl.add(true);
      await pumpEventQueue();

      expect(source.published.length, sentWhileOnline + 1,
          reason: '復帰時に最新位置を即送信');
      expect(gapCalls, 1);
      expect(source.publishedTracks, hasLength(1));
      expect(source.publishedTracks.first['pts'], 'abc');
    });
  });
}
