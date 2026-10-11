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
// 形の無い表（座標の列が無い CSV。森林簿など）のノード。読み取り専用で、レイヤに結合して使う。
// 設計は docs/technical/qgis-interop.md#表の結合（森林簿 CSV と計画図）

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/node_types.dart';
import '../../services/table/csv_table.dart';
import '../../services/table/table_join.dart';
import '../../utils/app_logger.dart';
import 'layer_tree_node.dart';

/// 表にする拡張子（同梱の GDAL に XLSX のドライバは無いので CSV だけ）
const tableExtensions = {'.csv'};

/// 表のファイル 1 本 ＝ 1 ノード。形が無いので地図には描かない（可視性も持たない）
class TableNode extends LayerTreeNode {
  TableNode(this.sourcePath, {super.parent}) : super(p.basename(sourcePath), nodeType: NodeType.table);

  /// 元のファイル
  final String sourcePath;

  /// QGIS のレイヤ名（ファイル名から拡張子を除いたもの。結合の既定の接頭辞にもなる）
  String get tableName => p.basenameWithoutExtension(sourcePath);

  @override
  String? getAbsoluteFilePath() => sourcePath;

  /// 中身（変わっていなければ控え）。読めなければ null
  Future<CsvTable?> load() => TableCache.load(sourcePath);

  @override
  Future<void> updateChildren() async {}

  @override
  Future<void> persistVisibility() async {}

  /// 利用者が消したとき: ファイルを消す
  @override
  Future<void> dispose() async {
    try {
      await fs.delete(sourcePath);
    } catch (e) {
      AppLogger.debug('[TableNode] 消せない: $sourcePath - $e');
    }
    await super.dispose();
  }
}
