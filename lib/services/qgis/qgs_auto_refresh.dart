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
// こかげマップ: メタデータが変わるたびに `<dir名>.qgs` を追従させる
//
// 正典を `.qgs` に移す途中経過（段1と段2の間）。まだ `.kmeta.json` が正典だが、
// 保存のたびにプロジェクト root の `.qgs` を DOM 保持型で更新しておけば、
// QGIS 側から見える状態が常に最新になる。
//
// > [!NOTE] 書くのは root の `.qgs` 1本だけ
// > 子 dir ごとの `.qgs`（埋め込み）は段4。いまの [QgsProjectBuilder] は
// > root から全ツリーを1本に書く。
//
// > [!IMPORTANT] Drive push の前に [flushNow] を呼ぶこと
// > push はディスクのファイルを読んで上げる。デバウンス待ちのまま push すると
// > 古い `.qgs` が飛ぶ。

import 'dart:async';

import '../../models/nodes/folder_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../utils/app_logger.dart';
import 'qgs_project_builder.dart';

class QgsAutoRefresh {
  QgsAutoRefresh._();

  static final QgsAutoRefresh instance = QgsAutoRefresh._();

  /// 変更が落ち着いてから書くまでの間隔
  static const Duration debounce = Duration(seconds: 3);

  /// プロジェクト root を返す。未オープンなら null。アプリ起動時に配線する
  LayerTreeNode? Function()? rootGetter;

  /// 自動更新を止めたいとき（テスト・大量操作中）
  bool enabled = true;

  Timer? _timer;
  bool _dirty = false;
  Future<void>? _running;

  /// メタデータが保存されたときに呼ぶ。デバウンスして書く。
  ///
  /// [folderPath] は保存された dir。root 配下でなければ（Global 等）無視する。
  void schedule(String folderPath) {
    if (!enabled) return;
    final root = _rootFolder();
    if (root == null) return;
    final rootPath = root.getAbsoluteFilePath();
    if (rootPath == null || !_isUnder(folderPath, rootPath)) return;

    _dirty = true;
    _timer?.cancel();
    _timer = Timer(debounce, _run);
  }

  /// 待ちがあれば今すぐ書き切る（Drive push・書き出しの前）。
  Future<void> flushNow() async {
    _timer?.cancel();
    _timer = null;
    if (_dirty) await _run();
    await _running;
  }

  Future<void> _run() async {
    // 走行中なら終わってから、その時点の dirty で再判定
    if (_running != null) {
      await _running;
      if (!_dirty) return;
    }
    _dirty = false;
    final root = _rootFolder();
    if (root == null) return;

    final task = _write(root);
    _running = task;
    try {
      await task;
    } finally {
      _running = null;
    }
    if (_dirty) unawaited(_run());
  }

  Future<void> _write(FolderNode root) async {
    try {
      final result = await const QgsProjectBuilder().writeTo(root);
      if (result == null) return;
      AppLogger.debug(
        '[QgsAutoRefresh] ${result.path} を更新'
        '（外した ${result.removedLayers.length} 件・触らなかったレンダラ ${result.untouchedRenderers.length} 件）',
      );
    } on Object catch (e) {
      // 自動更新は黙って失敗してよい（手動の書き出しで再現できる）
      AppLogger.debug('[QgsAutoRefresh] 更新に失敗: $e');
    }
  }

  FolderNode? _rootFolder() {
    final node = rootGetter?.call();
    return node is FolderNode ? node : null;
  }

  static bool _isUnder(String path, String root) {
    String norm(String s) => s.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final a = norm(path);
    final b = norm(root);
    return a == b || a.startsWith('$b/');
  }
}
