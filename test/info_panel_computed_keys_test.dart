// 情報パネル: 計算した情報（座標・頂点数・記録の時間）と属性が分かれ、
// latitude・longitude・vertex_count・timestamp という列が自分の値で出る（ホスト VM）。
//
// 以前は計算した情報を属性と同じ表（infoMap）に同じ名前で入れていて、測量の CSV 由来のデータによくある
// latitude・longitude の列は重心の座標に隠れ、vertex_count・timestamp の列は上書きされていた（2026-10-12）
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;

  const columns = {
    'name': 'TEXT',
    'latitude': 'REAL',
    'longitude': 'REAL',
    'vertex_count': 'INTEGER',
    'timestamp': 'TEXT',
    'metadata_note': 'TEXT',
    'sub_table': 'TEXT',
  };
  const attrs = {
    'name': 'a',
    'latitude': 34.5,
    'longitude': 136.5,
    'vertex_count': 99,
    'timestamp': '2026-01-02',
    'metadata_note': 'memo',
  };
  final track = jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (final ts in ['2026-10-12T09:00:00', '2026-10-12T09:30:00'])
        {'type': 'Feature', 'geometry': null, 'properties': {'timestamp': ts}},
    ],
  });

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('info_panel_keys_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
  });

  tearDown(() async {
    await gpkg.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  void expectOwnValues(FeatureNode f) {
    final info = f.infoMap;
    expect(info['latitude'], '34.5');
    expect(info['longitude'], '136.5');
    expect(info['vertex_count'], '99');
    expect(info['timestamp'], '2026-01-02');
    expect(info['metadata_note'], 'memo');
  }

  test('面: 属性は自分の値、頂点数と中心は計算した情報の欄に', () async {
    await gpkg.addLayer('pls', GeometryType.polygon);
    await gpkg.addAttributeColumns('pls', columns);
    const ring = [LatLng(33.0, 135.0), LatLng(33.0, 135.1), LatLng(33.1, 135.1), LatLng(33.0, 135.0)];
    await gpkg.addPolygonWithAttributes('pls', [ring], attrs);
    final layer = PolygonLayerNode(gpkg, 'pls', parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
    final f = layer.features.single;

    expectOwnValues(f);
    final computed = {for (final (label, value) in f.computedInfo) label: value};
    expect(computed.values, contains('3'));
    expect(computed.values.any((v) => v.startsWith('33.03')), isTrue, reason: '中心の座標');
  });

  test('線: 属性は自分の値、頂点数と記録の時間は計算した情報の欄に', () async {
    await gpkg.addLayer('lns', GeometryType.linestring);
    await gpkg.addAttributeColumns('lns', columns);
    const line = [LatLng(33.0, 135.0), LatLng(33.0, 135.1)];
    await gpkg.addLineWithAttributes('lns', line, {...attrs, 'sub_table': track});
    final layer = LineLayerNode(gpkg, 'lns', parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
    final f = layer.features.single;

    expectOwnValues(f);
    final values = [for (final (_, value) in f.computedInfo) value];
    expect(values, contains('2'));
    expect(values.any((v) => v.startsWith('09:00:00')), isTrue, reason: '記録の時間');
  });

  test('点: 属性は自分の値、座標は計算した情報の欄に', () async {
    await gpkg.addLayer('pts', GeometryType.point);
    await gpkg.addAttributeColumns('pts', columns);
    await gpkg.addPointWithAttributes('pts', const LatLng(33.25, 135.75), attrs);
    final layer = PointLayerNode(gpkg, 'pts', parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
    final f = layer.features.single;

    expectOwnValues(f);
    expect([for (final (_, value) in f.computedInfo) value], contains('33.250000, 135.750000'));
  });
}
