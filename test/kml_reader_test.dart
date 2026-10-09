// KML / KMZ の読み手: フォルダ × ジオメトリ型でのレイヤ分け、ExtendedData、KMZ の展開
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/external/external_dataset.dart';
import 'package:root_maps/services/external/readers/kml_reader.dart';

String _kml(String body) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
<Document><name>doc</name>
$body
</Document>
</kml>''';

const _square = '135.0,34.0,0 135.1,34.0,0 135.1,34.1,0 135.0,34.1,0 135.0,34.0,0';
const _hole = '135.02,34.02 135.03,34.02 135.03,34.03 135.02,34.02';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('kml_reader_'));
  tearDown(() async => dir.delete(recursive: true));

  Future<List<ExternalDataset>> readKml(String name, String body) async {
    final path = '${dir.path}/$name';
    File(path).writeAsStringSync(_kml(body));
    return KmlReader().read(path);
  }

  test('フォルダの無い 1 型の KML はファイル名の 1 枚。座標は lon,lat の順', () async {
    final ds = await readKml('林道.kml', '''
<Placemark><name>A</name><description><![CDATA[<b>説明</b>]]></description>
  <Point><coordinates>135.5,34.25,10</coordinates></Point></Placemark>
<Placemark><name>B</name><Point><coordinates> 135.6 , 34.3 </coordinates></Point></Placemark>
''');
    expect(ds, hasLength(1));
    expect(ds.single.layerName, '林道');
    expect(ds.single.geometryType, GeometryType.point);
    expect(ds.single.columns, {'name': 'TEXT', 'description': 'TEXT'});
    expect(ds.single.features[0], {'point': const LatLng(34.25, 135.5), 'name': 'A', 'description': '<b>説明</b>'});
    expect(ds.single.features[1]['point'], const LatLng(34.3, 135.6));
    expect(ds.single.features[1].containsKey('description'), isFalse);
  });

  test('フォルダごとに 1 枚。型が混ざるフォルダだけ接尾辞。入れ子のフォルダ名が重なれば道筋', () async {
    final ds = await readKml('t.kml', '''
<Folder><name>林班</name>
  <Placemark><name>p1</name><Polygon>
    <outerBoundaryIs><LinearRing><coordinates>$_square</coordinates></LinearRing></outerBoundaryIs>
    <innerBoundaryIs><LinearRing><coordinates>$_hole</coordinates></LinearRing></innerBoundaryIs>
  </Polygon></Placemark>
</Folder>
<Folder><name>作業道</name>
  <Placemark><name>l1</name><LineString><coordinates>135,34 135.1,34.1</coordinates></LineString></Placemark>
  <Placemark><name>pt</name><Point><coordinates>135,34</coordinates></Point></Placemark>
  <Folder><name>林班</name>
    <Placemark><name>p2</name><Point><coordinates>135,34</coordinates></Point></Placemark>
  </Folder>
</Folder>
<Placemark><name>root</name><Point><coordinates>135,34</coordinates></Point></Placemark>
''');
    expect(ds.map((d) => (d.layerName, d.geometryType)), [
      ('林班', GeometryType.polygon),
      ('作業道_line', GeometryType.linestring),
      ('作業道_point', GeometryType.point),
      ('作業道_林班', GeometryType.point),
      ('t', GeometryType.point),
    ]);
    final polygon = ds.first.features.single['rings'] as List<List<LatLng>>;
    expect(polygon, hasLength(2), reason: '外周と穴');
    expect(polygon[0].first, const LatLng(34.0, 135.0));
    expect(polygon[1], hasLength(4));
  });

  test('MultiGeometry は型ごとのレイヤに部分ごとに分かれ、属性は同じ', () async {
    final ds = await readKml('m.kml', '''
<Placemark><name>混在</name><MultiGeometry>
  <Point><coordinates>135,34</coordinates></Point>
  <Point><coordinates>135.1,34.1</coordinates></Point>
  <LineString><coordinates>135,34 135.1,34.1</coordinates></LineString>
  <Polygon><outerBoundaryIs><LinearRing><coordinates>$_square</coordinates></LinearRing></outerBoundaryIs></Polygon>
