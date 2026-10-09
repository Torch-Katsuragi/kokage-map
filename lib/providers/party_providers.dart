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
/// パーティ位置共有: セッション状態プロバイダ
///
/// コア層（[RtdbRoomRepository] / [RtdbPeerSource] / [PartyConnectionMonitor] /
/// [PartyLocationStore] / [ConnectivityInterfaceMonitor]）と内蔵GPS
/// （[InternalGpsLocationStore]）を束ね、ルーム作成/参加/退出と、
/// peers・接続状態・メンバーをUIへ公開する。
///
/// Android/iOS 限定（Firebase未初期化のWindowsでは createRoom/joinRoom が
/// 例外になり、UIはエラー表示する）。手書き NotifierProvider（コア層を
/// 直接保持するため codegen ではなくこちらを採用）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/party/party_room.dart';
import '../models/party/peer_position.dart';
import '../models/party/peer_track.dart';
import '../providers/notification_providers.dart';
import '../services/gps_history_recorder.dart';
import '../services/internal_gps_location_store.dart';
import '../services/party/battery_monitor.dart';
import '../services/party/connectivity_interface_monitor.dart';
import '../services/party/gps_history_gap_provider.dart';
import '../services/party/party_connection_monitor.dart';
import '../services/party/party_firebase.dart';
import '../services/party/party_location_store.dart';
import '../services/party/rtdb_peer_source.dart';
import '../services/party/rtdb_room_repository.dart';

/// パーティセッションの状態スナップショット
class PartySessionState {
  /// 参加中のルームコード（null = 未参加）
  final String? roomCode;

  /// 自分のuid（メンバー一覧から自分を見分けるため。未参加は null）
  final String? selfUid;

  /// 自分の役割
  final PartyRole? role;

  /// ホストのuid（meta.hostUid。星の表示はこれで判定し、members の role は信じない）
  final String? hostUid;

  /// 接続状態
  final PartyConnectionState connection;

  /// 他メンバーの最新位置（自分を除く）
  final Map<String, PeerPosition> peers;

  /// 他メンバーの圏外区間軌跡（自分を除く）
  final Map<String, List<PeerTrack>> tracks;

  /// メンバー一覧
  final List<PartyMember> members;

  /// 処理中（作成/参加の最中）
  final bool busy;

  /// ゴーストモード（自分の位置を共有しない）
  final bool ghost;

  /// 直近のエラーメッセージ
  final String? error;

  const PartySessionState({
    this.roomCode,
    this.selfUid,
    this.role,
    this.hostUid,
    this.connection = PartyConnectionState.offline,
    this.peers = const {},
    this.tracks = const {},
    this.members = const [],
    this.busy = false,
    this.ghost = false,
    this.error,
  });

  /// 参加中か
  bool get active => roomCode != null;

