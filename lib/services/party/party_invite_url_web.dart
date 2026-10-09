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
/// 招待URLの後始末（web）。
///
/// `?room=CODE` を読んだあと、アドレスバーと履歴からコードを消す。
/// 残しておくと、再読み込みで同じルームに入り直そうとするうえ、
/// 画面共有・スクショ・ブックマーク経由でコード（＝鍵）が漏れる。
library;

import 'package:web/web.dart' as web;

import 'party_invite.dart' show kRoomQueryParam;

void removeRoomQueryFromAddressBar() {
  final current = Uri.parse(web.window.location.href);
  if (!current.queryParameters.containsKey(kRoomQueryParam)) return;
  final rest = Map.of(current.queryParameters)..remove(kRoomQueryParam);
  final next = Uri(
    path: current.path,
    queryParameters: rest.isEmpty ? null : rest,
    fragment: current.hasFragment ? current.fragment : null,
  );
  // 履歴は増やさない（戻るでコード付きURLへ戻らないように置き換える）
  web.window.history.replaceState(null, '', next.toString());
}
