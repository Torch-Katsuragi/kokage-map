// 座標列のある CSV の読み手: 列の推定、引用符、Shift_JIS、投影座標・座標列なしの拒否
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart' as charset;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/external/readers/csv_reader.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('csv_reader_'));
  tearDown(() async => dir.delete(recursive: true));

  String write(String name, List<int> bytes) {
    final path = '${dir.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  group('detectColumns', () {
    test('緯度経度の名前（大文字小文字・日本語）', () {
      expect(
        CsvReader.detectColumns('id,Latitude,LONGITUDE'),
        const CsvGeometryColumns.xy(xField: 'LONGITUDE', yField: 'Latitude'),
      );
      expect(CsvReader.detectColumns('名前,緯度,経度'), const CsvGeometryColumns.xy(xField: '経度', yField: '緯度'));
      expect(CsvReader.detectColumns('lng,lat'), const CsvGeometryColumns.xy(xField: 'lng', yField: 'lat'));
      expect(CsvReader.detectColumns('"X","Y",v'), const CsvGeometryColumns.xy(xField: 'X', yField: 'Y'));
    });

    test('緯度経度が WKT・x/y より先', () {
      expect(CsvReader.detectColumns('x,y,lat,lon,wkt'), const CsvGeometryColumns.xy(xField: 'lon', yField: 'lat'));
      expect(CsvReader.detectColumns('x,y,WKT'), const CsvGeometryColumns.wkt('WKT'));
      expect(CsvReader.detectColumns('id,geometry'), const CsvGeometryColumns.wkt('geometry'));
    });

    test('片方しか無ければ null', () {
      expect(CsvReader.detectColumns('lat,name'), isNull);
      expect(CsvReader.detectColumns('a,b,c'), isNull);
      expect(CsvReader.detectColumns(''), isNull);
    });
  });

  test('引用符の中のカンマ・改行・二重引用符、CRLF、空行', () {
    expect(CsvReader.parseCsv('a,b\r\n"1,2","x\ny"\r\n\r\n"say ""hi""",\n'), [
      ['a', 'b'],
      ['1,2', 'x\ny'],
      ['say "hi"', ''],
    ]);
  });

  test('点を読む。属性は全列（緯度経度も）、数だけの列は REAL、BOM は外す', () async {
    final path = write(
      '調査地点.csv',
      utf8.encode('﻿name,lat,lon,memo\n"A, 1",34.25,135.5,"一行目\n二行目"\nB,34.3,135.6,\n壊れ,abc,135,x\n'),
    );
    final reader = CsvReader();
    expect(await reader.accepts(path), isTrue);
    final ds = (await reader.read(path)).single;
    expect(ds.layerName, '調査地点');
    expect(ds.geometryType, GeometryType.point);
    expect(ds.columns, {'name': 'TEXT', 'lat': 'REAL', 'lon': 'REAL', 'memo': 'TEXT'});
    expect(ds.features, hasLength(2), reason: '座標の読めない行は捨てる');
    expect(ds.features[0], {
      'point': const LatLng(34.25, 135.5),
      'name': 'A, 1',
      'lat': 34.25,
      'lon': 135.5,
      'memo': '一行目\n二行目',
    });
    expect(ds.features[1].containsKey('memo'), isFalse);

    final info = await CsvReader.inspect(path);
    expect(info?.columns, const CsvGeometryColumns.xy(xField: 'lon', yField: 'lat'));
    expect(info?.encoding, 'UTF-8');
  });

  test('UTF-8 として読めなければ Shift_JIS', () async {
    final path = write('sjis.csv', charset.shiftJis.encode('名称,緯度,経度\n杉林,34.1,135.9\n'));
    expect(await CsvReader().accepts(path), isTrue);
    final ds = (await CsvReader().read(path)).single;
    expect(ds.columns.keys, ['名称', '緯度', '経度']);
    expect(ds.features.single['名称'], '杉林');
    expect(ds.features.single['point'], const LatLng(34.1, 135.9));
    expect((await CsvReader.inspect(path))?.encoding, 'Shift_JIS');
  });

  test('WKT の列（点・線・面）は型ごとのレイヤ、WKT の列は属性にしない', () async {
    final path = write(
      'w.csv',
      utf8.encode(
        'id,wkt\n'
        '1,POINT (135 34)\n'
        '2,"LINESTRING (135 34, 135.1 34.1)"\n'
        '3,"POLYGON ((135 34, 135.1 34, 135.1 34.1, 135 34), (135.02 34.01, 135.03 34.01, 135.03 34.02, 135.02 34.01))"\n'
        '4,MULTIPOINT ((1 2))\n',
      ),
    );
    expect(await CsvReader().accepts(path), isTrue);
    final ds = await CsvReader().read(path);
    expect(ds.map((d) => (d.layerName, d.geometryType)), [
      ('w_point', GeometryType.point),
      ('w_line', GeometryType.linestring),
      ('w_polygon', GeometryType.polygon),
    ]);
    expect(ds.first.columns, {'id': 'REAL'});
    expect(ds[1].features.single['line'], const [LatLng(34, 135), LatLng(34.1, 135.1)]);
    expect(ds[2].features.single['rings'], hasLength(2));
  });

  test('断る: 座標列が無い・投影座標（絶対値 180 超）・座標がひとつも読めない', () async {
    final reader = CsvReader();
    expect(await reader.accepts(write('a.csv', utf8.encode('a,b\n1,2\n'))), isFalse);
    expect(await reader.accepts(write('b.csv', utf8.encode('x,y\n-45000.5,-210000.2\n'))), isFalse);
    expect(await reader.accepts(write('c.csv', utf8.encode('lat,lon\nfoo,bar\n'))), isFalse);
    expect(await reader.accepts(write('d.csv', utf8.encode('id,wkt\n1,POINT (500000 3800000)\n'))), isFalse);
    expect(await reader.accepts(write('e.csv', utf8.encode('lat,lon\n'))), isTrue, reason: '見出しだけは空のレイヤ');
  });
}
