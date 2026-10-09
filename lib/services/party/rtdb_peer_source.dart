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
/// パーティ位置共有: [PeerSource] の Firebase Realtime Database 実装
///
/// 1ルーム分の `/rooms/{roomCode}/live` と `/tracks` を担当する。
/// Android/iOS 限定（firebase_database は Windows 未対応）。
///
/// 接続検出は RTDB の `.info/connected` を権威とする。接続確立時に
/// onDisconnect を仕掛け、切断時に自分の `connected` を false へ自動更新する。
library;

import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../../models/party/peer_position.dart';
import '../../models/party/peer_track.dart';
import '../../utils/app_logger.dart';
import 'peer_source.dart';

/// RTDB を使うピア位置ソース
class RtdbPeerSource implements PeerSource {
  static const String _logTag = 'RtdbPeerSource';

  final FirebaseDatabase _db;

  /// 参加中のルームコード
  final String roomCode;

  /// 自分のuid（匿名認証）
  final String selfUid;

  RtdbPeerSource({
    required this.roomCode,
    required this.selfUid,
    FirebaseDatabase? database,
  }) : _db = database ?? FirebaseDatabase.instance;

  final StreamController<Map<String, PeerPosition>> _peersController =
      StreamController<Map<String, PeerPosition>>.broadcast();
  final StreamController<Map<String, List<PeerTrack>>> _tracksController =
      StreamController<Map<String, List<PeerTrack>>>.broadcast();
  final StreamController<bool> _connectedController =
      StreamController<bool>.broadcast();

  StreamSubscription<DatabaseEvent>? _liveSub;
  StreamSubscription<DatabaseEvent>? _tracksSub;
  StreamSubscription<DatabaseEvent>? _connectedSub;
  bool _started = false;

  DatabaseReference get _roomRef => _db.ref('rooms/$roomCode');
  DatabaseReference get _liveRef => _roomRef.child('live');
  DatabaseReference get _tracksRef => _roomRef.child('tracks');
  DatabaseReference get _selfLiveRef => _liveRef.child(selfUid);
  DatabaseReference get _connectedRef => _db.ref('.info/connected');

  @override
  Stream<Map<String, PeerPosition>> get peers => _peersController.stream;

  @override
  Stream<Map<String, List<PeerTrack>>> get tracks => _tracksController.stream;

  @override
  Stream<bool> get serverConnected => _connectedController.stream;

  /// 購読開始
  void start() {
    if (_started) return;
    _started = true;

    // 全メンバーの現在位置（自分含む。自分の除外は PartyLocationStore 側）
    _liveSub = _liveRef.onValue.listen(
      (event) {
        final result = <String, PeerPosition>{};
        for (final child in event.snapshot.children) {
          final key = child.key;
          final val = child.value;
          if (key == null || val is! Map) continue;
          try {
            final pos = PeerPosition.fromMap(key, val);
            // 範囲外・非有限の座標は描かない（ルールでも弾くが、受け側でも篩う）
            if (!isValidCoordinate(pos.latitude, pos.longitude)) continue;
            result[key] = pos;
          } catch (e) {
            AppLogger.debug('$_logTag: live parse skip ($key): $e');
          }
        }
        _peersController.add(result);
      },
      onError: (Object e) => AppLogger.debug('$_logTag: live購読エラー: $e'),
    );

    // 全メンバーの圏外区間軌跡（gap backfill の受信側。自分含む）
    _tracksSub = _tracksRef.onValue.listen(
      (event) {
        final result = <String, List<PeerTrack>>{};
        for (final member in event.snapshot.children) {
          final uid = member.key;
          if (uid == null) continue;
          final tracks = <PeerTrack>[];
          for (final child in member.children) {
            final val = child.value;
            if (val is! Map) continue;
            final track = PeerTrack.fromMap(uid, val);
            if (track != null) tracks.add(track);
          }
          if (tracks.isNotEmpty) {
            // 他人が書く値なので、1メンバーあたりの本数を絞ってから描画へ回す
            result[uid] = PeerTrack.limitPerMember(tracks);
          }
        }
        _tracksController.add(result);
      },
      onError: (Object e) => AppLogger.debug('$_logTag: tracks購読エラー: $e'),
    );

    // 実サーバー接続状態（.info/connected）
    _connectedSub = _connectedRef.onValue.listen((event) {
      final connected = event.snapshot.value == true;
      if (connected) {
        _armDisconnectHandler();
      } else {
        // 切断したら次の接続で仕掛け直す
        _disconnectArmed = false;
      }
      _connectedController.add(connected);
    });
  }

  /// 切断検知（`connected` を false にする onDisconnect）を仕掛ける。
  ///
  /// 部分更新なので `ts(=== now)` 検証には触れない。
  ///
  /// > [!WARNING] 早すぎると RTDBルールに弾かれる
  /// > `live/$uid` の書き込みは `members/$uid` の存在を要求する。
  /// > **web では `members/$uid` の書き込みが終わる前に `.info/connected` が
  /// > 立つことがあり**、そのとき `PERMISSION_DENIED` になる
  /// > （Androidでは表面化しなかった。2026-08-27 に web で踏んだ）。
  /// >
  /// > 失敗しても致命的ではない（切断検知が効かなくなるだけ）ので握るが、
  /// > 黙って諦めると切断検知が永久に死ぬ。初回の位置送信が通った時点で
  /// > 仕掛け直す（[publishPosition]）。そこまで来ていれば必ずメンバーである。
  void _armDisconnectHandler() {
    if (_disconnectArmed) return;
    _disconnectArmed = true;
    unawaited(
      _selfLiveRef.child('connected').onDisconnect().set(false).catchError((
        Object e,
      ) {
        _disconnectArmed = false;
        AppLogger.debug('$_logTag: onDisconnectを仕掛けられなかった（後で再試行）: $e');
      }),
    );
  }

  /// 切断検知を仕掛け済みか
  bool _disconnectArmed = false;

  @override
  Future<void> publishPosition(PeerPosition position) async {
    final data = position.toLiveMap();
    data['ts'] = ServerValue.timestamp; // サーバー時刻を強制（ルール: ts === now）
    await _selfLiveRef.set(data);
    // ここまで通ったならメンバーとして認められている。
    // 起動直後に弾かれていた切断検知を、ここで確実に仕掛ける。
    _armDisconnectHandler();
  }

  @override
  Future<void> clearPosition() async => _selfLiveRef.remove();

  @override
  Future<void> publishTrack({
    required String encodedPolyline,
    required int fromMs,
    required int toMs,
  }) async {
    await _roomRef.child('tracks/$selfUid').push().set({
      'pts': encodedPolyline,
      'from': fromMs,
      'to': toMs,
    });
  }

  @override
  Future<void> goOnline() async => _db.goOnline();

  @override
  Future<void> goOffline() async => _db.goOffline();

  @override
  Future<void> dispose() async {
    await _liveSub?.cancel();
    await _tracksSub?.cancel();
    await _connectedSub?.cancel();
    await _peersController.close();
    await _tracksController.close();
    await _connectedController.close();
  }
}