</MultiGeometry></Placemark>
<Placemark><name>軌跡</name><gx:Track>
  <when>2026-10-09T00:00:00Z</when><when>2026-10-09T00:01:00Z</when>
  <gx:coord>135.0 34.0 100</gx:coord><gx:coord>135.01 34.01 110</gx:coord>
</gx:Track></Placemark>
''');
    final byName = {for (final d in ds) d.layerName: d};
    expect(byName.keys, ['m_point', 'm_line', 'm_polygon']);
    expect(byName['m_point']!.features.map((f) => f['name']), ['混在', '混在']);
    expect(byName['m_line']!.features.map((f) => f['name']), ['混在', '軌跡']);
    expect(byName['m_line']!.features[1]['line'], const [LatLng(34.0, 135.0), LatLng(34.01, 135.01)]);
    expect(byName['m_polygon']!.features.single['rings'], hasLength(1));
  });

  test('ExtendedData（Data と SchemaData）が列になり、数だけの列は REAL', () async {
    final ds = await readKml('e.kml', '''
<Schema name="s" id="s"><SimpleField name="樹種" type="string"/><SimpleField name="面積" type="double"/></Schema>
<Placemark><name>1</name>
  <ExtendedData>
    <Data name="林班"><value>012</value></Data>
    <SchemaData schemaUrl="#s"><SimpleData name="樹種">スギ</SimpleData><SimpleData name="面積">1.5</SimpleData></SchemaData>
  </ExtendedData>
  <Point><coordinates>135,34</coordinates></Point></Placemark>
<Placemark><name>2</name>
  <ExtendedData>
    <Data name="林班"><value>13</value></Data>
    <Data name="point"><value>x</value></Data>
    <SchemaData schemaUrl="#s"><SimpleData name="面積"></SimpleData></SchemaData>
  </ExtendedData>
  <Point><coordinates>135,34</coordinates></Point></Placemark>
''');
    final d = ds.single;
    expect(d.columns, {
      'name': 'REAL',
      'description': 'TEXT',
      '林班': 'TEXT', // 012 は番号として文字列のまま
      '樹種': 'TEXT',
      '面積': 'REAL',
      'point_1': 'TEXT', // 形のキーと重なる名前は付け替える
    });
    expect(d.features[0]['面積'], 1.5);
    expect(d.features[0]['林班'], '012');
    expect(d.features[1].containsKey('面積'), isFalse);
    expect(d.features[1]['point'], isA<LatLng>());
    expect(d.features[1]['point_1'], 'x');
  });

  test('KMZ は doc.kml を読む（無ければ最初の .kml）', () async {
    final kml = _kml('<Placemark><name>z</name><Point><coordinates>135,34</coordinates></Point></Placemark>');
    final other = _kml('<Placemark><name>other</name><Point><coordinates>136,35</coordinates></Point></Placemark>');
    final zip = ZipEncoder().encodeBytes(
      Archive()
        ..addFile(ArchiveFile.string('files/other.kml', other))
        ..addFile(ArchiveFile.string('doc.kml', kml))
        ..addFile(ArchiveFile.bytes('files/icon.png', [0x89, 0x50])),
    );
    final path = '${dir.path}/z.kmz';
    File(path).writeAsBytesSync(zip);
    final ds = await KmlReader().read(path);
    expect(ds.single.layerName, 'z');
    expect(ds.single.features.single['name'], 'z');

    final noDoc = ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.string('a.kml', other)));
    File(path).writeAsBytesSync(noDoc);
    expect((await KmlReader().read(path)).single.features.single['name'], 'other');
  });

  test('KMZ に .kml が無ければ例外', () async {
    final path = '${dir.path}/empty.kmz';
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.string('a.txt', 'x'))));
    expect(KmlReader().read(path), throwsFormatException);
  });
}
