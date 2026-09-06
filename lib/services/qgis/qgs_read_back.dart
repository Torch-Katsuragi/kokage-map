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
// こかげマップ: QGIS 側で編集された `.qgs` をプロジェクトを開いたときに読み戻す
//
// 印（`kokage/savedAt`）と root の `saveDateTime` が食い違っていれば、
// 最後に書いたのはこかげマップではない＝QGIS（か人）が保存した。そのときだけ
// 寛容インポータで View・スタイル・可視性を取り込み、続く自動更新で
// 正規化＋印つきの `.qgs` に書き戻す。
//
// 印が一致していれば何もしない（自分が書いたものを読み直す意味は無い）。
// 印が無い `.qgs` は他人のファイルとして読む（旧 `project.qgs` を含む）。

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/nodes/folder_node.dart';
import '../../utils/app_logger.dart';
import 'qgs_auto_refresh.dart';
import 'qgs_document.dart';
import 'qgs_importer.dart';
import 'qgs_writer.dart';

/// 読み戻した結果。何もしなかったときは [QgsReadBack.run] が null を返す
class QgsReadBackResult {
  const QgsReadBackResult({
    required this.fileName,
    required this.importedViewCount,
    required this.discarded,
  });

  final String fileName;
  final int importedViewCount;
  final List<String> discarded;
}

class QgsReadBack {
  const QgsReadBack();

  /// [root] の `<dir名>.qgs`（無ければ旧 `project.qgs`）を見て、QGIS 側で保存されていれば取り込む。
  ///
  /// ツリーの子（gpkg とレイヤ）が読み込まれてから呼ぶこと。
  Future<QgsReadBackResult?> run(FolderNode root) async {
    // まだ `.qgs` が無いプロジェクトは、開いた時点で最初の1本を作っておく
    // （手動の書き出しメニューは撤去したので、ここが唯一の入口）
    final rootPath = root.getAbsoluteFilePath();
    if (rootPath != null && await _findProjectFile(rootPath) == null) {
      QgsAutoRefresh.instance.schedule(rootPath);
    }

    final results = <QgsReadBackResult>[];
    await _runTree(root, results);
    if (results.isEmpty) return null;
    return QgsReadBackResult(
      fileName: results.map((r) => r.fileName).join(', '),
      importedViewCount: results.fold(0, (s, r) => s + r.importedViewCount),
      discarded: [for (final r in results) ...r.discarded],
    );
  }

  /// root と、独立した `.qgs` を持つ子 dir を順に見る
  Future<void> _runTree(FolderNode folder, List<QgsReadBackResult> out) async {
    final one = await _runOne(folder);
    if (one != null) out.add(one);
    for (final child in folder.children.whereType<FolderNode>()) {
      await _runTree(child, out);
    }
  }

  /// `<dir名>.qgs`、無ければ旧 `project.qgs`。どちらも無ければ null
  Future<String?> _findProjectFile(String dirPath) async {
    final dirName = p.basename(p.normalize(dirPath));
    for (final c in [
      p.join(dirPath, qgsFileNameFor(dirName)),
      p.join(dirPath, kLegacyQgsFileName),
    ]) {
      if (await fs.exists(c)) return c;
    }
    return null;
  }

  Future<QgsReadBackResult?> _runOne(FolderNode root) async {
    final rootPath = root.getAbsoluteFilePath();
    if (rootPath == null) return null;

    final path = await _findProjectFile(rootPath);
    if (path == null) return null;

    final String xml;
    try {
      xml = await fs.readAsString(path);
    } on Object catch (e) {
      AppLogger.debug('[QgsReadBack] 読めない: $e');
      return null;
    }

    QgsDocument doc;
    try {
      doc = QgsDocument.parse(xml);
    } on Object catch (e) {
      AppLogger.debug('[QgsReadBack] XML として読めない（自動更新で退避される）: $e');
      return null;
    }

    if (doc.lastWrittenByKokage) {
      AppLogger.debug('[QgsReadBack] ${p.basename(path)} は自分が書いたもの。読み戻し不要');
      return null;
    }

    AppLogger.debug(
      '[QgsReadBack] ${p.basename(path)} は QGIS 側で保存されている'
      '（saveDateTime=${doc.root.getAttribute('saveDateTime')} '
      'savedAt=${doc.stamp?.savedAtText}）。取り込む',
    );
    final result = await const QgsImporter().import(path, root);

    // 取り込んだ結果（と正規化）を印つきで書き戻す
    QgsAutoRefresh.instance.schedule(rootPath);

    return QgsReadBackResult(
      fileName: p.basename(path),
      importedViewCount: result.importedViewCount,
      discarded: result.discarded,
    );
  }
}
