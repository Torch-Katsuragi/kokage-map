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
// Shapefile の .shp/.shx/.dbf をバイト列に組む（ファイル I/O なし）
import 'dart:typed_data';

import '../../../utils/binary_utils.dart';
import '../parsers/shapefile_binary_parser.dart' show ShapeType;

/// 1 つの形。部分（線の 1 本・面の 1 リング）ごとの [x, y] の並び。
/// 点は部分 1 つ・点 1 つ。
typedef ShpShape = List<List<List<double>>>;

/// [shapeType] は [ShapeType.point] / [ShapeType.polyLine] / [ShapeType.polygon]。
/// 面は最初のリングを外周として時計回り、残り（穴）を反時計回りに揃えて書く（Shapefile の決まり）
({Uint8List shp, Uint8List shx}) encodeShpShx(
  int shapeType,
  List<ShpShape> shapes,
) {
  final isPoint = shapeType == ShapeType.point;
  final contentBytes = [
    for (final s in shapes)
      isPoint ? 20 : 44 + 4 * s.length + 16 * _pointCount(s),
  ];
  final shpLength = contentBytes.fold<int>(100, (sum, c) => sum + 8 + c);
  final shxLength = 100 + 8 * shapes.length;
  final shp = ByteData(shpLength);
  final shx = ByteData(shxLength);

  final bbox = BoundingBox();
  for (final s in shapes) {
    _extend(bbox, s);
  }
  bbox.ensureValid();
  _writeHeader(shp, shapeType, shpLength, bbox);
  _writeHeader(shx, shapeType, shxLength, bbox);

  var o = 100;
  for (var i = 0; i < shapes.length; i++) {
    final shape = shapes[i];
    final words = contentBytes[i] ~/ 2;
    shx.setInt32(100 + 8 * i, o ~/ 2);
    shx.setInt32(104 + 8 * i, words);

    shp.setInt32(o, i + 1);
    shp.setInt32(o + 4, words);
    shp.setInt32(o + 8, shapeType, Endian.little);
    o += 12;
    if (isPoint) {
      final p = shape.first.first;
      shp.setFloat64(o, p[0], Endian.little);
      shp.setFloat64(o + 8, p[1], Endian.little);
      o += 16;
      continue;
    }

    final b = BoundingBox();
    _extend(b, shape);
    b.ensureValid();
    o = _writeBox(shp, o, b);
    shp.setInt32(o, shape.length, Endian.little);
    shp.setInt32(o + 4, _pointCount(shape), Endian.little);
    o += 8;
    var start = 0;
    for (final part in shape) {
      shp.setInt32(o, start, Endian.little);
      o += 4;
      start += part.length;
    }
    for (var k = 0; k < shape.length; k++) {
      final part = shape[k];
      final reverse = shapeType == ShapeType.polygon &&
          (_signedArea(part) > 0) == (k == 0); // 外周が反時計回り・穴が時計回りなら逆に
      for (var n = 0; n < part.length; n++) {
        final p = part[reverse ? part.length - 1 - n : n];
        shp.setFloat64(o, p[0], Endian.little);
        shp.setFloat64(o + 8, p[1], Endian.little);
        o += 16;
      }
    }
  }
  return (shp: shp.buffer.asUint8List(), shx: shx.buffer.asUint8List());
}

/// 靴ひも公式の符号つき面積。正なら反時計回り（x 東・y 北）
double _signedArea(List<List<double>> ring) {
  var sum = 0.0;
  for (var i = 0; i + 1 < ring.length; i++) {
    sum += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1];
  }
  return sum / 2;
}

int _pointCount(ShpShape shape) =>
    shape.fold<int>(0, (sum, part) => sum + part.length);

void _extend(BoundingBox bbox, ShpShape shape) {
  for (final part in shape) {
    for (final p in part) {
      bbox.extend(p[0], p[1]);
    }
  }
}

/// ファイル長は 16 bit ワード単位、Z/M の範囲は 0 のまま
void _writeHeader(ByteData d, int shapeType, int lengthBytes, BoundingBox b) {
  d.setInt32(0, 9994);
  d.setInt32(24, lengthBytes ~/ 2);
  d.setInt32(28, 1000, Endian.little);
  d.setInt32(32, shapeType, Endian.little);
  _writeBox(d, 36, b);
}

int _writeBox(ByteData d, int o, BoundingBox b) {
  d.setFloat64(o, b.minX, Endian.little);
  d.setFloat64(o + 8, b.minY, Endian.little);
  d.setFloat64(o + 16, b.maxX, Endian.little);
  d.setFloat64(o + 24, b.maxY, Endian.little);
  return o + 32;
}

class _DbfField {
  _DbfField(this.name, this.type, this.length, this.decimal, this.sourceKey);
  final String name;
  final String type;
  final int length;
  final int decimal;

  /// null は行番号
  final String? sourceKey;
}

/// 属性を DBF（CP932）に組む。列の型は最後に出てきた値で決める。
/// 列名は 10 文字に切って大文字にし、重なったら先の列を残す。
Uint8List encodeDbf(
  List<Map<String, dynamic>> rows, {
  bool includeRowNumber = false,
  DateTime? now,
}) {
  if (rows.isEmpty) {
    return Uint8List(32)..[0] = 0x03;
  }

  final fields = <_DbfField>[
    if (includeRowNumber) _DbfField('ROW_NUM', 'N', 10, 0, null),
  ];
  final lastValues = <String, dynamic>{};
  for (final row in rows) {
    lastValues.addAll(row);
  }
  final names = {for (final f in fields) f.name};
  for (final MapEntry(:key, :value) in lastValues.entries) {
    final name = (key.length > 10 ? key.substring(0, 10) : key).toUpperCase();
    if (!names.add(name)) continue;
    fields.add(switch (value) {
      double() => _DbfField(name, 'N', 15, 8, key),
      num() => _DbfField(name, 'N', 10, 0, key),
      bool() => _DbfField(name, 'L', 1, 0, key),
      _ => _DbfField(name, 'C', 50, 0, key),
    });
  }

  final recordLength = fields.fold<int>(1, (sum, f) => sum + f.length);
  final headerLength = 32 + fields.length * 32 + 1;
  final date = now ?? DateTime.now();
  final out = BytesBuilder(copy: false)
    ..add([0x03, date.year - 1900, date.month, date.day])
    ..add(BinaryUtils.writeInt32LittleEndian(rows.length))
    ..add(BinaryUtils.writeInt16LittleEndian(headerLength))
    ..add(BinaryUtils.writeInt16LittleEndian(recordLength))
    ..add(Uint8List(20));

  for (final f in fields) {
    out
      ..add(BinaryUtils.encodeToShiftJis(f.name, 11))
      ..addByte(f.type.codeUnitAt(0))
      ..add(Uint8List(4))
      ..add([f.length, f.decimal])
      ..add(Uint8List(14));
  }
  out.addByte(0x0D);

  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    out.addByte(0x20);
    for (final f in fields) {
      final key = f.sourceKey;
      final text = key == null ? '${i + 1}' : row[key]?.toString() ?? '';
      final padded =
          f.type == 'N' ? text.padLeft(f.length) : text.padRight(f.length);
      out.add(
        BinaryUtils.encodeToShiftJis(padded, f.length, padWithSpace: true),
      );
    }
  }
  out.addByte(0x1A);
  return out.takeBytes();
}
