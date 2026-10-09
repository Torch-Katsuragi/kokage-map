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
// こかげマップ: フォルダにファイルをそのまま入れる（「ファイルを追加」とドラッグ＆ドロップ。2026-10-09〜）
//
// 取り込み（gpkg へのコピー）はやめ、置いたファイルがそのままレイヤになる（[[external-formats]]）。
// ここはファイルを写すだけ。web でも動くよう `fs`（web は OPFS / フォルダのハンドル）で書く。

import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../core/fs/safe_path.dart';

/// 入れるファイル 1 つ（名前と、中身の読み方）
typedef IncomingFile = ({String name, Future<Uint8List> Function() read});

/// [FolderFileAdder.addTo] の結果
class AddFilesResult {
  AddFilesResult({required this.added, required this.failed});

  /// 書いたファイルの名前（衝突で付け替えたあとの名前）
  final List<String> added;

  /// 書けなかったもの（元の名前と理由）
  final List<({String name, Object error})> failed;
}

class FolderFileAdder {
  FolderFileAdder._();

  /// shp を地図に出すのに要る付属ファイル
  static const shpRequiredSidecars = ['.dbf', '.shx'];

  /// shp 一式を成す拡張子（変換で消すものと同じ。[[external-formats]]）
  static const shapefileExtensions = {
    '.shp', '.shx', '.dbf', '.prj', '.cpg', '.qix', '.sbn', '.sbx', '.shp.xml', '.fix', '.aih', '.ain', //
  };

  /// shp 一式の 1 つか
  static bool isShapefilePart(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.shp.xml') || shapefileExtensions.contains(p.extension(lower));
  }

  /// 名前の「拡張子より前」。shp 一式を同じ名前でそろえて扱うための鍵（`林班.shp.xml` → `林班`）
  static String stemOf(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.shp.xml')) return name.substring(0, name.length - '.shp.xml'.length);
    final ext = p.extension(name);
    return ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  }

  /// [names] を、[existing]（dir にもうある名前）とぶつからない名前に付け替える。元の名前 → 新しい名前。
  ///
  /// 同じ stem のもの（shp と付属ファイル）はまとめて同じ番号を振る（`林班_1.shp` と `林班_1.dbf`）。
  /// 片方だけ付け替えると一式としてつながらない。大文字小文字だけ違う名前もぶつかるとみなす（Drive・Windows で重なる）。
  /// 同じ名前が 2 度来たら後のものは捨てる
  static Map<String, String> planNames(Iterable<String> names, Iterable<String> existing) {
    final taken = {for (final n in existing) n.toLowerCase()};
    // shp 一式の stem。`林班.prj` だけが残っている dir に `林班.shp` を入れると、残っていた .prj まで一式に混ざる。
    // 付属ファイルだけ（.shp を含まない）なら、あとから足りない分を足す使い方なので既存の一式に加える
    final shpStems = {
      for (final n in existing)
        if (isShapefilePart(n)) stemOf(n).toLowerCase(),
    };
    final groups = <String, List<String>>{};
    final seen = <String>{};
    for (final n in names) {
      if (!seen.add(n.toLowerCase())) continue;
      groups.putIfAbsent(stemOf(n).toLowerCase(), () => []).add(n);
    }
    final out = <String, String>{};
    for (final members in groups.values) {
      for (var i = 0;; i++) {
        final suffix = i == 0 ? '' : '_$i';
        final renamed = {
          for (final n in members) n: '${stemOf(n)}$suffix${n.substring(stemOf(n).length)}',
        };
        if (renamed.values.any((r) => taken.contains(r.toLowerCase()))) continue;
        if (members.any((m) => m.toLowerCase().endsWith('.shp')) && shpStems.contains('${stemOf(members.first)}$suffix'.toLowerCase())) continue;
        out.addAll(renamed);
        taken.addAll(renamed.values.map((r) => r.toLowerCase()));
        shpStems.addAll([
          for (final r in renamed.values)
            if (isShapefilePart(r)) stemOf(r).toLowerCase(),
        ]);
        break;
      }
    }
    return out;
  }

  /// `.shp` があるのに `.dbf` か `.shx` が一緒に無いものの名前
  static List<String> shpMissingSidecars(Iterable<String> names) {
    final lower = {for (final n in names) n.toLowerCase()};
    return [
      for (final n in names)
        if (n.toLowerCase().endsWith('.shp'))
          if (shpRequiredSidecars.any((ext) => !lower.contains('${stemOf(n).toLowerCase()}$ext'))) n,
    ];
  }

  /// [files] を [dirPath] に写す。名前がぶつかれば付け替える（[planNames]）。1 つ失敗しても残りは続ける
  static Future<AddFilesResult> addTo(String dirPath, List<IncomingFile> files) async {
    final added = <String>[];
    final failed = <({String name, Object error})>[];
    final usable = <IncomingFile>[];
    for (final f in files) {
      // 手元のパスにできない名前（`/`・`..` 入り）は書かない
      if (isSafePathSegment(f.name)) {
        usable.add(f);
      } else {
        failed.add((name: f.name, error: UnsafePathException(f.name)));
      }
    }
    if (usable.isEmpty) return AddFilesResult(added: added, failed: failed);

    await fs.createDirectory(dirPath);
    final existing = [for (final e in await fs.list(dirPath)) e.name];
    final plan = planNames(usable.map((f) => f.name), existing);
    for (final f in usable) {
      final dest = plan[f.name];
      if (dest == null) continue; // 同じ名前が 2 度
      try {
        await fs.writeAsBytes(p.join(dirPath, dest), await f.read());
        added.add(dest);
      } on Object catch (e) {
        failed.add((name: f.name, error: e));
      }
    }
    return AddFilesResult(added: added, failed: failed);
  }
}
