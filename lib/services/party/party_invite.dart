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
/// パーティ位置共有: 招待リンク（URL参加）
///
/// 「ルーム参加がURLで済む」= web版の主力機能（docs/features/concept 参照）。
///   - 出す側: [buildInviteUrl] でルームコードを web 版URLに載せる。
///     QR・リンクどちらで渡しても、スマホカメラで読めば web 版がそのまま開く。
///   - 受け側: web 版は起動時に [consumePendingRoomCode] で `?room=` を拾う。
///     アプリ内の入力欄には [extractRoomCode] を通し、招待URLを貼っても
///     生コードを打っても同じように参加できる（読むときは寛容に）。
library;

import '../../core/platform_capabilities.dart';
import 'party_invite_url_io.dart'
    if (dart.library.js_interop) 'party_invite_url_web.dart' as url_impl;
import 'room_code_generator.dart';

/// 招待リンクの行き先（web版の本番URL）
///
/// 承認済みJavaScript生成元・Firebase Hosting の設定と対で管理する
/// （docs/technical/web-hosting.md）。
const String kWebAppUrl = 'https://kokage-map.sleeptree.jp/';

/// URLクエリのキー（`?room=CODE`）
const String kRoomQueryParam = 'room';

/// ルームコードから招待URLを組み立てる
String buildInviteUrl(String roomCode) =>
    '$kWebAppUrl?$kRoomQueryParam=$roomCode';

/// 入力テキストからルームコードを取り出す（読むときは寛容に）。
///
/// 受け付けるもの:
///   - 生のコード（大文字小文字・前後空白は正規化）
///   - 招待URL（`?room=CODE` を含む任意のURL）
///
/// 取り出せない・形式不正なら null。
String? extractRoomCode(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  // URLなら room パラメータを探す
  if (text.contains('://') || text.contains('$kRoomQueryParam=')) {
    final uri = Uri.tryParse(text);
    final fromQuery = uri?.queryParameters[kRoomQueryParam];
    if (fromQuery != null) {
      final code = fromQuery.trim().toUpperCase();
      return RoomCodeGenerator.isValid(code) ? code : null;
    }
    return null;
  }

  final code = text.toUpperCase();
  return RoomCodeGenerator.isValid(code) ? code : null;
}

bool _pendingConsumed = false;

/// 起動URL（web の `?room=CODE`）からルームコードを1回だけ取り出す。
///
/// 2回目以降と web 以外では null。地図画面が初回表示時に呼び、
/// 参加ダイアログへコードを充填する。
///
/// 読んだらアドレスバーから `?room=` を消す（再読み込みでの再参加と、
/// 画面共有・履歴からのコード漏れを防ぐ）。
String? consumePendingRoomCode() {
  if (_pendingConsumed) return null;
  _pendingConsumed = true;
  if (!PlatformCapabilities.isWeb) return null;
  final raw = Uri.base.queryParameters[kRoomQueryParam];
  if (raw == null) return null;
  try {
    url_impl.removeRoomQueryFromAddressBar();
  } catch (_) {
    // 消せなくても参加には響かない
  }
  final code = raw.trim().toUpperCase();
  return RoomCodeGenerator.isValid(code) ? code : null;
}

/// 起動URLに有効なルームコードが載っているか（消費せずに覗く）。
///
/// HomeScreen が「招待経由の起動」を判定して地図画面へ直行するのに使う。
bool hasPendingRoomCode() {
  if (_pendingConsumed || !PlatformCapabilities.isWeb) return false;
  final raw = Uri.base.queryParameters[kRoomQueryParam];
  if (raw == null) return false;
  return RoomCodeGenerator.isValid(raw.trim().toUpperCase());
}
