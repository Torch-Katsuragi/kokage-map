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
/// パーティ位置共有: ルームの共有ピン（集合地点・危険木・作業地点・メモ）
///
/// RTDB の `/rooms/{code}/pins/{pinId}` に置く。形は `database.rules.json` の `pins` と揃える。
/// 消すは `deleted: true`（null 削除はルールが拒む。実体は部屋ごと purge される）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// ピンの種類
enum RoomPinType {
  meeting,
  hazard,
  work,
  note;

  /// RTDB に置く値（ルールの `type` と一致させる）
  String get wireValue => name;

  static RoomPinType? fromWire(Object? v) {
    for (final t in values) {
      if (t.name == v) return t;
    }
    return null;
  }
}

/// 共有ピン 1 本
@immutable
class RoomPin {
  /// 本文の上限（UTF-16 の長さ。ルールの `text.length <= 140` と同じ数え方）
  static const int maxTextLength = 140;

  const RoomPin({
    required this.id,
    required this.author,
    required this.type,
    required this.lat,
    required this.lon,
    this.text = '',
    required this.createdAtMs,
    this.updatedAtMs = 0,
    this.deleted = false,
  });

  /// 端末で作る id（[RoomPinId.generate]）。同じ id の再送は上書きになるので冪等
  final String id;

  /// 立てた人の uid
  final String author;
  final RoomPinType type;
  final double lat;
  final double lon;

  /// 一言（空でよい。[maxTextLength] まで）
  final String text;

  /// 立てた時刻（サーバー時刻に寄せた epoch ms）。
  ///
  /// 圏外で立てたピンは送れるのが後になるので、送った時刻ではなく立てた時刻を持つ
  /// （ルールは「いま以前・26 時間以内・以後不変」を見る）
  final int createdAtMs;

  /// 最後に書き換わった時刻（サーバーが付ける。まだ送っていなければ 0）
  final int updatedAtMs;

  /// 消された
  final bool deleted;

  RoomPin copyWith({RoomPinType? type, String? text, int? createdAtMs, int? updatedAtMs, bool? deleted}) => RoomPin(
        id: id,
        author: author,
        type: type ?? this.type,
        lat: lat,
        lon: lon,
        text: text ?? this.text,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        deleted: deleted ?? this.deleted,
      );

  /// 消した形（本文も空にする。消したあとに一言だけ残らないように）
  RoomPin asDeleted() => copyWith(deleted: true, text: '');

  /// RTDB に書く形。`updatedAt` は送る側がサーバー時刻を入れる
  Map<String, Object> toWire() => {
        'author': author,
        'type': type.wireValue,
        'lat': lat,
        'lon': lon,
        'text': text,
        'createdAt': createdAtMs,
        'deleted': deleted,
      };

  /// 端末に溜める形（未送信キュー）
  Map<String, Object> toJson() => {...toWire(), 'id': id, 'updatedAt': updatedAtMs};

  static RoomPin? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !RoomPinId.isValid(id)) return null;
    return fromMap(id, json);
  }

  /// RTDB の値から読む。他人が書いた値なので篩う（壊れていれば null）
  static RoomPin? fromMap(String id, Map<Object?, Object?> m) {
    final author = m['author'];
    final type = RoomPinType.fromWire(m['type']);
    final lat = m['lat'];
    final lon = m['lon'];
    final createdAt = m['createdAt'];
    if (author is! String || author.isEmpty || type == null) return null;
    if (lat is! num || lon is! num || createdAt is! num) return null;
    final la = lat.toDouble(), lo = lon.toDouble();
    if (!la.isFinite || !lo.isFinite || la.abs() > 90 || lo.abs() > 180) return null;
    final rawText = m['text'];
    var text = rawText is String ? rawText : '';
    if (text.length > maxTextLength) text = text.substring(0, maxTextLength);
    final updatedAt = m['updatedAt'];
    return RoomPin(
      id: id,
      author: author,
      type: type,
      lat: la,
      lon: lo,
      text: text,
      createdAtMs: createdAt.toInt(),
      updatedAtMs: updatedAt is num ? updatedAt.toInt() : 0,
      deleted: m['deleted'] == true,
    );
  }

  /// 送った中身が同じか（`updatedAt` はサーバーが付けるので見ない）
  bool sameContent(RoomPin o) =>
      o.id == id &&
      o.author == author &&
      o.type == type &&
      o.lat == lat &&
      o.lon == lon &&
      o.text == text &&
      o.createdAtMs == createdAtMs &&
      o.deleted == deleted;

  @override
  bool operator ==(Object other) => other is RoomPin && sameContent(other) && other.updatedAtMs == updatedAtMs;

  @override
  int get hashCode => Object.hash(id, author, type, lat, lon, text, createdAtMs, updatedAtMs, deleted);

  @override
  String toString() => 'RoomPin($id, $type, $lat, $lon, deleted: $deleted)';
}

/// ピンの id。RTDB の push キーと同じ文字（英数・`-`・`_`）で 20 文字
class RoomPinId {
  static const String alphabet = '-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz';
  static final RegExp _valid = RegExp(r'^[0-9A-Za-z_-]{8,32}$');

  /// ルールの `$pinId.matches(...)` と同じ
  static bool isValid(String id) => _valid.hasMatch(id);

  /// 先頭 8 文字は時刻（並びが立てた順に近くなる）、残り 12 文字は乱数
  static String generate({math.Random? random, int? nowMs}) {
    final rnd = random ?? math.Random.secure();
    var t = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final head = List.filled(8, '');
    for (var i = 7; i >= 0; i--) {
      head[i] = alphabet[t % 64];
      t ~/= 64;
    }
    final tail = List.generate(12, (_) => alphabet[rnd.nextInt(64)]);
    return head.join() + tail.join();
  }
}
