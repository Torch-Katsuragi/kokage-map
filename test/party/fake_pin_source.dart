// 共有ピンの偽の RTDB（ルールの要点だけ真似る: 消したピンは戻せない）
import 'dart:async';

import 'package:root_maps/models/party/room_pin.dart';
import 'package:root_maps/services/party/pin_source.dart';

class FakePinSource implements PinSource {
  final server = <String, RoomPin>{};
  final _ctrl = StreamController<Map<String, RoomPin>>.broadcast();
  final puts = <RoomPin>[];
  int serverTimeMs = 1760000000000;
  bool disposed = false;

  /// 次の書き込みをこれで止める（届かないまま待たせる）
  Completer<void>? hold;

  /// 次の書き込みを一時的な失敗にする
  bool failNext = false;

  @override
  Stream<Map<String, RoomPin>> get pins => _ctrl.stream;

  /// サーバーの今の中身を流す（購読の初回スナップショット相当）
  void emit() => _ctrl.add(Map.of(server));

  /// 他のメンバーの書き込みを流す
  void remoteWrite(RoomPin pin) {
    server[pin.id] = pin.copyWith(updatedAtMs: serverTimeMs);
    emit();
  }

  @override
  Future<void> putPin(RoomPin pin) async {
    final h = hold;
    if (h != null) {
      hold = null;
      await h.future;
    }
    if (failNext) {
      failNext = false;
      throw StateError('network');
    }
    puts.add(pin);
    final cur = server[pin.id];
    if (cur != null && cur.deleted && !pin.deleted) throw const PinRejectedException('deleted');
    if (cur != null && cur.createdAtMs != pin.createdAtMs) throw const PinRejectedException('createdAt');
    server[pin.id] = pin.copyWith(updatedAtMs: ++serverTimeMs);
    emit();
  }

  @override
  int serverNowMs() => serverTimeMs;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _ctrl.close();
  }
}
