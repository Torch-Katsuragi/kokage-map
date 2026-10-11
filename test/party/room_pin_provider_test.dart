// roomPinsProvider の配線: ルームに入ると立ち上がり、online で送り、他人のピンを通知し、退出で消える
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/party/party_room.dart';
import 'package:root_maps/models/party/room_pin.dart';
import 'package:root_maps/providers/guidance_providers.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/providers/party_providers.dart';
import 'package:root_maps/providers/room_pin_providers.dart';
import 'package:root_maps/services/party/party_connection_monitor.dart';
import 'package:root_maps/services/party/pin_outbox.dart';

import 'fake_pin_source.dart';

class _FakeSession extends PartySession {
  @override
  PartySessionState build() => const PartySessionState();
  void set(PartySessionState s) => state = s;
}

void main() {
  late ProviderContainer container;
  late _FakeSession session;
  final sources = <String, FakePinSource>{};
  var seq = 0;

  setUp(() {
    sources.clear();
    seq = 0;
    container = ProviderContainer(overrides: [
      partySessionProvider.overrideWith(() => session = _FakeSession()),
      roomPinBackendProvider.overrideWithValue(RoomPinBackend(
        createSource: (code) => sources[code] = FakePinSource(),
        outbox: PinOutbox(storage: MemoryPinOutboxStorage()),
        newId: () => 'pinid${(seq++).toString().padLeft(6, '0')}',
      )),
    ]);
    container.listen(roomPinsProvider, (_, _) {});
    container.read(partySessionProvider);
  });

  tearDown(() => container.dispose());

  const members = [
    PartyMember(uid: 'me', name: '自分', role: PartyRole.guest),
    PartyMember(uid: 'host', name: '班長', role: PartyRole.host),
  ];

  PartySessionState inRoom({PartyConnectionState conn = PartyConnectionState.offline}) => PartySessionState(
        roomCode: 'AB23CD45',
        selfUid: 'me',
        hostUid: 'host',
        role: PartyRole.guest,
        connection: conn,
        members: members,
      );

  test('ルームに入ると立ち上がり、圏外で立てたピンは online になってから送る', () async {
    expect(container.read(roomPinsProvider).active, isFalse);
    session.set(inRoom());
    await pumpEventQueue();
    final source = sources['AB23CD45']!;
    source.emit();
    await container.read(roomPinsProvider.notifier).add(RoomPinType.meeting, const LatLng(33.9, 135.9), text: '尾根');
    await pumpEventQueue();
    expect(source.puts, isEmpty);
    expect(container.read(roomPinsProvider).pins.single.pending, isTrue);

    session.set(inRoom(conn: PartyConnectionState.online));
    await pumpEventQueue();
    expect(source.server.keys, ['pinid000000']);
    expect(container.read(roomPinsProvider).pins.single.pending, isFalse);
  });

  test('書き換え・消すは本人かホストだけ（表示の判定）', () async {
    session.set(inRoom());
    await pumpEventQueue();
    final s = container.read(roomPinsProvider);
    const mine = RoomPin(id: 'mine000001', author: 'me', type: RoomPinType.note, lat: 0, lon: 0, createdAtMs: 1);
    const others = RoomPin(id: 'other00001', author: 'x', type: RoomPinType.note, lat: 0, lon: 0, createdAtMs: 1);
    expect(s.canEdit(mine), isTrue);
    expect(s.canEdit(others), isFalse);
    session.set(PartySessionState(roomCode: 'AB23CD45', selfUid: 'host', hostUid: 'host', role: PartyRole.host));
    await pumpEventQueue();
    expect(container.read(roomPinsProvider).canEdit(others), isTrue);
  });

  test('他のメンバーのピンは通知センターに出て、そこから案内できる', () async {
    session.set(inRoom(conn: PartyConnectionState.online));
    await pumpEventQueue();
    final source = sources['AB23CD45']!..emit();
    await pumpEventQueue();
    source.remoteWrite(
        const RoomPin(id: 'hostPin001', author: 'host', type: RoomPinType.hazard, lat: 33.9, lon: 135.9, text: '倒れかけ', createdAtMs: 1));
    await pumpEventQueue();
    final n = container.read(notificationCenterProvider).single;
    expect(n.title, contains('班長'));
    expect(n.detail, '倒れかけ');
    await n.onAction!();
    expect(container.read(guidanceProvider).target?.point, const LatLng(33.9, 135.9));
  });

  test('退出（終了・失効・キックも同じ）でピンが消え、ソースも畳む', () async {
    session.set(inRoom(conn: PartyConnectionState.online));
    await pumpEventQueue();
    final source = sources['AB23CD45']!;
    source.remoteWrite(const RoomPin(id: 'hostPin001', author: 'host', type: RoomPinType.work, lat: 0, lon: 0, createdAtMs: 1));
    await pumpEventQueue();
    expect(container.read(roomPinsProvider).pins, hasLength(1));
    session.set(const PartySessionState());
    await pumpEventQueue();
    expect(container.read(roomPinsProvider).pins, isEmpty);
    expect(container.read(roomPinsProvider).active, isFalse);
    expect(source.disposed, isTrue);
  });
}
