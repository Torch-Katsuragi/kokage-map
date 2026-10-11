// 形の列が geom 以外（GeoPandas の geometry・ArcGIS Pro の Shape）の gpkg を読み書きできる（ホスト VM）。
//
// 以前は FeatureRepository が geom 列を決め打ちしていて、地物が出ず（形が読まれない）、
// 追加は `no column named geom` で落ちた（2026-10-12）。形の列は gpkg_geometry_columns から表ごとに引く
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/converters/turf_converter.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/coordinate/index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/foreign_geom_gpkg.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_geomcol_');
    GpkgCrsResolver.instance.clearCache();
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  for (final kind in ForeignGeomGpkg.all) {
    group(kind.label, () {
      late String path;
      late GeoPackageFile gpkg;
      final table = kind.table;
      final hasGeomAttr = kind.extraColumns.containsKey('geom');

      setUp(() async {
        path = '${tmp.path}/f.gpkg';
        await kind.write(path);
        gpkg = GeoPackageFile(const ['f.gpkg'], absolutePath: path);
      });
      tearDown(() => gpkg.dispose());

      /// rtree の中身（id → minx, miny）。こかげマップと別の接続で読む
      Future<Map<int, (double, double)>> rtree() async {
        final db = await gpkg.getDatabase();
        return {
          for (final r in await db.rawQuery('SELECT id, minx, miny FROM "${kind.rtree}" ORDER BY id'))
            r['id']! as int: ((r['minx']! as num).toDouble(), (r['miny']! as num).toDouble()),
        };
      }

      LatLng pointOf(Map<String, dynamic> row) => (row['geometry'] as List<LatLng>).single;

      test('形の列を表から引く（表にある綴りのまま）', () async {
        expect(await gpkg.geometryColumn(table), kind.geomColumn);
        expect(await gpkg.geometryColumn(table.toLowerCase()), kind.geomColumn);
        expect(await gpkg.getPrimaryKeyColumn(table), kind.pk);
      });

      test('読む: 形が出て、形の列は属性に残らない', () async {
        final rows = await gpkg.getFeaturesWithGeometry(table);
        expect(rows, hasLength(2));
        expect(pointOf(rows.first).longitude, closeTo(135.96, 1e-9));
        expect(pointOf(rows.last).latitude, closeTo(33.94, 1e-9));
        expect([for (final r in rows) r['name']], ['a', 'b']);
        for (final r in rows) {
          if (kind.geomColumn != 'geometry') expect(r.containsKey(kind.geomColumn), isFalse);
        }
        // geom という名前のふつうの列は属性のまま
        if (hasGeomAttr) expect(rows.first['geom'], 'geom-a');

        // 地物（turf）の属性にも形の列は入らず、geom の列は入る
        final f = TurfConverter.createFeatureFromRow(rows.first, 'point')!;
        expect(f.properties!.keys, isNot(contains(kind.geomColumn)));
        if (hasGeomAttr) expect(f.properties!['geom'], 'geom-a');
        expect(TurfConverter.featureToRowData(f)!.keys, hasGeomAttr ? contains('geom') : isNot(contains('geom')));
      });

      test('地物を選ぶ（1 件読む）', () async {
        final row = (await gpkg.getFeature(table, 2))!;
        expect(row[featureIdKey], 2);
        expect(pointOf(row).longitude, closeTo(135.97, 1e-9));
        expect(row.containsKey(kind.geomColumn) && kind.geomColumn != 'geometry', isFalse);
      });

      test('属性表・情報の列: 本当の形の列だけを隠す', () async {
        final columns = await gpkg.getColumnNames(table, getAll: true);
        expect(columns.map((c) => c.toLowerCase()), isNot(contains(kind.geomColumn.toLowerCase())));
        expect(columns, contains('name'));
        expect(columns.contains('geom'), hasGeomAttr);

        final info = [for (final c in await gpkg.getAttributeColumnInfo(table)) c['name']];
        expect(info, isNot(contains(kind.geomColumn)));
        expect(info.contains('geom'), hasGeomAttr);

        // 地図の検索も形の列を見ない（geom の列は見る）
        final hits = await gpkg.searchAttributeRows(table, ['b']);
        expect([for (final h in hits) h['__id']], [2]);
        expect(hits.single.keys, isNot(contains(kind.geomColumn)));
        if (hasGeomAttr) expect(hits.single['geom'], 'geom-b');
      });

      test('足す: 形の列に入り、rtree にも載る', () async {
        final id = await gpkg.addPointWithAttributes(table, const LatLng(34.0, 136.0), {'name': 'c'});
        expect(id, 3);
        final row = (await gpkg.getFeature(table, id!))!;
        expect(row['name'], 'c');
        expect(pointOf(row).latitude, closeTo(34.0, 1e-9));
        expect((await rtree())[3]!.$1, closeTo(136.0, 1e-6));

        final ids = await gpkg.addPointsBatch(table, [
          {'point': const LatLng(34.1, 136.1), 'name': 'd', if (hasGeomAttr) 'geom': 'geom-d'},
        ]);
        expect(ids, [4]);
        final d = (await gpkg.getFeature(table, 4))!;
        expect(pointOf(d).longitude, closeTo(136.1, 1e-9));
        if (hasGeomAttr) expect(d['geom'], 'geom-d');
        expect((await rtree()).keys, [1, 2, 3, 4]);
      });

      test('書き換える: 形（rtree も）と属性', () async {
        expect(await gpkg.updatePoint(table, 1, const LatLng(35.0, 137.0), name: 'A'), isTrue);
        var row = (await gpkg.getFeature(table, 1))!;
        expect(pointOf(row).longitude, closeTo(137.0, 1e-9));
        expect((await rtree())[1]!.$2, closeTo(35.0, 1e-6));

        // 属性の一括更新: 形の列の名前で値を渡しても形は壊さない。geom の列（ふつうの列）は書く
        expect(
          await gpkg.updateFeatureAttributes(table, 1, {
            'name': 'AA',
            kind.geomColumn: 'not a geometry',
            if (hasGeomAttr) 'geom': 'geom-AA',
          }),
          isTrue,
        );
        row = (await gpkg.getFeature(table, 1))!;
        expect(row['name'], 'AA');
        expect(pointOf(row).longitude, closeTo(137.0, 1e-9));
        if (hasGeomAttr) expect(row['geom'], 'geom-AA');
      });

      test('消す: 行も rtree も消える', () async {
        expect(await gpkg.removeFeature(table, 1), isTrue);
        expect([for (final r in await gpkg.getFeaturesWithGeometry(table)) r[featureIdKey]], [2]);
        expect((await rtree()).keys, [2]);
      });

      /// 属性表の「別レイヤに複製」と同じ: geom のレイヤを作り、元の属性の列（形の列は除かれる）を足す
      Future<void> makeTarget(String name) async {
        await gpkg.addLayer(name, GeometryType.point);
        for (final c in await gpkg.getAttributeColumnInfo(table)) {
          final n = (c['name'] as String).toLowerCase();
          if (n != 'geom' && n != 'fid' && n != 'id') await gpkg.addAttributeColumn(name, c['name'] as String, c['type'] as String);
        }
      }

      test('別のレイヤへ写す: 形の列の名前が違っても（→ geom）形が移る', () async {
        await makeTarget('copy');
        expect(await gpkg.geometryColumn('copy'), 'geom');
        // 写す先に元の形の列の名前の列を作らない
        expect((await gpkg.getTableColumns('copy')).map((c) => c.toLowerCase()), isNot(contains(kind.geomColumn.toLowerCase())));
        expect(await gpkg.copyFeaturesBetweenLayers(table, 'copy'), 2);
        final rows = await gpkg.getFeaturesWithGeometry('copy');
        expect([for (final r in rows) r['name']], ['a', 'b']);
        expect(pointOf(rows.last).latitude, closeTo(33.94, 1e-9));

        // 絞り込んで複製
        await makeTarget('dup');
        expect(await gpkg.duplicateFilteredFeatures(table, 'dup', "name = 'b'"), 1);
        expect(pointOf((await gpkg.getFeaturesWithGeometry('dup')).single).longitude, closeTo(135.97, 1e-9));
      });

      test('作り直したレイヤ・名前を変えたレイヤでも形の列を引き直す', () async {
        await gpkg.renameLayer(table, 'renamed');
        expect(await gpkg.geometryColumn('renamed'), kind.geomColumn);
        expect(await gpkg.getFeaturesWithGeometry('renamed'), hasLength(2));
        // 新しいレイヤは geom（QGIS の既定）で作る
        await gpkg.addLayer('fresh', GeometryType.point);
        expect(await gpkg.geometryColumn('fresh'), 'geom');
        expect(await gpkg.addPointWithAttributes('fresh', const LatLng(33.0, 135.0), {}), 1);
      });
    });
  }
}
