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
// 座標列のある CSV の読み手（設計は docs/technical/external-formats.md）

import 'dart:convert';

import 'package:charset/charset.dart' as charset;
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../../../core/fs/k_file_system.dart';
import '../../../models/geometry_type.dart';
import '../external_dataset.dart';
import 'attribute_columns.dart';

/// CSV の形を持つ列（`.qgs` の delimitedtext URI の `xField` / `yField` / `wktField` に書く名前）。
/// 緯度経度の列か WKT の列のどちらか
@immutable
class CsvGeometryColumns {
  const CsvGeometryColumns.xy({required String this.xField, required String this.yField}) : wktField = null;

  const CsvGeometryColumns.wkt(String this.wktField) : xField = null, yField = null;

  /// 経度の列（見出しのとおりの綴り）
  final String? xField;

  /// 緯度の列
  final String? yField;

  /// WKT の列
  final String? wktField;

  @override
  bool operator ==(Object other) =>
      other is CsvGeometryColumns && other.xField == xField && other.yField == yField && other.wktField == wktField;

  @override
  int get hashCode => Object.hash(xField, yField, wktField);

  @override
  String toString() => wktField != null ? 'CsvGeometryColumns(wkt: $wktField)' : 'CsvGeometryColumns($xField, $yField)';
}

/// 座標列のある CSV を点（WKT なら線・面も）のレイヤとして読む。
///
/// - 文字コードは UTF-8（BOM は外す）、UTF-8 として読めなければ Shift_JIS
/// - 区切りはカンマ。`"` で囲んだ値の中のカンマ・改行・`""` を扱う
/// - 座標は WGS84 の緯度経度だけ。投影座標（絶対値が 180 を超える）は [accepts] で断る
/// - 属性は WKT の列以外すべて（緯度経度の列も残す。QGIS と同じ）。型は数だけなら REAL、それ以外 TEXT
class CsvReader extends ExternalReader {
  @override
  Set<String> get extensions => const {'.csv'};

  /// accepts で値を確かめる行数
  static const _sampleRows = 100;

