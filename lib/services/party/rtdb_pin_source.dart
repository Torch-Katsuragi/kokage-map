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
/// パーティ位置共有: [PinSource] の Firebase Realtime Database 実装（`/rooms/{code}/pins`）
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../models/party/room_pin.dart';
import '../../utils/app_logger.dart';
import 'pin_source.dart';

class RtdbPinSource implements PinSource {
  static const String _logTag = 'RtdbPinSource';

  RtdbPinSource({required this.roomCode, FirebaseDatabase? database})
      : _db = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _db;
  final String roomCode;

  final _controller = StreamController<Map<String, RoomPin>>.broadcast();
  StreamSubscription<DatabaseEvent>? _sub;
  StreamSubscription<DatabaseEvent>? _offsetSub;
  int _offsetMs = 0;

  DatabaseReference get _pinsRef => _db.ref('rooms/$roomCode/pins');

  void start() {
    if (_sub != null) return;
    _sub = _pinsRef.onValue.listen(
      (event) {
        final out = <String, RoomPin>{};
        for (final child in event.snapshot.children) {
          final key = child.key;
          final val = child.value;
          if (key == null || val is! Map || !RoomPinId.isValid(key)) continue;
          final pin = RoomPin.fromMap(key, val);
          if (pin != null) out[key] = pin;
        }
        _controller.add(out);
      },
      onError: (Object e) => AppLogger.debug('$_logTag: pins購読エラー: $e'),
    );
    _offsetSub = _db.ref('.info/serverTimeOffset').onValue.listen(
          (e) => _offsetMs = (e.snapshot.value as num?)?.toInt() ?? 0,
          onError: (Object _) {},
        );
  }

  @override
  Stream<Map<String, RoomPin>> get pins => _controller.stream;

  @override
  int serverNowMs() => DateTime.now().millisecondsSinceEpoch + _offsetMs;

  @override
  Future<void> putPin(RoomPin pin) async {
    try {
      await _pinsRef.child(pin.id).set({...pin.toWire(), 'updatedAt': ServerValue.timestamp});
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') throw PinRejectedException(e.message ?? e.code);
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _offsetSub?.cancel();
    await _controller.close();
  }
}
