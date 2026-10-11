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
// こかげマップ: 属性フォームの選択肢を集める（UniqueValues はレイヤの既存の値、
// ValueRelation は参照先のレイヤの キー・値 の組をフィルタの式で絞ったもの）

import 'package:path/path.dart' as p;

import '../models/nodes/external_layer_node.dart';
import '../models/nodes/geopackage_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/qgis_form.dart';
import '../utils/app_logger.dart';
import '../utils/qgis_expression.dart';

class QgisFormOptions {
  const QgisFormOptions._();

  /// 列 → 選択肢。UniqueValues と ValueRelation の列だけ（参照先が見つからない列は入れない）
  static Future<Map<String, List<QgisValueOption>>> load(LayerNode layer, QgisForm form) async {
    final out = <String, List<QgisValueOption>>{};
    final columns = (await layer.getAttributeColumnNames(getAll: true)).toSet();
    for (final field in form.fields.values) {
      if (!columns.contains(field.name)) continue; // QGIS 側にだけある列（式の仮想列など）
      try {
        switch (field.kind) {
          case QgisWidgetKind.uniqueValues:
            out[field.name] = await _uniqueValues(layer, field.name);
          case QgisWidgetKind.valueRelation:
            final opts = await _relation(layer, field);
            if (opts != null) out[field.name] = opts;
          default:
        }
      } on Object catch (e) {
        AppLogger.debug('[QgisFormOptions] ${field.name} の選択肢を集められない: $e');
      }
    }
    return out;
  }

  static Future<List<QgisValueOption>> _uniqueValues(LayerNode layer, String column) async {
    final rows = await layer.geoPackageFile.getAllFeatureAttributes(layer.layerName, columns: [column]);
    final seen = <String>{};
    for (final r in rows) {
      final v = r[column];
      if (v == null || '$v'.isEmpty) continue;
      seen.add('$v');
    }
    final sorted = seen.toList()..sort();
    return [for (final v in sorted) QgisValueOption(v, v)];
  }

  static Future<List<QgisValueOption>?> _relation(LayerNode layer, QgisFieldForm field) async {
    final target = field.relationTarget;
    final key = field.relationKey;
    final value = field.relationValue;
    final folderPath = layer.folderNode?.getAbsoluteFilePath();
    if (target == null || key == null || value == null || folderPath == null) return null;
    final gpkgPath = p.normalize(p.join(folderPath, target.gpkg));
    final ref = _findLayer(_root(layer), gpkgPath, target.layer);
    if (ref == null) {
      AppLogger.debug('[QgisFormOptions] 値の関係の参照先が無い: ${target.gpkg}/${target.layer}');
      return null;
    }
    final rows = await ref.geoPackageFile.getAllFeatureAttributes(ref.layerName);
    final filterSrc = field.relationFilter;
    final filter = filterSrc == null ? null : tryParseQgisExpression(filterSrc);
    if (filterSrc != null && filter == null) {
      AppLogger.debug('[QgisFormOptions] 値の関係のフィルタを読めないので絞らない: $filterSrc');
    }
    final opts = <QgisValueOption>[];
    final seen = <String>{};
    for (final r in rows) {
      if (filter != null && !filter.test(r)) continue;
      final k = r[key];
      if (k == null || !seen.add('$k')) continue;
      opts.add(QgisValueOption('$k', '${r[value] ?? k}'));
    }
    if (field.relationOrderByValue) opts.sort((a, b) => a.label.compareTo(b.label));
    return opts;
  }

  static LayerTreeNode _root(LayerTreeNode n) {
    var cur = n;
    while (cur.parent != null) {
      cur = cur.parent!;
    }
    return cur;
  }

  static LayerNode? _findLayer(LayerTreeNode node, String gpkgPath, String layerName) {
    if (node is GeoPackageNode) {
      final abs = node is ExternalLayerNode ? node.sourcePath : node.geoPackageFile.getAbsolutePath();
      if (abs != null && p.normalize(abs) == gpkgPath) {
        return node.children.whereType<LayerNode>().where((l) => l.layerName == layerName).firstOrNull;
      }
      return null;
    }
    for (final c in node.children) {
      final hit = _findLayer(c, gpkgPath, layerName);
      if (hit != null) return hit;
    }
    return null;
  }
}