  @override
  Future<bool> accepts(String path) async {
    try {
      final table = parseCsv(decodeCsvBytes(await fs.readAsBytes(path)).text);
      if (table.isEmpty) return false;
      final columns = _detect(table.first);
      if (columns == null) return false;
      final sample = table.skip(1).take(_sampleRows).toList();
      final index = _indices(table.first, columns);
      var valid = 0;
      for (final row in sample) {
        final geometry = _geometryOf(row, index);
        if (geometry == _outOfRange) return false;
        if (geometry != null) valid++;
      }
      // 見出しだけなら空のレイヤとして受ける。行があるのに 1 つも読めなければ座標列ではない
      return sample.isEmpty || valid > 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<ExternalDataset>> read(String path) async {
    final table = parseCsv(decodeCsvBytes(await fs.readAsBytes(path)).text);
    if (table.isEmpty) throw const FormatException('CSV が空です');
    final header = table.first;
    final columns = _detect(header);
    if (columns == null) throw const FormatException('CSV に座標の列が見つかりません');
    final index = _indices(header, columns);

    // 属性の列（WKT の列は形にするので除く）。同じ見出しが重なれば _2 …
    final attrColumns = <(int, String)>[];
    final used = <String>{};
    for (final (i, raw) in header.indexed) {
      if (i == index.wkt) continue;
      final base = attributeColumnName(raw);
      var name = base;
      for (var n = 2; !used.add(name); n++) {
        name = '${base}_$n';
      }
      attrColumns.add((i, name));
    }

    final groups = <GeometryType, List<(Object, Map<String, String?>)>>{};
    for (final row in table.skip(1)) {
      final geometry = _geometryOf(row, index);
      if (geometry == null || geometry == _outOfRange) continue;
      final (type, shape) = geometry as (GeometryType, Object);
      groups.putIfAbsent(type, () => []).add((
        shape,
        {for (final (i, name) in attrColumns) name: row.elementAtOrNull(i)},
      ));
    }
    if (groups.isEmpty) groups[GeometryType.point] = [];

    final fileName = p.basenameWithoutExtension(path);
    final order = [for (final (_, name) in attrColumns) name];
    return [
      for (final MapEntry(key: type, value: features) in groups.entries)
        () {
          final typed = typeAttributeColumns(order, [for (final f in features) f.$2]);
          final geometryKey = _geometryKey(type);
          return ExternalDataset(
            layerName: groups.length == 1 ? fileName : '${fileName}_${_suffix(type)}',
            geometryType: type,
            columns: typed.columns,
            features: [
              for (final (i, f) in features.indexed) {geometryKey: f.$1, ...typed.rows[i]},
            ],
          );
        }(),
    ];
  }

  /// [path] の CSV の形の列と文字コード（`.qgs` の delimitedtext URI を書くとき用）。座標列が無ければ null
  static Future<({CsvGeometryColumns columns, String encoding})?> inspect(String path) async {
    final decoded = decodeCsvBytes(await fs.readAsBytes(path));
    final table = parseCsv(decoded.text);
    final columns = table.isEmpty ? null : _detect(table.first);
    return columns == null ? null : (columns: columns, encoding: decoded.encoding);
  }

  /// 見出しの行（[header] は CSV の 1 行目そのもの）から形の列を推定する。見つからなければ null。
  /// 優先は 緯度経度の名前（lat/latitude/緯度 と lon/lng/longitude/経度）→ WKT（wkt/geometry）→ x/y
  static CsvGeometryColumns? detectColumns(String header) {
    final rows = parseCsv(header);
    return rows.isEmpty ? null : _detect(rows.first);
  }

  static const _latNames = ['lat', 'latitude', '緯度'];
  static const _lonNames = ['lon', 'lng', 'longitude', '経度'];
  static const _wktNames = ['wkt', 'geometry'];

  static CsvGeometryColumns? _detect(List<String> header) {
    String? find(List<String> names) {
      for (final name in names) {
        final hit = header.where((h) => h.trim().toLowerCase() == name).firstOrNull;
        if (hit != null) return hit;
      }
      return null;
    }

    final lat = find(_latNames);
    final lon = find(_lonNames);
    if (lat != null && lon != null) return CsvGeometryColumns.xy(xField: lon, yField: lat);
    final wkt = find(_wktNames);
    if (wkt != null) return CsvGeometryColumns.wkt(wkt);
    final y = find(['y']);
    final x = find(['x']);
    if (x != null && y != null) return CsvGeometryColumns.xy(xField: x, yField: y);
    return null;
  }

  static ({int? x, int? y, int? wkt}) _indices(List<String> header, CsvGeometryColumns c) => (
    x: c.xField == null ? null : header.indexOf(c.xField!),
    y: c.yField == null ? null : header.indexOf(c.yField!),
    wkt: c.wktField == null ? null : header.indexOf(c.wktField!),
  );

  /// 範囲外の座標（投影座標とみなす）の印
  static const _outOfRange = Object();

  /// 行の形。`(GeometryType, 形)`、読めなければ null、範囲外なら [_outOfRange]
  static Object? _geometryOf(List<String> row, ({int? x, int? y, int? wkt}) index) {
    if (index.wkt != null) {
      final text = row.elementAtOrNull(index.wkt!)?.trim() ?? '';
      if (text.isEmpty) return null;
      return _parseWkt(text);
    }
    final x = double.tryParse(row.elementAtOrNull(index.x!)?.trim() ?? '');
    final y = double.tryParse(row.elementAtOrNull(index.y!)?.trim() ?? '');
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    if (x.abs() > 180 || y.abs() > 90) return _outOfRange;
    return (GeometryType.point, LatLng(y, x));
  }

  /// WKT の POINT / LINESTRING / POLYGON（Z・M は捨てる、`SRID=…;` は読み飛ばす）。ほかの型は null
  static Object? _parseWkt(String wkt) {
    final m = RegExp(
      r'^(?:SRID=\d+;)?\s*(POINT|LINESTRING|POLYGON)\s*(?:ZM|Z|M)?\s*\((.*)\)\s*$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(wkt);
    if (m == null) return null;
    var outOfRange = false;
    List<LatLng>? coords(String body) {
      final out = <LatLng>[];
      for (final pair in body.split(',')) {
        final n = pair.trim().split(RegExp(r'\s+'));
        if (n.length < 2) return null;
        final x = double.tryParse(n[0]);
        final y = double.tryParse(n[1]);
        if (x == null || y == null) return null;
        if (x.abs() > 180 || y.abs() > 90) {
          outOfRange = true;
          return null;
        }
        out.add(LatLng(y, x));
      }
      return out;
    }

    final body = m.group(2)!;
    final Object? result = switch (m.group(1)!.toUpperCase()) {
      'POINT' => switch (coords(body)) {
        [final ll] => (GeometryType.point, ll),
        _ => null,
      },
      'LINESTRING' => switch (coords(body)) {
        final c? when c.length >= 2 => (GeometryType.linestring, c),
        _ => null,
      },
      _ => () {
        final rings = [for (final r in RegExp(r'\(([^()]*)\)').allMatches(body)) coords(r.group(1)!)];
        if (rings.isEmpty || rings.any((r) => r == null) || rings.first!.length < 3) return null;
        return (GeometryType.polygon, [for (final r in rings) r!]);
      }(),
    };
    return outOfRange ? _outOfRange : result;
  }

  static String _geometryKey(GeometryType t) => switch (t) {
    GeometryType.point => 'point',
    GeometryType.linestring => 'line',
    GeometryType.polygon => 'rings',
  };

  static String _suffix(GeometryType t) => switch (t) {
    GeometryType.point => 'point',
    GeometryType.linestring => 'line',
    GeometryType.polygon => 'polygon',
  };

  /// バイト列 → 文字列。UTF-8（BOM は外す）として読めなければ Shift_JIS。
  /// [encoding] は QGIS の delimitedtext URI に書ける名前
  @visibleForTesting
  static ({String text, String encoding}) decodeCsvBytes(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      return (text: text.startsWith('﻿') ? text.substring(1) : text, encoding: 'UTF-8');
    } on FormatException {
      return (text: charset.shiftJis.decode(bytes), encoding: 'Shift_JIS');
    }
  }

  /// CSV（RFC 4180）を行 × 値に分ける。`"` で囲んだ値の中のカンマ・改行、`""`（`"` 1 つ）を扱う。
  /// 改行は CRLF・LF・CR。空の行は捨てる
  @visibleForTesting
  static List<List<String>> parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    var fieldStarted = false;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      if (!(row.length == 1 && row.first.isEmpty)) rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(c);
        }
        continue;
      }
      switch (c) {
        case '"' when !fieldStarted && field.isEmpty:
          quoted = true;
          fieldStarted = true;
        case ',':
          endField();
        case '\r':
          if (i + 1 < text.length && text[i + 1] == '\n') i++;
          endRow();
        case '\n':
          endRow();
        default:
          field.write(c);
          fieldStarted = true;
      }
    }
    if (fieldStarted || field.isNotEmpty || row.isNotEmpty) endRow();
    return rows;
  }
}
