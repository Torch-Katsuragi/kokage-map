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
/// パーティ位置共有: 共有ピンの中核（受信のマージ・未送信キュー・復帰時の送信）
///
/// 位置の gap backfill と同じく、圏外では送らずに溜め、`online` に戻った瞬間にまとめて送る。
/// 地図には「届いたピン」に「まだ送れていない自分の操作」を重ねて見せる（圏外でも立てたピンが見える）。
///
/// 競合: 同じピンへの書き込みはサーバーに届いた順に後勝ち（ピン全体を set する）。
/// ただし消したピンはルールが戻させないので、消すが勝つ。拒まれた操作はキューから外す。
library;

import 'dart:async';

import '../../models/party/room_pin.dart';
import '../../utils/app_logger.dart';
import 'pin_outbox.dart';
import 'pin_source.dart';

/// 地図に見せるピン 1 本
class RoomPinView {
  const RoomPinView(this.pin, {this.pending = false});
  final RoomPin pin;

  /// まだサーバーに届いていない（圏外で立てた・書き換えた）
  final bool pending;

  @override
  bool operator ==(Object other) => other is RoomPinView && other.pin == pin && other.pending == pending;

  @override
  int get hashCode => Object.hash(pin, pending);
}

class RoomPinStore {
  static const String _logTag = 'RoomPinStore';

  /// 地図に描く上限（他人が書く値なので、新しいほうからこれだけ）
  static const int maxShown = 300;

  RoomPinStore({
    required this.source,
    required this.outbox,
    required this.roomCode,
    required this.selfUid,
    required this.idGenerator,
  });

  final PinSource source;
  final PinOutbox outbox;
  final String roomCode;
  final String selfUid;
  final String Function() idGenerator;

  Map<String, RoomPin> _remote = const {};
  bool _gotFirstSnapshot = false;
  final Set<String> _seen = {};
  bool _online = false;
  bool _disposed = false;

  /// 送っている最中（id -> 送った中身）
  final Map<String, RoomPin> _inFlight = {};

  final _viewController = StreamController<List<RoomPinView>>.broadcast();
  final _newRemoteController = StreamController<RoomPin>.broadcast();
  StreamSubscription<Map<String, RoomPin>>? _sub;
  List<RoomPinView> _view = const [];

  /// 地図に見せるピン（消されたものを除く。新しい順）
  Stream<List<RoomPinView>> get viewStream => _viewController.stream;
  List<RoomPinView> get view => _view;

  /// 他のメンバーが新しく立てたピン（入った時点で既にあったものは流さない）
  Stream<RoomPin> get newRemotePins => _newRemoteController.stream;

  Future<void> start() async {
    await outbox.load();
    if (_disposed) return;
    _sub = source.pins.listen(_onRemote);
    _emit();
    unawaited(flush());
  }

  /// 接続状態（`PartyConnectionState.online` かどうか）。false→true で溜めた分を送る
  void setOnline(bool online) {
    final was = _online;
    _online = online;
    if (online && !was) unawaited(flush());
  }

  void _onRemote(Map<String, RoomPin> pins) {
    _remote = pins;
    if (!_gotFirstSnapshot) {
      _gotFirstSnapshot = true;
      _seen.addAll(pins.keys);
    } else {
      for (final p in pins.values) {
        if (_seen.add(p.id) && p.author != selfUid && !p.deleted) _newRemoteController.add(p);
      }
    }
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    final merged = <String, RoomPinView>{
      for (final p in _remote.values) p.id: RoomPinView(p),
    };
    for (final p in outbox.pending(roomCode, selfUid)) {
      final remote = _remote[p.id];
      // 消されたピンは戻らない（ルールが拒む）ので、送る前から消えたままにする
      if (remote != null && remote.deleted) continue;
      // 届いた中身が同じなら送れている（キューの片付けを待たずに確定扱い）
      merged[p.id] = RoomPinView(p, pending: remote == null || !remote.sameContent(p));
    }
    final list = [
      for (final v in merged.values)
        if (!v.pin.deleted) v,
    ]..sort((a, b) => b.pin.createdAtMs.compareTo(a.pin.createdAtMs));
    _view = list.length > maxShown ? list.sublist(0, maxShown) : list;
    _viewController.add(_view);
  }

  /// いま見えている中身（未送信の自分の操作を含む）
  RoomPin? current(String id) {
    for (final v in _view) {
      if (v.pin.id == id) return v.pin;
    }
    return null;
  }

  /// ピンを立てる
  Future<RoomPin> add({required RoomPinType type, required double lat, required double lon, String text = ''}) async {
    final pin = RoomPin(
      id: idGenerator(),
      author: selfUid,
      type: type,
      lat: lat,
      lon: lon,
      text: _clip(text),
      // ルールは createdAt <= サーバーのいま。時計の推定のずれぶん少し前にしておく
      createdAtMs: source.serverNowMs() - 1000,
    );
    await _enqueue(pin);
    return pin;
  }

  /// 種類・一言を書き換える（本人かホストだけ。権限はルールが最終判定）
  Future<void> edit(RoomPin pin, {RoomPinType? type, String? text}) =>
      _enqueue(pin.copyWith(type: type, text: text == null ? null : _clip(text)));

  /// 消す
  Future<void> delete(RoomPin pin) => _enqueue(pin.asDeleted());

  static String _clip(String s) {
    final t = s.trim();
    return t.length > RoomPin.maxTextLength ? t.substring(0, RoomPin.maxTextLength) : t;
  }

  Future<void> _enqueue(RoomPin pin) async {
    await outbox.put(roomCode, selfUid, pin);
    _emit();
    if (_online) unawaited(flush());
  }

  /// 溜めた分を送る（online のときだけ。送り中の id は待つ）
  Future<void> flush() async {
    if (!_online || _disposed) return;
    final futures = <Future<void>>[];
    for (final pin in outbox.pending(roomCode, selfUid)) {
      if (_inFlight.containsKey(pin.id)) continue;
      futures.add(_send(pin));
    }
    await Future.wait(futures);
  }

  Future<void> _send(RoomPin pin) async {
    _inFlight[pin.id] = pin;
    var resend = false;
    try {
      await source.putPin(pin);
      await outbox.remove(roomCode, pin);
    } on PinRejectedException catch (e) {
      // 終了・失効・BAN・消されたピンの書き換え。送り直しても通らない
      AppLogger.debug('$_logTag: 拒まれたので捨てる (${pin.id}): $e');
      await outbox.remove(roomCode, pin);
    } catch (e) {
      // 一時的な失敗。キューに残し、次に繋がったときに送る
      AppLogger.debug('$_logTag: 送信失敗（残す） (${pin.id}): $e');
    } finally {
      _inFlight.remove(pin.id);
      // 送っている間に新しい操作が来ていたら続けて送る
      resend = outbox.pending(roomCode, selfUid).any((p) => p.id == pin.id && !p.sameContent(pin));
    }
    _emit();
    if (resend && _online && !_disposed) await _send(outbox.pending(roomCode, selfUid).firstWhere((p) => p.id == pin.id));
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    await _viewController.close();
    await _newRemoteController.close();
  }
}
