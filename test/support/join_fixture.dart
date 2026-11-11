// 台帳 CSV と計画図の結合のテストの材料（tool/qgis/write_join_fixture.py で QGIS に作らせたものと同じ形）
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/layer_join.dart';

/// fixture（QGIS が作った計画図）と同じ行
const parcelRows = <(int?, String, String?)>[
  (12, '1', '12-1'),
  (12, '2', '12-2'),
  (13, '1', '13-1'),
  (14, '1', '14-1'),
  (null, '9', null),
];

/// QGIS の fixture と同じ結合
const fixtureJoins = [
  LayerJoin(table: '台帳.csv', joinField: '区画番号', targetField: 'key', fields: ['区分', '年数']),
  LayerJoin(table: '地区表.csv', joinField: '地区', targetField: 'block', prefix: '地区_'),
];

/// [dir] に計画図.gpkg（parcels）と表 2 本を置く
Future<void> makeJoinProject(String dir) async {
  final g = GeoPackageFile(const ['計画図.gpkg'], absolutePath: p.join(dir, '計画図.gpkg'));
  await g.addLayer('parcels', GeometryType.polygon);
  await g.addAttributeColumns('parcels', {'block': 'INTEGER', 'parcels': 'TEXT', 'key': 'TEXT'});
  for (var i = 0; i < parcelRows.length; i++) {
    final (block, parcels, key) = parcelRows[i];
    final x = 135.9 + i * 0.01;
    await g.addPolygonWithAttributes('parcels', [
      [LatLng(33.9, x), LatLng(33.9, x + 0.009), LatLng(33.909, x + 0.009), LatLng(33.9, x)],
    ], {'block': block, 'parcels': parcels, 'key': key});
  }
  await g.flushChanges();
  await g.dispose();
  for (final name in ['台帳.csv', '地区表.csv']) {
    File(p.join('test/fixtures/joins', name)).copySync(p.join(dir, name));
  }
}
