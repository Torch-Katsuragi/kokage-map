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
/// パーティ位置共有: ルームの共有ピンの状態
///
/// [partySessionProvider] を見て、ルームに入ったら [RoomPinStore] を立て、出たら畳む。
/// 接続状態（online）を渡し、他のメンバーが立てたピンを通知センターに出す。
/// ルームが終わる・失効する・キックされると [partySessionProvider] が退出するので、ピンもそこで消える。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/party/room_pin.dart';
import '../services/party/party_connection_monitor.dart';
import '../services/party/pin_outbox.dart';
import '../services/party/pin_source.dart';
import '../services/party/room_pin_store.dart';
import '../services/party/rtdb_pin_source.dart';
import 'guidance_providers.dart';
import 'notification_providers.dart';
import 'party_providers.dart';

/// ピンの送受信の差し替え口（テストでは偽物に替える）
class RoomPinBackend {
  RoomPinBackend({required this.createSource, required this.outbox, this.newId = RoomPinId.generate});

  /// 本番: RTDB と SharedPreferences
  factory RoomPinBackend.rtdb() => RoomPinBackend(
        createSource: (code) => RtdbPinSource(roomCode: code)..start(),
        outbox: PinOutbox(),
      );

  final PinSource Function(String roomCode) createSource;
  final PinOutbox outbox;
  final String Function() newId;
}

final roomPinBackendProvider = Provider<RoomPinBackend>((ref) => RoomPinBackend.rtdb());

/// ピンの状態
class RoomPinsState {
  const RoomPinsState({this.pins = const [], this.selfUid, this.hostUid});

  /// 地図に見せるピン（新しい順）
  final List<RoomPinView> pins;
  final String? selfUid;
  final String? hostUid;

  bool get active => selfUid != null;

  /// 書き換え・消すができるか（立てた本人かホスト。ルールと同じ）
  bool canEdit(RoomPin pin) => selfUid != null && (pin.author == selfUid || hostUid == selfUid);
}

final roomPinsProvider = NotifierProvider<RoomPins, RoomPinsState>(RoomPins.new);

class RoomPins extends Notifier<RoomPinsState> {
  RoomPinStore? _store;
  String? _room;
  String? _uid;
  final _subs = <StreamSubscription<Object?>>[];

  @override
  RoomPinsState build() {
    ref.onDispose(() => unawaited(_stop(disposing: true)));
    ref.listen(partySessionProvider, (_, next) => _onSession(next));
    final initial = ref.read(partySessionProvider);
    if (initial.active) scheduleMicrotask(() => _onSession(ref.read(partySessionProvider)));
    return const RoomPinsState();
  }

  void _onSession(PartySessionState s) {
    final code = s.roomCode, uid = s.selfUid;
    if (code != _room || uid != _uid) {
      unawaited(_stop());
      if (code != null && uid != null) _start(code, uid);
    }
    _store?.setOnline(s.connection == PartyConnectionState.online);
    if (_store != null && (state.hostUid != s.hostUid || state.selfUid != uid)) {
      state = RoomPinsState(pins: state.pins, selfUid: uid, hostUid: s.hostUid);
    }
  }

  void _start(String code, String uid) {
    final backend = ref.read(roomPinBackendProvider);
    final store = RoomPinStore(
      source: backend.createSource(code),
      outbox: backend.outbox,
      roomCode: code,
      selfUid: uid,
      idGenerator: backend.newId,
    );
    _store = store;
    _room = code;
    _uid = uid;
    final s = ref.read(partySessionProvider);
    state = RoomPinsState(selfUid: uid, hostUid: s.hostUid);
    _subs
      ..add(store.viewStream.listen((v) => state = RoomPinsState(pins: v, selfUid: state.selfUid, hostUid: state.hostUid)))
      ..add(store.newRemotePins.listen(_notifyNew));
    unawaited(store.start());
  }

  /// 畳む。状態はその場で空にし、購読・ソースの片付けは後ろで待つ
  /// （続けて別のルームを立てたとき、後から空で上書きしないように）
  Future<void> _stop({bool disposing = false}) async {
    final store = _store;
    _store = null;
    _room = null;
    _uid = null;
    final subs = List.of(_subs);
    _subs.clear();
    if (!disposing && store != null) state = const RoomPinsState();
    // 全部まとめて止める（1 本ずつ待つと、その間に旧ルームの新着通知が出うる）
    await Future.wait([for (final s in subs) s.cancel()]);
    if (store != null) {
      await store.dispose();
      await store.source.dispose();
    }
  }

  void _notifyNew(RoomPin pin) {
    final members = ref.read(partySessionProvider).members;
    final name = members.where((m) => m.uid == pin.author).map((m) => m.name).firstOrNull;
    ref.read(notificationCenterProvider.notifier).add(
          title: t.party.pins.newNotice(name: (name == null || name.isEmpty) ? t.party.pins.someone : name, type: typeLabel(pin.type)),
          detail: pin.text.isEmpty ? null : pin.text,
          level: pin.type == RoomPinType.hazard ? NotificationLevel.warning : NotificationLevel.info,
          actionLabel: t.guidance.action,
          onAction: () async => guideTo(pin),
        );
  }

  /// ピンを立てる（圏外なら溜めて、繋がったら送る）
  Future<void> add(RoomPinType type, LatLng at, {String text = ''}) async {
    await _store?.add(type: type, lat: at.latitude, lon: at.longitude, text: text);
  }

  Future<void> edit(RoomPin pin, {required RoomPinType type, required String text}) async {
    await _store?.edit(pin, type: type, text: text);
  }

  Future<void> delete(RoomPin pin) async {
    await _store?.delete(pin);
  }

  /// 「ここへ案内」
  void guideTo(RoomPin pin) {
    ref.read(guidanceProvider.notifier).start(GuidanceTarget(
          point: LatLng(pin.lat, pin.lon),
          label: pin.text.isEmpty ? typeLabel(pin.type) : '${typeLabel(pin.type)}: ${pin.text}',
        ));
  }

  static String typeLabel(RoomPinType type) => switch (type) {
        RoomPinType.meeting => t.party.pins.typeMeeting,
        RoomPinType.hazard => t.party.pins.typeHazard,
        RoomPinType.work => t.party.pins.typeWork,
        RoomPinType.note => t.party.pins.typeNote,
      };
}
