// 森林簿 CSV と計画図の結合のテストの材料（tool/qgis/write_join_fixture.py で QGIS に作らせたものと同じ形）
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/layer_join.dart';

/// fixture（QGIS が作った計画図）と同じ行
const shobanRows = <(int?, String, String?)>[
  (12, '1', '12-1'),
  (12, '2', '12-2'),
  (13, '1', '13-1'),
  (14, '1', '14-1'),
  (null, '9', null),
];

/// QGIS の fixture と同じ結合
const fixtureJoins = [
  LayerJoin(table: '森林簿.csv', joinField: '林小班', targetField: 'key', fields: ['樹種', '林齢']),
  LayerJoin(table: '林班表.csv', joinField: '林班', targetField: 'rinpan', prefix: '林班_'),
];

/// [dir] に計画図.gpkg（shoban）と表 2 本を置く
Future<void> makeJoinProject(String dir) async {
  final g = GeoPackageFile(const ['計画図.gpkg'], absolutePath: p.join(dir, '計画図.gpkg'));
  await g.addLayer('shoban', GeometryType.polygon);
  await g.addAttributeColumns('shoban', {'rinpan': 'INTEGER', 'shoban': 'TEXT', 'key': 'TEXT'});
  for (var i = 0; i < shobanRows.length; i++) {
    final (rinpan, shoban, key) = shobanRows[i];
    final x = 135.9 + i * 0.01;
    await g.addPolygonWithAttributes('shoban', [
      [LatLng(33.9, x), LatLng(33.9, x + 0.009), LatLng(33.909, x + 0.009), LatLng(33.9, x)],
    ], {'rinpan': rinpan, 'shoban': shoban, 'key': key});
  }
  await g.flushChanges();
  await g.dispose();
  for (final name in ['森林簿.csv', '林班表.csv']) {
    File(p.join('test/fixtures/joins', name)).copySync(p.join(dir, name));
  }
}
