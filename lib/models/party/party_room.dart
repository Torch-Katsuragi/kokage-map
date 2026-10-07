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
/// パーティ位置共有: ルーム・メンバーのモデル
///
/// RTDBの `/rooms/{code}/meta` と `/rooms/{code}/members/{uid}` に対応する。
library;

/// メンバーの役割
enum PartyRole {
  /// ホスト（部屋作成・キック・終了が可能）
  host,

  /// ゲスト
  guest;

  String get wireValue => name;

  static PartyRole fromWire(String? v) =>
      v == 'host' ? PartyRole.host : PartyRole.guest;
}

/// ルームメタ情報（`/rooms/{code}/meta`）
class RoomMeta {
  /// ルームコード（8文字, 曖昧文字を除外した32種から生成）
  final String roomCode;

  /// ホストのuid
  final String hostUid;

  /// 部屋名（任意, 最大60文字）
  final String? name;

  /// 有効フラグ。host終了時に false。
  final bool active;

  /// 作成時刻（epoch ms, サーバー時刻）
  final int createdAtMs;

  /// 失効時刻（epoch ms）。これを過ぎると新規参加不可。
  final int expiresAtMs;

  const RoomMeta({
    required this.roomCode,
    required this.hostUid,
    this.name,
    required this.active,
    required this.createdAtMs,
    required this.expiresAtMs,
  });

  factory RoomMeta.fromMap(String roomCode, Map<dynamic, dynamic> map) {
    return RoomMeta(
      roomCode: roomCode,
      hostUid: map['hostUid'] as String? ?? '',
      name: map['name'] as String?,
      active: map['active'] as bool? ?? false,
      createdAtMs: (map['createdAt'] as num?)?.toInt() ?? 0,
      expiresAtMs: (map['expiresAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// メンバー情報（`/rooms/{code}/members/{uid}`）
class PartyMember {
  final String uid;

  /// 表示名（最大40文字）
  final String name;

  /// マーカー色（#RRGGBB等の文字列, 最大16文字）
  final String? color;

  final PartyRole role;

  const PartyMember({
    required this.uid,
    required this.name,
    this.color,
    required this.role,
  });

  Map<String, Object?> toMap() => {
    'name': name,
    if (color != null) 'color': color,
    'role': role.wireValue,
  };

  factory PartyMember.fromMap(String uid, Map<dynamic, dynamic> map) {
    return PartyMember(
      uid: uid,
      name: map['name'] as String? ?? '',
      color: map['color'] as String?,
      role: PartyRole.fromWire(map['role'] as String?),
    );
  }
}
