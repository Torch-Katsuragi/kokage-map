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
// 結合の評価。表を一度だけ「結合の値 → 行」の Map にして、地物ごとには引くだけにする（1 万 × 1 万でも一瞬）。
// 設計は docs/technical/qgis-interop.md#表の結合（森林簿 CSV と計画図）

import '../../core/fs/k_file_system.dart';
import '../../models/layer_join.dart';
import '../../utils/app_logger.dart';
import 'csv_table.dart';

/// 結合の値を照合の鍵にする。QGIS と同じく **値の文字の形** で比べる（整数 12 と文字 "12" は当たる。
/// QGIS の結合の記憶は `QVariant::toString()` を鍵にする）。NULL は当たらない
String? joinKey(Object? value, {bool normalize = false}) {
  if (value == null) return null;
  String s;
  if (value is double) {
    s = value.isFinite && value == value.truncateToDouble() ? value.toInt().toString() : value.toString();
  } else {
    s = value.toString();
  }
  return normalize ? normalizeJoinKey(s) : s;
}

/// 全角の英数字・記号・空白を半角にし、前後の空白を落とす（林班「１２」→「12」）
String normalizeJoinKey(String s) {
  final out = StringBuffer();
  for (final c in s.runes) {
    if (c >= 0xFF01 && c <= 0xFF5E) {
      out.writeCharCode(c - 0xFEE0);
    } else if (c == 0x3000) {
      out.writeCharCode(0x20);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString().trim();
}

/// 引ける形にした結合 1 本
class ResolvedJoin {
  ResolvedJoin._(this.join, this.table, this.fieldNames, this._columns, this._rowByKey);

  /// [join] を [table] に当てて、鍵 → 行の Map を作る。表に結合の列が無ければ null
  static ResolvedJoin? build(LayerJoin join, CsvTable table, {Set<String> existingFields = const {}}) {
    final joinIndex = table.indexOf(join.joinField);
    if (joinIndex < 0) return null;
    final names = <String>[];
    final columns = <int>[];
    final taken = {...existingFields};
    for (var i = 0; i < table.fields.length; i++) {
      final name = table.fields[i].name;
      // 結合の列そのものは足さない（QGIS と同じ）
      if (i == joinIndex) continue;
      if (join.fields != null && !join.fields!.contains(name)) continue;
      final out = '${join.effectivePrefix}$name';
      // 既にある名前は足さない（QGIS も同名の列は足せない）
      if (!taken.add(out)) continue;
      names.add(out);
      columns.add(i);
    }
    final byKey = <String, int>{};
    for (var r = 0; r < table.rows.length; r++) {
      final key = joinKey(table.rows[r][joinIndex], normalize: join.normalize);
      if (key == null) continue;
      // 同じ値の行が複数あれば、QGIS の記憶あり（既定）は最後の行、記憶なしは最初の行
      if (join.memoryCache || !byKey.containsKey(key)) byKey[key] = r;
    }
    return ResolvedJoin._(join, table, names, columns, byKey);
  }

  final LayerJoin join;
  final CsvTable table;

  /// 足す列の名前（接頭辞つき）
  final List<String> fieldNames;
  final List<int> _columns;
  final Map<String, int> _rowByKey;

  /// 結合の列の値 [target] に当たる行の、足す列の値（[fieldNames] の順）。当たらなければ null
  List<Object?>? valuesFor(Object? target) {
    final key = joinKey(target, normalize: join.normalize);
    final row = key == null ? null : _rowByKey[key];
    if (row == null) return null;
    final values = table.rows[row];
    return [for (final c in _columns) values[c]];
  }

  /// 足す列の型（[fieldNames] の順）
  List<TableFieldType> get fieldTypes => [for (final c in _columns) table.fields[c].type];
}

/// 地物の属性に結合の値を足す。[joins] が空なら [props] をそのまま返す
Map<String, Object?>? withJoinedValues(Map<String, dynamic>? props, List<ResolvedJoin> joins) {
  if (joins.isEmpty) return props;
  final out = <String, Object?>{...?props};
  for (final j in joins) {
    final values = j.valuesFor(props?[j.join.targetField]);
    for (var i = 0; i < j.fieldNames.length; i++) {
      out[j.fieldNames[i]] = values?[i];
    }
  }
  return out;
}

/// 読んだ表の控え（パス → 更新時刻・大きさ・中身）。同じ表を結ぶレイヤが何枚あっても 1 回だけ読む
class TableCache {
  TableCache._();

  static final Map<String, ({DateTime? modified, int? size, CsvTable table})> _cache = {};

  /// [path] の表を読む（変わっていなければ控え）。読めなければ null
  static Future<CsvTable?> load(String path) async {
    try {
      if (!await fs.exists(path)) return null;
      final modified = await fs.lastModified(path);
      final size = await fs.length(path);
      final cached = _cache[path];
      if (cached != null && cached.modified == modified && cached.size == size) return cached.table;
      final table = CsvTable.parse(await fs.readAsBytes(path));
      _cache[path] = (modified: modified, size: size, table: table);
      return table;
    } catch (e) {
      AppLogger.debug('[TableCache] 読めない: $path - $e');
      return null;
    }
  }

  static void clear() => _cache.clear();
}
