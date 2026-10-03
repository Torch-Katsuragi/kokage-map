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
// こかげマップ: プロジェクトの置き場所（ホームの「新しく作る」「続きから」「一覧」）
//
// 置き場所は Global の親（Android は Documents/KokageMap）。1 プロジェクト 1 フォルダで、
// Global と練習用フォルダは一覧に出さない。置き場所の外のフォルダも「ほかの場所を開く」で開ける（2026-10-03）。

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fs/k_file_system.dart';
import '../i18n/strings.g.dart';
import 'global_folder_locator.dart';
import 'kmeta_service.dart';

/// 置き場所の中のプロジェクト 1 つ
class ProjectEntry {
  const ProjectEntry({required this.path, required this.name, required this.modified, required this.driveLinked});

  final String path;
  final String name;
  final DateTime modified;

  /// Drive と同期しているフォルダ
  final bool driveLinked;
}

class ProjectsHome {
  ProjectsHome._();

  static const _lastKey = 'last_project_dir';

  /// プロジェクトごとの最後に開いた時刻（ミリ秒）。フォルダの更新時刻は中のファイルを書いても変わらないので自分で持つ
  static const _openedKey = 'project_opened_at';

  /// 置き場所（無ければ作る）
  static Future<String> root() async {
    final dir = p.dirname(await GlobalFolderLocator.defaultPath());
    if (!await fs.exists(dir)) await fs.createDirectory(dir);
    return dir;
  }

  /// 一覧に出さない名前（Global・練習用・隠しフォルダ）
  static bool _hidden(String name) =>
      name.startsWith('.') || name == GlobalFolderLocator.sharedRelativeSegments.last || name == t.tutorial.practice.folder;

  /// 置き場所の中のプロジェクト。新しく触ったものから
  static Future<List<ProjectEntry>> list() async {
    final dir = await root();
    final prefs = await SharedPreferences.getInstance();
    final opened = _decode(prefs.getString(_openedKey));
    final out = <ProjectEntry>[];
    for (final e in await fs.list(dir)) {
      if (!e.isDirectory || _hidden(e.name)) continue;
      final path = e.path;
      final name = e.name;
      DateTime modified;
      final at = opened[path];
      if (at != null) {
        modified = DateTime.fromMillisecondsSinceEpoch(at);
      } else {
        try {
          modified = await fs.lastModified(path) ?? DateTime.fromMillisecondsSinceEpoch(0);
        } catch (_) {
          modified = DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
      var linked = false;
      try {
        linked = (await KMetaService.instance.getMeta(path)).sync.driveId != null;
      } catch (_) {}
      out.add(ProjectEntry(path: path, name: name, modified: modified, driveLinked: linked));
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// 置き場所に [name] のフォルダを作ってそのパスを返す。同じ名前があれば「名前 2」のように避ける
  static Future<String> create(String name) async {
    final dir = await root();
    final base = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var candidate = p.join(dir, base);
    for (var n = 2; await fs.exists(candidate); n++) {
      candidate = p.join(dir, '$base $n');
    }
    await fs.createDirectory(candidate);
    return candidate;
  }

  /// 最後に開いたプロジェクト（練習用は覚えない）
  static Future<void> remember(String path) async {
    if (p.basename(path) == t.tutorial.practice.folder) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastKey, path);
    final opened = _decode(prefs.getString(_openedKey))..[path] = DateTime.now().millisecondsSinceEpoch;
    await prefs.setString(_openedKey, jsonEncode(opened));
  }

  static Map<String, int> _decode(String? s) {
    if (s == null) return {};
    try {
      return (jsonDecode(s) as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// 最後に開いたプロジェクト。消えていれば null
  static Future<String?> last() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_lastKey);
    if (path == null || !await fs.exists(path)) return null;
    return path;
  }
}
