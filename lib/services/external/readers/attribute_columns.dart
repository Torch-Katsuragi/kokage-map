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
// 文字列だけの属性（KML・CSV）に列の型を付ける

/// [ExternalDataset.features] で形を入れるキー。属性の列名がこれと重なったら付け替える
const _geometryKeys = {'point', 'line', 'rings'};

/// 属性の列名として使える名前（空なら `field`、形のキーと重なれば `_1` を足す）
String attributeColumnName(String name) {
  final n = name.trim().isEmpty ? 'field' : name.trim();
  return _geometryKeys.contains(n.toLowerCase()) ? '${n}_1' : n;
}

/// 文字列を数として読む。読めない・有限でない・先頭が 0 の整数（`012` のような番号）は null
double? _asNumber(String s) {
  final t = s.trim();
  if (RegExp(r'^[+-]?0\d').hasMatch(t)) return null;
  final v = double.tryParse(t);
  return v != null && v.isFinite ? v : null;
}

/// [rows]（列名 → 文字列）の列に型を付ける。空でない値がすべて数なら `REAL`（値は double）、それ以外は `TEXT`。
/// 空・null の値はキーごと落とす。列の並びは [order]
({Map<String, String> columns, List<Map<String, Object>> rows}) typeAttributeColumns(
  List<String> order,
  List<Map<String, String?>> rows,
) {
  final columns = <String, String>{};
  for (final name in order) {
    var any = false;
    var numeric = true;
    for (final row in rows) {
      final v = row[name];
      if (v == null || v.trim().isEmpty) continue;
      any = true;
      if (_asNumber(v) == null) {
        numeric = false;
        break;
      }
    }
    columns[name] = any && numeric ? 'REAL' : 'TEXT';
  }
  final typed = [
    for (final row in rows)
      {
        for (final MapEntry(:key, :value) in row.entries)
          if (value != null && value.trim().isNotEmpty && columns.containsKey(key))
            key: columns[key] == 'REAL' ? _asNumber(value)! : value,
      },
  ];
  return (columns: columns, rows: typed);
}
