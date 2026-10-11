// 共有ピンのモデル（RTDB の形・端末保存の形・篩い・id）
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/party/room_pin.dart';

void main() {
  const pin = RoomPin(
    id: 'AAAAAAAAbbbbbbbbcccc',
    author: 'u1',
    type: RoomPinType.hazard,
    lat: 33.93,
    lon: 135.96,
    text: '枯れ木が傾いている',
    createdAtMs: 1760000000000,
    updatedAtMs: 1760000001000,
  );

  group('RoomPin', () {
    test('RTDB に書く形はルールの項目と同じ（updatedAt は送る側が付ける）', () {
      expect(pin.toWire().keys.toSet(), {'author', 'type', 'lat', 'lon', 'text', 'createdAt', 'deleted'});
      expect(pin.toWire()['type'], 'hazard');
    });

    test('RTDB の値から読み戻せる', () {
      final back = RoomPin.fromMap(pin.id, {...pin.toWire(), 'updatedAt': 1760000001000});
      expect(back, pin);
    });

    test('端末保存の形から読み戻せる', () {
      expect(RoomPin.fromJson(pin.toJson()), pin);
      expect(RoomPin.fromJson({...pin.toJson(), 'id': 'bad.id'}), isNull);
    });

    test('壊れた値・範囲外は捨て、長すぎる本文は切る', () {
      final w = pin.toWire();
      expect(RoomPin.fromMap('x', {...w, 'type': 'party'}), isNull);
      expect(RoomPin.fromMap('x', {...w, 'lat': 95}), isNull);
      expect(RoomPin.fromMap('x', {...w, 'lon': double.nan}), isNull);
      expect(RoomPin.fromMap('x', {...w, 'author': ''}), isNull);
      expect(RoomPin.fromMap('x', {...w, 'createdAt': 'now'}), isNull);
      final long = RoomPin.fromMap('x', {...w, 'text': 'あ' * 200})!;
      expect(long.text.length, RoomPin.maxTextLength);
      final noText = RoomPin.fromMap('x', {...w}..remove('text'))!;
      expect(noText.text, '');
    });

    test('消した形は本文も空にする', () {
      final d = pin.asDeleted();
      expect(d.deleted, isTrue);
      expect(d.text, '');
      expect(d.createdAtMs, pin.createdAtMs);
    });

    test('sameContent は updatedAt を見ない', () {
      expect(pin.sameContent(pin.copyWith(updatedAtMs: 0)), isTrue);
      expect(pin.sameContent(pin.copyWith(text: '別')), isFalse);
    });
  });

  group('RoomPinId', () {
    test('ルールの形（英数・-・_ で 8〜32 文字）に合う', () {
      final rnd = math.Random(1);
      for (var i = 0; i < 200; i++) {
        final id = RoomPinId.generate(random: rnd);
        expect(id.length, 20);
        expect(RoomPinId.isValid(id), isTrue, reason: id);
      }
    });

    test('先頭は時刻順に並ぶ', () {
      final a = RoomPinId.generate(nowMs: 1760000000000);
      final b = RoomPinId.generate(nowMs: 1760000005000);
      expect(a.substring(0, 8).compareTo(b.substring(0, 8)), lessThan(0));
    });

    test('不正な id', () {
      for (final bad in ['short', 'has.dot.in.it', 'a' * 33, 'スペース あり']) {
        expect(RoomPinId.isValid(bad), isFalse, reason: bad);
      }
    });
  });
}
