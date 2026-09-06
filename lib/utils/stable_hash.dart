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
// こかげマップ: プラットフォームを跨いで同じ値になるハッシュ
//
// > [!WARNING] `String.hashCode` をファイルに書いてはいけない
// > Dart VM と dart2js で実装が違い、同じ文字列でも web と Android で値が変わる。
// > `.qgs` のレイヤ id のように「ファイルに残して端末間で突き合わせる」用途では
// > 必ずこちらを使う（2026-09-06 に `.qgs` の id で踏んだ）。

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// [text] の UTF-8 バイト列の MD5 を 16 進で返す。
///
/// [length] で先頭だけに切れる（既定は 12 文字 = 48bit。数千件の識別子なら衝突は無視できる）。
String stableHashHex(String text, {int length = 12}) {
  final digest = md5.convert(utf8.encode(text)).toString();
  return length >= digest.length ? digest : digest.substring(0, length);
}
