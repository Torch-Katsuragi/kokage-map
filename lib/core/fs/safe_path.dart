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
// こかげマップ: 外から来た名前を手元のパスにするときの検査（2026-10-09）
//
// Drive のファイル名・フォルダ名には `/` や `..` を含められる。そのまま連結すると、
// 共有リンクで取り込んだフォルダから外（共有ストレージ全体）へ書けてしまう。
// 手元へ書く経路（pull・クローン・3-way マージの base）は全部ここを通す。
// web でも同じ `p`（url 形式）で判定するので、dart:io は持ち込まない。

import 'package:path/path.dart' as p;

/// 手元のパスにできない相対パスを渡された
class UnsafePathException implements Exception {
  const UnsafePathException(this.relativePath);

  final String relativePath;

  @override
  String toString() => 'UnsafePathException: $relativePath';
}

/// [segment] をパスの 1 段（ファイル名・フォルダ名）として使えるか。
/// 空・`.`・`..`、`/` `\` `:`・制御文字を含むものは使えない
bool isSafePathSegment(String segment) {
  if (segment.isEmpty || segment == '.' || segment == '..') return false;
  for (final c in segment.codeUnits) {
    // 0x2F '/'、0x5C '\'、0x3A ':'、制御文字
    if (c < 0x20 || c == 0x7F || c == 0x2F || c == 0x5C || c == 0x3A) return false;
  }
  return true;
}

/// `/` 区切りの相対パスが、どの段も [isSafePathSegment] か（先頭・末尾の `/` や `//` も不可）
bool isSafeRelativePath(String relativePath) =>
    relativePath.isNotEmpty && relativePath.split('/').every(isSafePathSegment);

/// `/` 区切りの [relativePath] を [base] の下に置いたパス。
/// 危ない段があるか、正規化して [base] の外に出るなら [UnsafePathException]
String resolveUnder(String base, String relativePath) {
  if (!isSafeRelativePath(relativePath)) throw UnsafePathException(relativePath);
  final out = p.joinAll([base, ...relativePath.split('/')]);
  // 段の検査で足りるはずだが、念のため正規化した形でも確かめる（返すのは今までどおり連結しただけの形）
  if (!p.isWithin(p.normalize(base), p.normalize(out))) throw UnsafePathException(relativePath);
  return out;
}

/// Drive のフォルダ名などを、手元のフォルダ名 1 段にする。
/// 使えない文字（Windows で使えないものと制御文字）は `_` にし、それでも使えない（空・`.`・`..`）なら [fallback]
String toLocalFolderName(String name, {required String fallback}) {
  final s = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '_');
  return isSafePathSegment(s) && s.replaceAll('.', '').isNotEmpty ? s : fallback;
}
