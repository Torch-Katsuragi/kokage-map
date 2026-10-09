// DBF の削除済み行（削除フラグ `*`）で、後ろの行の属性が SHP のレコードとずれないこと
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/services/import_export/parsers/dbf_reader.dart';

/// 1 列（C 型・長さ 8）の dBASE III を手で組む。[rows] は (削除フラグつきか, 値)
Uint8List _dbf(List<(bool, String)> rows) {
  const fieldLength = 8;
  const headerLength = 32 + 32 + 1;
  const recordLength = 1 + fieldLength;
  final b = BytesBuilder();
  final header = ByteData(32)
    ..setUint8(0, 0x03)
    ..setUint32(4, rows.length, Endian.little)
    ..setUint16(8, headerLength, Endian.little)
    ..setUint16(10, recordLength, Endian.little);
  b.add(header.buffer.asUint8List());
  final field = Uint8List(32);
  field.setAll(0, 'NAME'.codeUnits);
  field[11] = 'C'.codeUnitAt(0);
  field[16] = fieldLength;
  b.add(field);
  b.addByte(0x0D);
  for (final (deleted, value) in rows) {
    b.addByte(deleted ? 0x2A : 0x20);
    b.add(value.padRight(fieldLength).codeUnits);
  }
  b.addByte(0x1A);
  return b.toBytes();
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('dbf_deleted_'));
  tearDown(() async => dir.delete(recursive: true));

  test('削除済みの行があっても後ろの行の属性が行番号どおり', () async {
    final path = '${dir.path}/t.dbf';
    File(path).writeAsBytesSync(_dbf([(false, 'sugi'), (true, 'gone'), (false, 'hinoki')]));
    final data = await DbfReader.read(path);

    expect(data!['NAME'], hasLength(3), reason: '削除済みの行も詰めない');
    expect(DbfReader.getAttributesForRecord(data, 0), {'NAME': 'sugi'});
    expect(DbfReader.getAttributesForRecord(data, 1), isEmpty);
    expect(DbfReader.getAttributesForRecord(data, 2), {'NAME': 'hinoki'});
    expect(DbfReader.isDeletedRecord(data, 1), isTrue);
    expect(DbfReader.isDeletedRecord(data, 0), isFalse);
    expect(DbfReader.isDeletedRecord(data, 2), isFalse);
  });

  test('削除済みの行が無ければ isDeletedRecord は常に false', () async {
    final path = '${dir.path}/t.dbf';
    File(path).writeAsBytesSync(_dbf([(false, 'a'), (false, 'b')]));
    final data = await DbfReader.read(path);
    expect(data!['NAME'], ['a', 'b']);
    expect(DbfReader.isDeletedRecord(data, 0), isFalse);
    expect(DbfReader.isDeletedRecord(null, 0), isFalse);
  });
}