  PartySessionState copyWith({
    String? roomCode,
    String? selfUid,
    PartyRole? role,
    String? hostUid,
    PartyConnectionState? connection,
    Map<String, PeerPosition>? peers,
    Map<String, List<PeerTrack>>? tracks,
    List<PartyMember>? members,
    bool? busy,
    bool? ghost,
    String? error,
    bool clearError = false,
  }) {
    return PartySessionState(
      roomCode: roomCode ?? this.roomCode,
      selfUid: selfUid ?? this.selfUid,
      role: role ?? this.role,
      hostUid: hostUid ?? this.hostUid,
      connection: connection ?? this.connection,
      peers: peers ?? this.peers,
      tracks: tracks ?? this.tracks,
      members: members ?? this.members,
      busy: busy ?? this.busy,
      ghost: ghost ?? this.ghost,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// パーティセッション
final partySessionProvider =
    NotifierProvider<PartySession, PartySessionState>(PartySession.new);

/// パーティセッションの司令塔
class PartySession extends Notifier<PartySessionState> {
  RtdbRoomRepository? _repo;
  RtdbPeerSource? _source;
  PartyConnectionMonitor? _monitor;
  PartyLocationStore? _store;
  BatteryMonitor? _battery;

  /// 参加中に張っている購読（退出で全部止める）
  final _subs = <StreamSubscription<Object?>>[];

  /// 失効時刻に自動退出するためのタイマー
  Timer? _expiryTimer;

  /// サーバー時刻 - 端末時刻（ms）。失効判定に使う
  int _serverOffsetMs = 0;

  /// 自動退出の処理中（キックと終了が同時に来ても1回だけ流す）
  bool _closing = false;

  @override
  PartySessionState build() {
    ref.onDispose(_teardown);
    return const PartySessionState();
  }

  RtdbRoomRepository get _repository => _repo ??= RtdbRoomRepository();

  /// ルームを作成（host）
  Future<void> createRoom({String? name}) => _enter(PartyRole.host, () async {
        final meta = await _repository.createRoom(name: name);
        return meta.roomCode;
      });

  /// ルームに参加（guest）
  Future<void> joinRoom({required String code, required String name}) {
    final normalized = code.trim().toUpperCase();
    return _enter(PartyRole.guest, () async {
      await _repository.joinRoom(code: normalized, name: name);
      return normalized;
    });
  }

  /// 作成・参加の共通の入口。[enterRoom] はルームに入ってそのコードを返す
  Future<void> _enter(
      PartyRole role, Future<String> Function() enterRoom) async {
    if (state.busy || state.active) return;
    state = state.copyWith(busy: true, clearError: true);
    if (!await PartyFirebase.ensureInitialized()) {
      state = state.copyWith(busy: false, error: t.party.initFailed);
      return;
    }
    try {
      await _activate(await enterRoom(), role);
    } catch (e) {
      state = state.copyWith(busy: false, error: '$e');
    }
  }

  /// 参加成立後のストリーム配線
  Future<void> _activate(String code, PartyRole role) async {
    final uid = _repository.currentUid;
    if (uid == null) {
      state = state.copyWith(busy: false, error: t.party.signInUnconfirmed);
      return;
    }

    final source = RtdbPeerSource(roomCode: code, selfUid: uid)..start();
    final connMonitor = ConnectivityInterfaceMonitor();
    final monitor = PartyConnectionMonitor(
      hasInterface: connMonitor.hasInterface,
      serverConnected: source.serverConnected,
      requestOnline: source.goOnline,
      requestOffline: source.goOffline,
    );
    // バッテリー残量モニタ（送信ペイロード＋低残量時の送信間引きに使う）。
    final battery = BatteryMonitor();
    unawaited(battery.start());
    final store = PartyLocationStore(
      peerSource: source,
      monitor: monitor,
      ownPositions: InternalGpsLocationStore().positionStream,
      selfUid: uid,
      batteryProvider: () => battery.level,
      // 復帰時、圏外区間の軌跡を常時記録のGPS履歴からbackfillする。
      gapProvider: gpsHistoryGapProvider(GpsHistoryRecorder()),
    )..start();

    _source = source;
    _monitor = monitor;
    _store = store;
    _battery = battery;

    _subs.addAll([
      store.peersStream.listen((peers) => state = state.copyWith(peers: peers)),
      store.tracksStream
          .listen((tracks) => state = state.copyWith(tracks: tracks)),
      monitor.stateStream.listen((c) => state = state.copyWith(connection: c)),
      _repository.watchMembers(code).listen(
        (m) {
          state = state.copyWith(members: m);
          // 一覧から自分が消えた＝hostに退出させられた。
          // （自発的な退出は _teardown が先に購読を止めるのでここへ来ない）
          if (m.isNotEmpty && !m.any((member) => member.uid == uid)) {
            unawaited(_onKicked());
          }
        },
        // members から外れると room 全体の `.read` が失効し購読がエラーで死ぬ。
        // これもキック（またはルーム消滅）として扱う。
        onError: (Object _) => unawaited(_onKicked()),
      ),
      _repository.watchServerTimeOffset().listen(
            (o) => _serverOffsetMs = o,
            onError: (Object _) {},
          ),
      // ホストが終了した・失効した・meta が消えたら自動退出する。
      // （RTDBルールもこの状態では位置送信を弾くので、居残っても送れない）
      _repository.watchMeta(code).listen(
            _onMeta,
            // `.read` 失効（キック）でも来る。members 側と同じくキック扱い
            onError: (Object _) => unawaited(_onKicked()),
          ),
      store.ghostStream.listen((g) => state = state.copyWith(ghost: g)),
    ]);

    state = state.copyWith(
      roomCode: code,
      selfUid: uid,
      role: role,
      busy: false,
      ghost: store.ghost,
      connection: monitor.state,
      clearError: true,
    );
  }

  /// ゴーストモードを切り替える（自分の位置共有を一時停止/再開）
  Future<void> setGhost(bool on) async {
    await _store?.setGhost(on);
  }

  /// メンバーを退出させる（host のみ）
  Future<void> kick(String uid) async {
    final code = state.roomCode;
    if (code == null || state.role != PartyRole.host) return;
    try {
      await _repository.kickMember(code, uid);
    } catch (e) {
      state = state.copyWith(error: '$e');
    }
  }

  /// サーバー時刻の推定値（epoch ms）
  int get _serverNowMs => DateTime.now().millisecondsSinceEpoch + _serverOffsetMs;

  /// meta の更新。終了・失効・消失なら自動退出し、失効時刻にタイマーを張る
  void _onMeta(RoomMeta? meta) {
    if (meta == null || !meta.active || meta.expiresAtMs <= _serverNowMs) {
      unawaited(_onRoomClosed());
      return;
    }
    if (meta.hostUid.isNotEmpty) {
      state = state.copyWith(hostUid: meta.hostUid);
    }
    _expiryTimer?.cancel();
    final remaining = Duration(milliseconds: meta.expiresAtMs - _serverNowMs);
    _expiryTimer = Timer(remaining, () => unawaited(_onRoomClosed()));
  }

  /// hostに退出させられた（または部屋が消えた）ときの自動退出
  Future<void> _onKicked() => _closeBy(t.party.kickedNotice);

  /// ホストがルームを終了した・ルームが失効したときの自動退出
  Future<void> _onRoomClosed() => _closeBy(t.party.roomClosedNotice);

  Future<void> _closeBy(String notice) async {
    if (!state.active || _closing) return;
    _closing = true;
    final code = state.roomCode;
    try {
      await _teardown();
      if (code != null) {
        // 自分の live/members を片付ける（ルールは本人の削除を常に通す）。
        // 圏外だと書き込みの完了がいつまでも返らないので待たない。
        // 消せなくても致命的でない（実体は定期purgeが回収）。
        unawaited(_repository.leaveRoom(code).catchError((Object _) {}));
      }
      state = const PartySessionState();
      ref.read(notificationCenterProvider.notifier).add(
            title: notice,
            level: NotificationLevel.warning,
          );
    } finally {
      _closing = false;
    }
  }

  /// 退出（host の場合はルームを終了）
  Future<void> leave() async {
    final code = state.roomCode;
    final wasHost = state.role == PartyRole.host;
    await _teardown();
    if (code != null) {
      try {
        await _repository.leaveRoom(code); // active===true のうちに自己削除
        if (wasHost) await _repository.endRoom(code);
      } catch (_) {
        // 退出時のエラーは致命的でないため握りつぶす
      }
    }
    state = const PartySessionState();
  }

  Future<void> _teardown() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final subs = List.of(_subs);
    _subs.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
    await _store?.dispose();
    await _monitor?.dispose();
    await _source?.dispose();
    await _battery?.dispose();
    _store = null;
    _monitor = null;
    _source = null;
    _battery = null;
  }
}
