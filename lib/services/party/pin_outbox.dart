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
/// パーティ位置共有: 共有ピンの未送信キュー（端末に保存）
///
/// 圏外で立てた・書き換えた・消したピンをここに溜め、繋がったら送る。
/// 1 ピン 1 件（同じ id の後の操作が前を上書きする）。中身はピン全体なので、
/// 何度送っても結果は同じ（冪等）。アプリを落としても残り、同じルームに入り直すと送る。
/// ルームの寿命（26 時間）を過ぎたものは読み込み時に捨てる。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/party/room_pin.dart';
import '../../utils/app_logger.dart';

/// 保存先（テストではメモリで差し替える）
abstract class PinOutboxStorage {
  Future<String?> read();
  Future<void> write(String data);
}

class SharedPrefsPinOutboxStorage implements PinOutboxStorage {
  static const String key = 'party_pin_outbox_v1';

  @override
  Future<String?> read() async => (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String data) async => (await SharedPreferences.getInstance()).setString(key, data);
}

class MemoryPinOutboxStorage implements PinOutboxStorage {
  String? data;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String data) async => this.data = data;
}

/// 未送信の 1 件
class PinOutboxEntry {
  const PinOutboxEntry({required this.roomCode, required this.uid, required this.queuedAtMs, required this.pin});

  final String roomCode;

  /// 溜めた人の uid（別の匿名アカウントで入り直したら送らない）
  final String uid;
  final int queuedAtMs;
  final RoomPin pin;

  Map<String, Object> toJson() => {'room': roomCode, 'uid': uid, 'queuedAt': queuedAtMs, 'pin': pin.toJson()};

  static PinOutboxEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final room = j['room'], uid = j['uid'], at = j['queuedAt'];
    final pin = RoomPin.fromJson(j['pin']);
    if (room is! String || uid is! String || at is! num || pin == null) return null;
    return PinOutboxEntry(roomCode: room, uid: uid, queuedAtMs: at.toInt(), pin: pin);
  }
}

class PinOutbox {
  PinOutbox({PinOutboxStorage? storage, int Function()? nowMs})
      : _storage = storage ?? SharedPrefsPinOutboxStorage(),
        _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// ルームの寿命の上限（ルールの `expiresAt <= now + 26h` と同じ）
  static const Duration maxAge = Duration(hours: 26);

  final PinOutboxStorage _storage;
  final int Function() _now;

  /// (roomCode, pinId) -> 件
  final Map<(String, String), PinOutboxEntry> _entries = {};
  Future<void>? _loading;

  /// 保存を直列にする（後の書き込みが前を追い越さない）
  Future<void> _saving = Future.value();

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _storage.read();
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      final cutoff = _now() - maxAge.inMilliseconds;
      for (final j in list) {
        final e = PinOutboxEntry.fromJson(j);
        if (e == null || e.queuedAtMs < cutoff) continue;
        _entries[(e.roomCode, e.pin.id)] = e;
      }
    } catch (e) {
      AppLogger.debug('PinOutbox: 読み込み失敗（捨てる）: $e');
    }
  }

  /// [roomCode] で [uid] が溜めた未送信（古い順）
  List<RoomPin> pending(String roomCode, String uid) {
    final list = [
      for (final e in _entries.values)
        if (e.roomCode == roomCode && e.uid == uid) e,
    ]..sort((a, b) => a.queuedAtMs.compareTo(b.queuedAtMs));
    return [for (final e in list) e.pin];
  }

  /// 溜める（同じ id があれば置き換える）
  Future<void> put(String roomCode, String uid, RoomPin pin) {
    _entries[(roomCode, pin.id)] = PinOutboxEntry(roomCode: roomCode, uid: uid, queuedAtMs: _now(), pin: pin);
    return _save();
  }

  /// 送れた・拒まれたので外す。ただし送っている間に新しい操作で置き換わっていたら残す
  Future<void> remove(String roomCode, RoomPin sent) {
    final e = _entries[(roomCode, sent.id)];
    if (e == null || !e.pin.sameContent(sent)) return Future.value();
    _entries.remove((roomCode, sent.id));
    return _save();
  }

  Future<void> _save() {
    final data = jsonEncode([for (final e in _entries.values) e.toJson()]);
    return _saving = _saving.then((_) => _storage.write(data)).catchError((Object e) {
      AppLogger.debug('PinOutbox: 保存失敗: $e');
    });
  }
}
