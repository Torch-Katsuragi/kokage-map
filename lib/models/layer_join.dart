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
// レイヤに表（森林簿 CSV など）を結ぶ設定。QGIS のレイヤのプロパティ →「結合」（`.qgs` の `<vectorjoins>`）と同じもの。
// 設計は docs/technical/qgis-interop.md#表の結合（森林簿 CSV と計画図）

import 'package:path/path.dart' as p;

/// 1 本の結合（QGIS の `QgsVectorLayerJoinInfo`）
class LayerJoin {
  const LayerJoin({
    required this.table,
    required this.joinField,
    required this.targetField,
    this.fields,
    this.prefix,
    this.memoryCache = true,
    this.normalize = false,
  });

  /// 結ぶ表のファイル（レイヤのある dir からの相対パス、`/` 区切り。例 `森林簿.csv`）
  final String table;

  /// 表の側の列（QGIS の joinFieldName）
  final String joinField;

  /// レイヤの側の列（QGIS の targetFieldName）
  final String targetField;

  /// 足す列（QGIS の joinFieldsSubset）。null なら結合の列を除く全部（QGIS と同じ）
  final List<String>? fields;

  /// 列名の接頭辞（QGIS の customPrefix）。null なら既定の `<表の名前>_`
  final String? prefix;

  /// QGIS の memoryCache（表を記憶に載せる）。同じ値の行が複数あると、QGIS は記憶に載せると最後の行、
  /// 載せないと最初の行を使う。アプリは常に記憶に載せて引くので、この値は当たる行の選び方と `.qgs` の往復に使う
  final bool memoryCache;

  /// 全角・半角と前後の空白をそろえて照合する（アプリだけの設定。QGIS は常に完全一致なので、
  /// これを付けた結合は QGIS では当たらない行が出うる）
  final bool normalize;

  /// 表の名前（QGIS のレイヤ名。ファイル名から拡張子を除いたもの）
  String get tableName => p.basenameWithoutExtension(table);

  /// 実際の接頭辞
  String get effectivePrefix => prefix ?? '${tableName}_';

  /// 同じ表・同じ列の組か（一覧で 1 本を指すとき）
  bool sameLink(LayerJoin other) =>
      other.table == table && other.joinField == joinField && other.targetField == targetField;

  LayerJoin copyWith({List<String>? fields, String? prefix, bool clearPrefix = false, bool? normalize}) => LayerJoin(
    table: table,
    joinField: joinField,
    targetField: targetField,
    fields: fields ?? this.fields,
    prefix: clearPrefix ? null : (prefix ?? this.prefix),
    memoryCache: memoryCache,
    normalize: normalize ?? this.normalize,
  );

  Map<String, Object?> toJson() => {
    'table': table,
    'joinField': joinField,
    'targetField': targetField,
    if (fields != null) 'fields': fields,
    if (prefix != null) 'prefix': prefix,
    if (!memoryCache) 'memoryCache': false,
    if (normalize) 'normalize': true,
  };

  static LayerJoin? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final table = json['table'];
    final joinField = json['joinField'];
    final targetField = json['targetField'];
    if (table is! String || joinField is! String || targetField is! String) return null;
    final fields = json['fields'];
    return LayerJoin(
      table: table,
      joinField: joinField,
      targetField: targetField,
      fields: fields is List ? [for (final f in fields) '$f'] : null,
      prefix: json['prefix'] as String?,
      memoryCache: json['memoryCache'] != false,
      normalize: json['normalize'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LayerJoin &&
      sameLink(other) &&
      other.prefix == prefix &&
      other.memoryCache == memoryCache &&
      other.normalize == normalize &&
      _listEquals(other.fields, fields);

  @override
  int get hashCode => Object.hash(table, joinField, targetField, prefix, memoryCache, normalize, fields?.join('\u0000'));

  static bool _listEquals(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
