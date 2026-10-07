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
/// フォルダパスの検証ユーティリティ
library;

import 'package:path/path.dart' as p;

/// 2つのパスに含有関係（片方が片方のサブディレクトリ）があるかを判定
///
/// Windows: 大文字小文字を無視して正規化比較
/// Returns: 含有関係がある場合は警告メッセージ、なければnull
String? checkContainmentRelation(String path1, String path2) {
  final norm1 = p.normalize(path1).toLowerCase();
  final norm2 = p.normalize(path2).toLowerCase();
  if (norm1 == norm2) {
    return 'Global folder and project folder point to the same directory.';
  }
  final sep = p.separator;
  // プロジェクトの中の点で始まるフォルダ（`.kokage/Global`）は地図に出ないので重ならない（2026-10-03）
  if (norm1.startsWith('$norm2$sep')) {
    if (norm1.startsWith('.', norm2.length + 1)) return null;
    return 'Global folder is inside the project folder.\n'
        'This may cause unexpected behavior.';
  }
  if (norm2.startsWith('$norm1$sep')) {
    return 'Project folder is inside the global folder.\n'
        'This may cause unexpected behavior.';
  }
  return null;
}
