// レイヤを別の GeoPackage へ移す・写す（レイヤ一覧で gpkg へドラッグ）で、地物と属性が全部渡るか
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile src;
  late GeoPackageFile dst;
  late GeoPackageNode srcNode;
  late GeoPackageNode dstNode;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('layer_migrate_');
    src = GeoPackageFile(const ['a.gpkg'], absolutePath: p.join(tmp.path, 'a.gpkg'));
    dst = GeoPackageFile(const ['b.gpkg'], absolutePath: p.join(tmp.path, 'b.gpkg'));
    await dst.createEmptyDatabase();
    final root = FolderNode('Home', children: []);
    srcNode = GeoPackageNode(src, parent: root);
    dstNode = GeoPackageNode(dst, parent: root);
    root.children.addAll([srcNode, dstNode]);
  });

  tearDown(() async {
    await src.dispose();
    await dst.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  const a = LatLng(33.93, 135.96);
  const b = LatLng(33.94, 135.97);
  const c = LatLng(33.94, 135.96);

  Future<LayerNode> layer(String name) async {
    await srcNode.updateChildren();
    return srcNode.children.whereType<LayerNode>().firstWhere((l) => l.layerName == name);
  }

  test('点・線・面の地物と属性を写す', () async {
    await src.addLayer('pts', GeometryType.point);
    await src.addLayer('roads', GeometryType.linestring);
    await src.addLayer('stands', GeometryType.polygon);
    for (final t in ['pts', 'roads', 'stands']) {
      await src.addAttributeColumns(t, {'name': 'TEXT', 'dbh': 'REAL'});
    }
    await src.addPointWithAttributes('pts', a, {'name': 'p1', 'dbh': 30.5});
    await src.addPointWithAttributes('pts', b, {'name': 'p2'});
    await src.addLineWithAttributes('roads', [a, b], {'name': 'r1'});
    await src.addPolygonWithAttributes('stands', [
      [a, b, c, a],
    ], {'name': 's1', 'dbh': 1.0});

    for (final t in ['pts', 'roads', 'stands']) {
      final moved = await (await layer(t)).migrateToGeoPackage(dstNode, moveLayer: false);
      expect(moved, isNotNull, reason: t);
    }

    final pts = await dst.getFeaturesWithGeometry('pts');
    expect(pts.map((r) => r['name']), ['p1', 'p2']);
    expect(pts.first['dbh'], 30.5);
    expect((pts.first['geometry'] as List).single, a);

    final roads = await dst.getFeaturesWithGeometry('roads');
    expect(roads.map((r) => r['name']), ['r1']);
    expect(roads.single['geometry'], [
      [a, b],
    ]);

    final stands = await dst.getFeaturesWithGeometry('stands');
    expect(stands.map((r) => r['name']), ['s1']);
    expect(stands.single['geometry'], [
      [
        [a, b, c, a],
      ],
    ]);

    // 写し元は残っている
    expect(await src.getLayerNames(), containsAll(['pts', 'roads', 'stands']));
  });

  test('移すと写し先に地物が全部渡り、写し元のレイヤは消える', () async {
    await src.addLayer('stands', GeometryType.polygon);
    await src.addAttributeColumns('stands', {'name': 'TEXT', 'kmaps_metadata': 'TEXT'});
    for (var i = 0; i < 3; i++) {
      await src.addPolygonWithAttributes('stands', [
        [a, b, c, a],
      ], {'name': 's$i', 'kmaps_metadata': '{"n":$i}'});
    }

    final moved = await (await layer('stands')).migrateToGeoPackage(dstNode);
    expect(moved, isNotNull);
    expect(await src.getLayerNames(), isNot(contains('stands')));

    final stands = await dst.getFeaturesWithGeometry('stands');
    expect(stands.map((r) => r['name']), ['s0', 's1', 's2']);
    expect(stands.map((r) => r['kmaps_metadata']), [
      {'n': 0},
      {'n': 1},
      {'n': 2},
    ]);
  });

  test('渡らない地物があれば移さない（写し先を消し、写し元は残す）', () async {
    await src.addLayer('stands', GeometryType.polygon);
    await src.addAttributeColumns('stands', {'name': 'TEXT'});
    await src.addPolygonWithAttributes('stands', [
      [a, b, c, a],
    ], {'name': 'ok'});
    // 読めない形の行は書き先に渡せない
    await (await src.getDatabase()).rawInsert('INSERT INTO stands (name, geom) VALUES (?, ?)', ['broken', Uint8List.fromList([0x47, 0x50, 0, 1])]);

    final moved = await (await layer('stands')).migrateToGeoPackage(dstNode);
    expect(moved, isNull);
    expect(await src.getLayerNames(), contains('stands'));
    expect(await dst.getLayerNames(), isNot(contains('stands')));
  });
}
