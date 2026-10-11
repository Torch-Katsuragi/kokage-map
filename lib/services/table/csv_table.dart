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
// 形の無い表（森林簿などの CSV）を読む。設計は docs/technical/qgis-interop.md#表の結合（森林簿 CSV と計画図）
//
// GDAL の CSV ドライバは文字コードを選べない（Shift_JIS の CSV は化ける）ので、表は Dart で読む。
// 型の判定は QGIS の「CSV テキストレイヤ」（delimitedtext、detectTypes=yes）に合わせる: 整数・小数・文字。

import 'dart:convert';
import 'dart:typed_data';

import 'cp932_table.dart';

/// CP932（Windows の Shift_JIS。NEC 特殊文字・IBM 拡張文字を含む）を文字にする。読めないバイトは U+FFFD
String decodeCp932(List<int> bytes) {
  final out = StringBuffer();
  final n = bytes.length;
  for (var i = 0; i < n; i++) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
    } else if (b >= 0xA1 && b <= 0xDF) {
      out.write(cp932HalfKana[b - 0xA1]);
    } else if ((b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC)) {
      final t = i + 1 < n ? bytes[i + 1] : -1;
      if (t < 0x40 || t > 0xFC) {
        out.writeCharCode(0xFFFD);
        continue;
      }
      i++;
      final lead = b <= 0x9F ? b - 0x81 : b - 0xE0 + 31;
      out.write(cp932DoubleByte[lead * 189 + (t - 0x40)]);
    } else {
      out.writeCharCode(0xFFFD);
    }
  }
  return out.toString();
}

/// 表の列の型（QGIS の delimitedtext の判定の部分集合）
enum TableFieldType { integer, real, text }

/// 表の列
class TableField {
  const TableField(this.name, this.type);
  final String name;
  final TableFieldType type;
}

/// 読んだ表。値は型に合わせて int / double / String、空は null
class CsvTable {
  const CsvTable({required this.fields, required this.rows, required this.encoding});

  final List<TableField> fields;

  /// 行ごとの値（[fields] の順）
  final List<List<Object?>> rows;

  /// 読んだ文字コード（`UTF-8` か `CP932`）。`.qgs` の delimitedtext の `encoding=` に書く
  final String encoding;

  int indexOf(String field) => fields.indexWhere((f) => f.name == field);

  List<String> get fieldNames => [for (final f in fields) f.name];

  /// CSV のバイト列を読む。UTF-8（BOM の有無を問わない）として読めなければ CP932（Shift_JIS）
  static CsvTable parse(Uint8List bytes) {
    final (text, encoding) = decodeText(bytes);
    final records = parseCsvRecords(text);
    if (records.isEmpty) return CsvTable(fields: const [], rows: const [], encoding: encoding);
    final header = records.first;
    final names = <String>[];
    for (var i = 0; i < header.length; i++) {
      var name = header[i].trim();
      if (name.isEmpty) name = 'field_${i + 1}'; // QGIS と同じ名前
      var unique = name;
      for (var n = 2; names.contains(unique); n++) {
        unique = '${name}_$n';
      }
      names.add(unique);
    }
    final raw = [
      for (final r in records.skip(1))
        if (!(r.length == 1 && r.first.isEmpty)) r, // 空行
    ];
    final types = [for (var i = 0; i < names.length; i++) _detectType(raw, i)];
    return CsvTable(
      fields: [for (var i = 0; i < names.length; i++) TableField(names[i], types[i])],
      rows: [
        for (final r in raw)
          [for (var i = 0; i < names.length; i++) _convert(i < r.length ? r[i] : '', types[i])],
      ],
      encoding: encoding,
    );
  }

  /// 文字コードを決めて文字にする。UTF-8 として正しければ UTF-8、でなければ CP932
  static (String, String) decodeText(Uint8List bytes) {
    var start = 0;
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) start = 3;
    final body = Uint8List.sublistView(bytes, start);
    try {
      return (utf8.decode(body), 'UTF-8');
    } on FormatException {
      return (decodeCp932(body), 'CP932');
    }
  }

  static final _intPattern = RegExp(r'^[+-]?\d+$');
  static final _realPattern = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

  static TableFieldType _detectType(List<List<String>> rows, int column) {
    var sawValue = false;
    var allInt = true;
    var allReal = true;
    for (final r in rows) {
      final v = column < r.length ? r[column].trim() : '';
      if (v.isEmpty) continue;
      sawValue = true;
      if (allInt && !_intPattern.hasMatch(v)) allInt = false;
      if (allReal && !_realPattern.hasMatch(v)) allReal = false;
      if (!allInt && !allReal) return TableFieldType.text;
    }
    if (!sawValue) return TableFieldType.text;
    if (allInt) return TableFieldType.integer;
    return allReal ? TableFieldType.real : TableFieldType.text;
  }

  static Object? _convert(String raw, TableFieldType type) {
    if (raw.isEmpty) return null;
    return switch (type) {
      TableFieldType.integer => int.tryParse(raw.trim()) ?? raw,
      TableFieldType.real => double.tryParse(raw.trim()) ?? raw,
      TableFieldType.text => raw,
    };
  }
}

/// RFC 4180 の CSV を行と欄に分ける（`"` で囲んだ欄の中の `,` `""` 改行も読む）。区切りは `,`
List<List<String>> parseCsvRecords(String text) {
  final records = <List<String>>[];
  var record = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var i = 0;
  final n = text.length;
  void endField() {
    record.add(field.toString());
    field.clear();
  }

  void endRecord() {
    endField();
    records.add(record);
    record = <String>[];
  }

  while (i < n) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < n && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        quoted = false;
      } else {
        field.write(c);
      }
      i++;
      continue;
    }
    switch (c) {
      case '"' when field.isEmpty:
        quoted = true;
      case ',':
        endField();
      case '\r':
        if (i + 1 < n && text[i + 1] == '\n') i++;
        endRecord();
      case '\n':
        endRecord();
      default:
        field.write(c);
    }
    i++;
  }
  if (field.isNotEmpty || record.isNotEmpty) endRecord();
  return records;
}
