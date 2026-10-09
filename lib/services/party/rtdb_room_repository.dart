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
/// パーティ位置共有: ルームのライフサイクル（匿名認証・作成/参加/退出/終了）
///
/// セキュリティルールの制約に合わせた設計:
///   - 「メンバーになるまで `.read` 不可」なので、参加は**事前readせず**
///     `members/{uid}` への書き込みの許否（active && 未失効をルールが判定）で
///     成否を決める。permission-denied = 無効/失効コード。
///   - コード衝突時は meta 書き込みが denied になるので、コード再生成でリトライ。
///
/// Android/iOS 限定（firebase_auth / firebase_database は Windows 未対応）。
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../models/party/party_room.dart';
import 'room_code_generator.dart';

/// ルーム操作の例外
class PartyRoomException implements Exception {
  final String message;
  const PartyRoomException(this.message);
  @override
  String toString() => 'PartyRoomException: $message';
}

/// ルームのライフサイクル管理
class RtdbRoomRepository {
  final FirebaseDatabase _db;
  final FirebaseAuth _auth;
  final RoomCodeGenerator _codeGen;

  /// コード衝突時の最大リトライ回数
  static const int _maxCodeAttempts = 5;

  RtdbRoomRepository({
    FirebaseDatabase? database,
    FirebaseAuth? auth,
    RoomCodeGenerator? codeGenerator,
  })  : _db = database ?? FirebaseDatabase.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _codeGen = codeGenerator ?? RoomCodeGenerator();

  /// 現在のuid（未サインインなら null）
  String? get currentUid => _auth.currentUser?.uid;

  /// 匿名サインインを保証し、uidを返す
  Future<String> ensureSignedIn() async {
    final current = _auth.currentUser;
    if (current != null) return current.uid;
    final cred = await _auth.signInAnonymously();
    final uid = cred.user?.uid;
    if (uid == null) {
      throw const PartyRoomException('匿名サインインに失敗しました');
    }
    return uid;
  }

  /// ルームを作成（host）。生成したコードの [RoomMeta] を返す。
  Future<RoomMeta> createRoom({
    String? name,
    Duration ttl = const Duration(hours: 24),
  }) async {
    final uid = await ensureSignedIn();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expiresAtMs = nowMs + ttl.inMilliseconds;

    PartyRoomException? lastError;
    for (var attempt = 0; attempt < _maxCodeAttempts; attempt++) {
      final code = _codeGen.generate();
      try {
        // meta を先に書く。members の書き込みルールは root/meta/hostUid を参照するが、
        // RTDBルールの root は「書き込み前」の状態なので、meta と members を1回の
        // update で書くと members 側でホスト判定が通らない。順次書き込みにする。
        await _db.ref('rooms/$code/meta').set({
          'hostUid': uid,
          'active': true,
          'createdAt': ServerValue.timestamp,
          'expiresAt': expiresAtMs,
          if (name != null && name.isNotEmpty) 'name': name,
        });
        await _db.ref('rooms/$code/members/$uid').set({
          'name': (name == null || name.isEmpty) ? 'host' : name,
          'role': PartyRole.host.wireValue,
        });
        return RoomMeta(
          roomCode: code,
          hostUid: uid,
          name: name,
          active: true,
          createdAtMs: nowMs,
          expiresAtMs: expiresAtMs,
        );
      } on FirebaseException catch (e) {
        // コード衝突（既存ルーム）→ 別コードで再試行
        if (e.code == 'permission-denied') {
          lastError = const PartyRoomException('ルームコードの生成に失敗しました');
          continue;
        }
        rethrow;
      }
    }
    throw lastError ?? const PartyRoomException('ルーム作成に失敗しました');
  }

  /// ルームに参加（guest）。事前readせず members への書き込みで判定する。
  Future<void> joinRoom({required String code, required String name}) async {
    if (!RoomCodeGenerator.isValid(code)) {
      throw const PartyRoomException('コードの形式が正しくありません');
    }
    final uid = await ensureSignedIn();
    try {
      await _db.ref('rooms/$code/members/$uid').set({
        'name': name.isEmpty ? 'guest' : name,
        'role': PartyRole.guest.wireValue,
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw const PartyRoomException('コードが無効か、ルームが終了/失効しています');
      }
      rethrow;
    }
  }

  /// ルームから退出（自分の members と live を削除）
  Future<void> leaveRoom(String code) async {
    final uid = currentUid;
    if (uid == null) return;
    await _db.ref('rooms/$code/live/$uid').remove();
    await _db.ref('rooms/$code/members/$uid').remove();
  }

  /// ルームを終了（host のみ）。active=false にし、定期purge対象にする。
  ///
  /// `expiresAt` もサーバー時刻（いま）へ縮める。purge は `meta/expiresAt` の
  /// インデックスで失効分を引くので、終了した部屋も同じ条件で拾える。
  /// ゲストは meta の購読でこれを見て自動退出する（ルールも以後の位置送信を弾く）。
  Future<void> endRoom(String code) async {
    await _db.ref('rooms/$code/meta').update({
      'active': false,
      'expiresAt': ServerValue.timestamp,
    });
  }

  /// メンバーを退出させる（host のみ。ルールが host 特権を担保）。
  ///
  /// members の削除と `banned/{uid}` の書き込みを1回の multi-path update で行う。
  /// banned が無いと、蹴られた側が同じコードで members を書き直してすぐ戻れる。
  ///
  /// `live/{uid}` は本人以外書けないため消せない。members から外れた時点で
  /// 相手の `.read` が失効し、蹴られた側は購読エラー経由で自動退出する。
  /// 残った live の実体は定期purge（Cloud Functions）が回収する。
  Future<void> kickMember(String code, String uid) async {
    await _db.ref('rooms/$code').update({
      'members/$uid': null,
      'banned/$uid': true,
    });
  }

  /// ルームのメタ情報の購読（メンバーであること前提）。
  ///
  /// meta が消えた（purge された）ときは null を流す。
  Stream<RoomMeta?> watchMeta(String code) {
    return _db.ref('rooms/$code/meta').onValue.map((event) {
      final val = event.snapshot.value;
      if (val is! Map) return null;
      return RoomMeta.fromMap(code, val);
    });
  }

  /// サーバー時刻と端末時刻の差（ms）の購読（`.info/serverTimeOffset`）。
  ///
  /// 失効判定を端末時計のズレに左右させないために使う。
  Stream<int> watchServerTimeOffset() {
    return _db.ref('.info/serverTimeOffset').onValue.map(
          (event) => (event.snapshot.value as num?)?.toInt() ?? 0,
        );
  }

  /// メンバー一覧の購読（メンバーであること前提）
  Stream<List<PartyMember>> watchMembers(String code) {
    return _db.ref('rooms/$code/members').onValue.map((event) {
      final members = <PartyMember>[];
      for (final child in event.snapshot.children) {
        final key = child.key;
        final val = child.value;
        if (key == null || val is! Map) continue;
        members.add(PartyMember.fromMap(key, val));
      }
      return members;
    });
  }
}
