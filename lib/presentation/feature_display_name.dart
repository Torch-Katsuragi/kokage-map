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
// こかげマップ: 地物を人に見せるときの名前（情報パネル・検索の結果・案内の見出し）
//
// [FeatureNode.name] は `name` 列の値で、列の無いレイヤでは「名前なし」になる。QGIS で作った
// gpkg には `name` 列が無いことが多い（2026-10-12 に小班のレイヤで「名前なし」が並んだ）。
// QGIS の「表示名」の式 → ラベルの式 → `name` 列の順に探し、無ければ null を返す。

import 'dart:typed_data';

import '../models/nodes/feature_node.dart';
import '../screens/layer_style_settings_screen.dart' show layerStyleSettings, labelPropertyDef;
import '../utils/attribute_columns.dart';
import '../utils/label_expression.dart';
import '../utils/label_template.dart';

/// QGIS の表示名の式で作った名前。式が無い・値が入らなければ null。
///
/// 式が列 1 つ（`"林小班"`）だけなら null（その列は属性の行にそのまま出ている）
String? featureQgisDisplayName(FeatureNode f) {
  if (f.isDisposed || f.parent.isDisposed) return null;
  final expr = f.parent.displayExpression;
  if (expr == null) return null;
  final normalized = normalizeLabelExpression(expr);
  if (normalized == null || tryParseLabelExpression(normalized) is FieldRef) return null;
  return renderLabelTemplate(expr, f.parent.effectiveProperties(f.turfFeature.properties));
}

/// 地物の表示名: QGIS の表示名の式 → ラベルの式 → `name` 列。どれも値が無ければ null
String? featureDisplayName(FeatureNode f) {
  if (f.isDisposed || f.parent.isDisposed) return null;
  final layer = f.parent;
  final props = layer.effectiveProperties(f.turfFeature.properties);
  final kmeta = layer.styleGroups[layer.styleKeyOf(f.rowId)] ?? layer.kmetaStyleIfLoaded;
  for (final expr in [layer.displayExpression, layerStyleSettings.resolveString(labelPropertyDef, kmeta), 'name']) {
    if (expr == null) continue;
    final name = renderLabelTemplate(expr, props);
    if (name != null) return name;
  }
  return null;
}

/// 地物を見分ける短い文字。表示名（[featureDisplayName]）が [exclude] 以外の値で取れればそれ、
/// 無ければ [excludeColumn] 以外の列を [maxFields] 個まで「列: 値」で（文字の列を先に）。
/// 何も取れなければ null（「名前なし」は出さない）
String? featureIdentifier(FeatureNode f, {String? excludeColumn, String? exclude, int maxFields = 2}) {
  if (f.isDisposed || f.parent.isDisposed) return null;
  final name = featureDisplayName(f);
  if (name != null && name != exclude) return name;
  final texts = <String>[];
  final others = <String>[];
  for (final MapEntry(:key, :value) in (f.turfFeature.properties ?? const <String, dynamic>{}).entries) {
    if (key == excludeColumn || key.toLowerCase() == 'fid' || isSystemColumn(key) || isInternalColumn(key)) continue;
    if (value == null || value is Uint8List || value is List || value is Map) continue;
    final s = value.toString().trim();
    if (s.isEmpty) continue;
    (value is String ? texts : others).add('$key: $s');
  }
  final picked = [...texts, ...others].take(maxFields).toList();
  return picked.isEmpty ? null : picked.join(' / ');
}
