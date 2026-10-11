// 形の列が geom の表にある「geometry」というふつうの列が、自分の値のまま読める・出る・直せる・写せる（ホスト VM）。
//
// 以前は読んだ行の `geometry` に解いた形を入れていて、geometry の列は属性に出ず（属性表・情報パネル・ラベル）、
// 属性表では読み取り専用、別のレイヤへ写す・足すときも落としていた（2026-10-12）。
// 解いた形は列の名前と重ならない鍵（featureGeometryKey）に入れる
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/converters/turf_converter.dart';
import 'package:root_maps/editing/edit_session.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/coordinate/index.dart';
import 'package:root_maps/utils/attribute_columns.dart';
import 'package:root_maps/utils/label_template.dart';
import 'package:root_maps/utils/qgis_expression.dart';
import 'package:root_maps/widgets/attribute_table/attribute_table_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/colliding_columns_gpkg.dart';

const _table = CollidingColumnsGpkg.table;

void main() {
  late Directory tmp;
  late String path;
  late GeoPackageFile gpkg;
  late PointLayerNode layer;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> open() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_geometry_attr_');
    path = '${tmp.path}/c.gpkg';
    GpkgCrsResolver.instance.clearCache();
    await writeGeometryAttributeGpkg(path);
    gpkg = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
    layer = PointLayerNode(gpkg, _table, parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
  }

  Future<void> close() async {
    await gpkg.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }

  /// こかげマップと別の接続で読んだ列の値（fid の順）
  Future<List<Object?>> onDisk(String column) async {
    final db = await openDatabase(path, singleInstance: false, readOnly: true);
    final rows = await db.rawQuery('SELECT "$column" AS v FROM $_table ORDER BY fid');
    await db.close();
    return [for (final r in rows) r['v']];
  }

  PointFeatureNode featureAt(int i) => layer.features.firstWhere((f) => f.rowId == i + 1) as PointFeatureNode;

  group('', () {
    setUp(open);
    tearDown(close);

    test('読んだ行: 解いた形は別の鍵、geometry の列は自分の値、形の列は残らない', () async {
      expect(await gpkg.geometryColumn(_table), 'geom');
      final rows = await gpkg.getFeaturesWithGeometry(_table);
      expect([for (final r in rows) r['geometry']], ['g-a', 'g-b']);
      expect((rows.first[featureGeometryKey] as List<LatLng>).single, const LatLng(33.93, 135.96));
      expect(rows.first.containsKey('geom'), isFalse);

      final one = (await gpkg.getFeature(_table, 2))!;
      expect(one['geometry'], 'g-b');
      expect((one[featureGeometryKey] as List<LatLng>).single, const LatLng(33.94, 135.97));

      final f = TurfConverter.createFeatureFromRow(rows.first, 'point')!;
      expect(f.properties!['geometry'], 'g-a');
      expect(f.properties!.keys, isNot(contains(featureGeometryKey)));
      expect(TurfConverter.featureToRowData(f)!['geometry'], 'g-a');
    });

    test('地物: 形が出て、情報パネル・ラベル・描き分けの式に geometry の列の値が出る', () async {
      expect(layer.features, hasLength(2));
      final f = featureAt(1);
      expect(f.point, const LatLng(33.94, 135.97));
      expect(readAttribute(f, 'geometry'), 'g-b');
      expect(f.infoMap['geometry'], 'g-b');
      final props = layer.effectiveProperties(f.turfFeature.properties);
      expect(renderLabelTemplate('"geometry"', props), 'g-b');
      expect(parseQgisExpression(""""geometry" = 'g-b'""").test(props), isTrue);
    });

    test('直して保存: geometry の列は書け、形は変わらない', () async {
      final f = featureAt(0);
      await f.setAttributeValue('geometry', 'g-x');
      f.name = 'x';
      await gpkg.flushChanges();
      expect(await onDisk('geometry'), ['g-x', 'g-b']);
      expect(await onDisk('name'), ['x', 'b']);

      expect(await f.updateLocation(const LatLng(33.95, 135.98)), isTrue);
      await gpkg.flushChanges();
      expect(await onDisk('geometry'), ['g-x', 'g-b']);
      final back = (await gpkg.getFeature(_table, 1))!;
      expect((back[featureGeometryKey] as List<LatLng>).single, const LatLng(33.95, 135.98));
      expect(back['geometry'], 'g-x');
    });

    test('編集パネル: geometry の列が出て直せる', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final editor = container.read(featureEditorProvider.notifier);
      await editor.start(featureAt(0));
      final st = container.read(featureEditorProvider)!;
      expect(st.columns, contains('geometry'));
      expect(st.attrs['geometry'], 'g-a');
      editor.setAttr('geometry', 'g-y');
      expect(await editor.save(), isTrue);
      await gpkg.flushChanges();
      expect(await onDisk('geometry'), ['g-y', 'g-b']);
    });

    test('別のレイヤへ写す・足す・移す: geometry の列も写る', () async {
      await gpkg.addLayer('copy', GeometryType.point);
      await gpkg.addAttributeColumns('copy', {'name': 'TEXT', 'geometry': 'TEXT'});
      expect(await gpkg.duplicateFilteredFeatures(_table, 'copy', '1 = 1'), 2);
      expect([for (final r in await gpkg.getFeaturesWithGeometry('copy')) r['geometry']], ['g-a', 'g-b']);

      await gpkg.addGeometries('copy', [
        (const geo.Point(geo.Geographic(lon: 135.98, lat: 33.95)), {'name': 'z', 'geometry': 'g-z'}),
      ]);
      final last = (await gpkg.getFeaturesWithGeometry('copy')).last;
      expect(last['geometry'], 'g-z');
      expect((last[featureGeometryKey] as List<LatLng>).single, const LatLng(33.95, 135.98));
    });
  });

  testWidgets('属性表: geometry の列が自分の値で出て直せる', (tester) async {
    await tester.runAsync(open);
    addTearDown(() => tester.runAsync(close));
    AttributeTableController? ctrl;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          ctrl ??= AttributeTableController(layer, ref);
          return const SizedBox();
        }),
      ),
    ));
    final c = ctrl!;
    await tester.runAsync(c.initialize);

    expect(c.columnNames, containsAll(['name', 'geometry']));
    expect(c.columnNames, isNot(contains('geom')));
    expect(c.canEdit('geometry'), isTrue);
    expect([for (final r in c.rows) r.cells['geometry']!.value], ['g-a', 'g-b']);

    expect(await tester.runAsync(() => c.saveAttributeChange(c.features.first, 'geometry', 'g-t')), isNull);
    await tester.runAsync(gpkg.flushChanges);
    expect(await tester.runAsync(() => onDisk('geometry')), ['g-t', 'g-b']);
  });
}
