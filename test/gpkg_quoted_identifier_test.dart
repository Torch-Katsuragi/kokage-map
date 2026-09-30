// 空白や引用符を含むテーブル名・カラム名でフィーチャを読み書きできるかのテスト
//
// QGIS で作ったレイヤは "Survey points" のような名前になりやすい。sqflite の
// `db.insert` 等は識別子を囲まないので、以前は `INSERT INTO Survey points ...` で
// 構文エラーになり、フィーチャを 1 件も追加できなかった（2026-10-01）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/sql_identifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_quoted_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('quoteIdent は二重引用符を重ねてエスケープする', () {
    expect(quoteIdent('Survey points'), '"Survey points"');
    expect(quoteIdent('Plot "A"'), '"Plot ""A"""');
  });

  const line = [LatLng(35.68, 139.76), LatLng(35.69, 139.77)];
  const ring = [
    LatLng(35.68, 139.76),
    LatLng(35.68, 139.77),
    LatLng(35.69, 139.77),
    LatLng(35.68, 139.76),
  ];

  Future<int?> add(String table, GeometryType type, Map<String, dynamic> a) {
    switch (type) {
      case GeometryType.point:
        return gpkg.addPointWithAttributes(table, const LatLng(35.68, 139.76), a);
      case GeometryType.linestring:
        return gpkg.addLineWithAttributes(table, line, a);
      case GeometryType.polygon:
        return gpkg.addPolygonWithAttributes(table, [ring], a);
    }
  }

  Future<bool> updateGeometry(String table, int id, GeometryType type) {
    switch (type) {
      case GeometryType.point:
        return gpkg.updatePoint(table, id, const LatLng(35.7, 139.8), name: 'moved');
      case GeometryType.linestring:
        return gpkg.updateLine(table, id, line.reversed.toList(), name: 'moved');
      case GeometryType.polygon:
        return gpkg.updatePolygon(table, id, [ring.reversed.toList()], name: 'moved');
    }
  }

  for (final type in [
    GeometryType.point,
    GeometryType.linestring,
    GeometryType.polygon,
  ]) {
    for (final table in ['Survey points', 'Plot "A"']) {
      test('${type.name}: "$table" に追加・読み出し・更新・削除できる', () async {
        await gpkg.addLayer(table, type);
        await gpkg.addAttributeColumns(table, {
          'name': 'TEXT',
          'tree height': 'REAL',
        });
        final db = await gpkg.getDatabase();
        // QGIS が作る rtree も名前に空白を含む
        await db.execute(
          'CREATE VIRTUAL TABLE ${quoteIdent('rtree_${table}_geom')} '
          'USING rtree(id, minx, maxx, miny, maxy)',
        );

        final id1 = await add(table, type, {'name': 'a', 'tree height': 12.5});
        final id2 = await add(table, type, {'name': 'b', 'tree height': 20.0});
        expect(id1, isNotNull);
        expect(id2, isNotNull);

        final attrs = await gpkg.getFeatureAttributes(table, id1!);
        expect(attrs?['name'], 'a');
        expect(attrs?['tree height'], 12.5);
        expect(await gpkg.getFeatureAttribute(table, id2!, 'tree height'), 20.0);

        final all = await gpkg.getAllFeatureAttributes(
          table,
          columns: ['name', 'tree height'],
        );
        expect(all.map((r) => r['name']), ['a', 'b']);

        final feature = await gpkg.getFeature(table, id1);
        expect(feature?['name'], 'a');
        expect(await gpkg.getFeaturesWithGeometry(table), hasLength(2));

        final rtree = quoteIdent('rtree_${table}_geom');
        expect(await db.rawQuery('SELECT id FROM $rtree ORDER BY id'), hasLength(2));

        expect(
          await gpkg.updateFeatureAttributes(table, id1, {'tree height': 13.0}),
          isTrue,
        );
        expect(await gpkg.updateFeatureAttribute(table, id1, 'name', 'a2'), isTrue);
        expect(await updateGeometry(table, id2, type), isTrue);

        final updated = await gpkg.getFeatureAttributes(table, id1);
        expect(updated?['name'], 'a2');
        expect(updated?['tree height'], 13.0);
        expect(await gpkg.getFeatureAttribute(table, id2, 'name'), 'moved');

        expect(await gpkg.removeFeature(table, id2), isTrue);
        expect(await gpkg.getFeatureAttributes(table, id2), isNull);
        expect(await gpkg.getFeaturesWithGeometry(table), hasLength(1));
        expect(await db.rawQuery('SELECT id FROM $rtree'), [
          {'id': id1},
        ]);
      });
    }
  }
}
