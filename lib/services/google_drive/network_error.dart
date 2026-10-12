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
/// 「通信できなかった」失敗かどうかの判定（純 Dart。サインイン・Drive の呼び出しで共用）。
///
/// ⚠ 林業の現場は圏外が多い。通信の失敗を権限や設定の問題として出すと、
/// 直す必要のない共有設定を触りに行かせてしまう（2026-10-12、Pixel 9 で名前解決が一瞬落ちて
/// 「共有設定を確認してください」と出た）。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

/// 通信の失敗そのものを示す語（`toString()` を小文字にして探す）。
/// `dart:io` の SocketException は web に無いので、型でなく文字で見る
const _networkMarkers = [
  'network_error',
  'network error',
  'networkerror',
  'socketexception',
  'failed host lookup',
  'unknownhost',
  'unable to resolve host',
  'clientexception',
  'connection abort',
  'connection refused',
  'connection reset',
  'connection closed',
  'connection timed out',
  'timed out',
];

/// [error] が通信の失敗（圏外・名前解決の失敗・接続切れ・時間切れ）か
bool isNetworkError(Object error) {
  if (error is http.ClientException || error is TimeoutException) return true;
  final text = error.toString().toLowerCase();
  return _networkMarkers.any(text.contains);
}
