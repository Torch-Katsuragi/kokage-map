// 共有ピンの未送信キュー・復帰時の送信・再送の冪等性・後勝ち／消すが勝つ
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/party/room_pin.dart';
import 'package:root_maps/services/party/pin_outbox.dart';
import 'package:root_maps/services/party/room_pin_store.dart';

import 'fake_pin_source.dart';

void main() {
  late FakePinSource source;
  late MemoryPinOutboxStorage storage;
  late int now;
  var seq = 0;

  String nextId() => 'pin${(seq++).toString().padLeft(8, '0')}';

  RoomPinStore build({PinOutbox? outbox, String uid = 'me'}) => RoomPinStore(
        source: source,
        outbox: outbox ?? PinOutbox(storage: storage, nowMs: () => now),
        roomCode: 'AB23CD45',
        selfUid: uid,
        idGenerator: nextId,
      );

  setUp(() {
    source = FakePinSource();
    storage = MemoryPinOutboxStorage();
    now = 1760000000000;
    seq = 0;
  });

  Future<void> settle() => pumpEventQueue();

  test('圏外で立てたピンは送らずに溜め、地図には未送信として見える', () async {
    final store = build();
    await store.start();
    source.emit();
    await store.add(type: RoomPinType.meeting, lat: 33.9, lon: 135.9, text: '  集合  ');
    await settle();
    expect(source.puts, isEmpty);
    expect(store.view, hasLength(1));
    expect(store.view.single.pending, isTrue);
    expect(store.view.single.pin.text, '集合');
    expect(store.view.single.pin.createdAtMs, lessThan(source.serverTimeMs));
    expect(storage.data, contains('pin00000000'));
  });

  test('繋がった瞬間に送り、届いたら未送信の印が消えキューも空になる', () async {
    final store = build();
    await store.start();
    source.emit();
    await store.add(type: RoomPinType.hazard, lat: 33.9, lon: 135.9);
    store.setOnline(true);
    await settle();
    expect(source.puts, hasLength(1));
    expect(source.server.keys, ['pin00000000']);
    expect(store.view.single.pending, isFalse);
    final reloaded = PinOutbox(storage: storage, nowMs: () => now);
    await reloaded.load();
    expect(reloaded.pending('AB23CD45', 'me'), isEmpty);
  });

  test('アプリを落としても溜めた分は残り、同じルームに入り直すと送る（同じ id で 1 本だけ）', () async {
    final first = build();
    await first.start();
    source.emit();
    await first.add(type: RoomPinType.work, lat: 1, lon: 2);
    await first.dispose();

    // 再起動: 保存先から読み直す
    final second = build(outbox: PinOutbox(storage: storage, nowMs: () => now));
    await second.start();
    source.emit();
    expect(second.view.single.pending, isTrue);
    second.setOnline(true);
    await settle();
    expect(source.server.keys, ['pin00000000']);
    expect(second.view.single.pending, isFalse);
  });

  test('届いたのに片付ける前に落ちても、再送は同じ中身の上書きで冪等', () async {
    final store = build();
    await store.start();
    source.emit();
    final pin = await store.add(type: RoomPinType.note, lat: 1, lon: 2, text: 'a');
    // サーバーには届いた（返事を受け取る前にアプリが落ちた）
    await source.putPin(pin);
    final relaunched = build(outbox: PinOutbox(storage: storage, nowMs: () => now));
    await relaunched.start();
    source.emit();
    relaunched.setOnline(true);
    await settle();
    expect(source.puts, hasLength(2));
    expect(source.server, hasLength(1));
    expect(source.server.values.single.sameContent(pin), isTrue);
  });

  test('寿命（26時間）を過ぎた未送信は読み込みで捨てる', () async {
    final store = build();
    await store.start();
    await store.add(type: RoomPinType.note, lat: 1, lon: 2);
    now += const Duration(hours: 27).inMilliseconds;
    final later = PinOutbox(storage: storage, nowMs: () => now);
    await later.load();
    expect(later.pending('AB23CD45', 'me'), isEmpty);
  });

  test('別の uid・別のルームの未送信は送らない', () async {
    final outbox = PinOutbox(storage: storage, nowMs: () => now);
    await outbox.load();
    await outbox.put('ZZ98XY76', 'me', const RoomPin(id: 'otherRoom01', author: 'me', type: RoomPinType.note, lat: 0, lon: 0, createdAtMs: 1));
    await outbox.put('AB23CD45', 'old', const RoomPin(id: 'otherUid001', author: 'old', type: RoomPinType.note, lat: 0, lon: 0, createdAtMs: 1));
    final store = build(outbox: outbox);
    await store.start();
    source.emit();
    store.setOnline(true);
    await settle();
    expect(source.puts, isEmpty);
    expect(store.view, isEmpty);
  });

  test('送っている間に書き換えたら、届いた後に新しい中身を続けて送る', () async {
    final store = build();
    await store.start();
    source.emit();
    store.setOnline(true);
    source.hold = Completer<void>();
    final hold = source.hold!;
    final pin = await store.add(type: RoomPinType.meeting, lat: 1, lon: 2, text: '初め');
    await settle();
    await store.edit(store.current(pin.id)!, text: '直した');
    hold.complete();
    await settle();
    expect(source.puts.map((p) => p.text), ['初め', '直した']);
    expect(source.server[pin.id]!.text, '直した');
    expect(store.view.single.pending, isFalse);
  });

  test('一時的な失敗はキューに残し、次に繋がったときに送る', () async {
    final store = build();
    await store.start();
    source.emit();
    source.failNext = true;
    store.setOnline(true);
    await store.add(type: RoomPinType.meeting, lat: 1, lon: 2);
    await settle();
    expect(source.server, isEmpty);
    expect(store.view.single.pending, isTrue);
    store
      ..setOnline(false)
      ..setOnline(true);
    await settle();
    expect(source.server, hasLength(1));
  });

  test('消されたピンへの遅れた書き換えは拒まれ、キューから外れて消えたまま（消すが勝つ）', () async {
    final store = build();
    await store.start();
    source.emit();
    store.setOnline(true);
    final pin = await store.add(type: RoomPinType.hazard, lat: 1, lon: 2, text: 'a');
    await settle();
    store.setOnline(false);
    final mine = store.current(pin.id)!;
    // 圏外の間にホストが消した
    source.remoteWrite(mine.asDeleted());
    await store.edit(mine, text: '遅れて届く');
    store.setOnline(true);
    await settle();
    expect(source.server[pin.id]!.deleted, isTrue);
    expect(store.view, isEmpty);
    final reloaded = PinOutbox(storage: storage, nowMs: () => now);
    await reloaded.load();
    expect(reloaded.pending('AB23CD45', 'me'), isEmpty);
  });

  test('書き換えは後勝ち（後から届いた中身が残る）', () async {
    final store = build();
    await store.start();
    source.emit();
    store.setOnline(true);
    final pin = await store.add(type: RoomPinType.work, lat: 1, lon: 2, text: '自分');
    await settle();
    source.remoteWrite(store.current(pin.id)!.copyWith(text: 'ホスト'));
    await settle();
    expect(store.current(pin.id)!.text, 'ホスト');
    await store.edit(store.current(pin.id)!, text: '自分が後');
    await settle();
    expect(source.server[pin.id]!.text, '自分が後');
  });

  test('他のメンバーが新しく立てたピンだけ知らせる（入った時点のもの・自分のもの・消したものは知らせない）', () async {
    source.server['already0001'] =
        const RoomPin(id: 'already0001', author: 'x', type: RoomPinType.note, lat: 0, lon: 0, createdAtMs: 1);
    final store = build();
    final got = <String>[];
    store.newRemotePins.listen((p) => got.add(p.id));
    await store.start();
    source.emit();
    store.setOnline(true);
    await store.add(type: RoomPinType.note, lat: 0, lon: 0);
    source.remoteWrite(const RoomPin(id: 'fromPeer001', author: 'peer', type: RoomPinType.hazard, lat: 0, lon: 0, createdAtMs: 2));
    source.remoteWrite(
        const RoomPin(id: 'gonePeer001', author: 'peer', type: RoomPinType.hazard, lat: 0, lon: 0, createdAtMs: 3, deleted: true));
    await settle();
    expect(got, ['fromPeer001']);
    expect(store.view.map((v) => v.pin.id), containsAll(['already0001', 'fromPeer001', 'pin00000000']));
    expect(store.view.map((v) => v.pin.id), isNot(contains('gonePeer001')));
  });
}
