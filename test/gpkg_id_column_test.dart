// 主キーが fid の表・主キーの無い表にある「id」（と主キーでない「fid」）というふつうの列が、
// 自分の値のまま読める・出る・直せる・写せる（ホスト VM）。
//
// 以前は読んだ行の `id` に地物番号（fid・rowid）を入れていて、id の列は属性表・情報パネル・ラベル・描き分けで
// 地物番号に見え、属性表では読み取り専用で直せず、別のレイヤへ写すときも落としていた（2026-10-12）。
// 地物番号は列の名前と重ならない鍵（featureIdKey）に入れ、主キーの列は QGIS と同じく読み取り専用で出す
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
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
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  for (final kind in CollidingColumnsGpkg.values) {
    group(kind.label, () {
      late Directory tmp;
      late String path;
      late GeoPackageFile gpkg;
      late PointLayerNode layer;

      Future<void> open() async {
        tmp = await Directory.systemTemp.createTemp('gpkg_id_col_');
        path = '${tmp.path}/c.gpkg';
        GpkgCrsResolver.instance.clearCache();
        await kind.write(path);
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

      /// こかげマップと別の接続で読んだ列の値（地物番号の順）
      Future<List<Object?>> onDisk(String column) async {
        final db = await openDatabase(path, singleInstance: false, readOnly: true);
        final rows = await db.rawQuery('SELECT "$column" AS v FROM $_table ORDER BY rowid');
        await db.close();
        return [for (final r in rows) r['v']];
      }

      FeatureNode featureAt(int i) => layer.features.firstWhere((f) => f.rowId == CollidingColumnsGpkg.featureIds[i]);

      group('', () {
        setUp(open);
        tearDown(close);

        test('読んだ行: 地物番号は別の鍵、id・fid の列は自分の値', () async {
          expect(await gpkg.getPrimaryKeyColumn(_table), kind.primaryKey);
          final rows = await gpkg.getFeaturesWithGeometry(_table);
          expect([for (final r in rows) r[featureIdKey]], CollidingColumnsGpkg.featureIds);
          expect([for (final r in rows) r['id']], CollidingColumnsGpkg.idValues);
          expect([for (final r in rows) r['fid']], kind.fidValues);
          expect(rows.first.containsKey('rowid'), isFalse, reason: 'rowid は列ではない');

          final one = (await gpkg.getFeature(_table, 2))!;
          expect(one[featureIdKey], 2);
          expect(one['id'], 102);
        });

        test('地物: 番号と属性が分かれ、情報パネルに id の列の値が出る', () async {
          expect([for (final f in layer.features) f.rowId], CollidingColumnsGpkg.featureIds);
          final f = featureAt(0);
          expect(readAttribute(f, 'id'), 101);
          expect(readAttribute(f, 'fid'), kind.fidValues.first);
          expect(f.turfFeature.properties!.keys, isNot(contains(featureIdKey)));
          expect(f.infoMap['id'], '101');
          expect(f.infoMap['fid'], '${kind.fidValues.first}');
        });

        test('ラベル・描き分けの式の "id" は id の列の値', () async {
          final props = layer.effectiveProperties(featureAt(1).turfFeature.properties);
          expect(renderLabelTemplate('"id"', props), '102');
          expect(renderLabelTemplate('{id}', props), '102');
          expect(parseQgisExpression('"id" = 102').test(props), isTrue);
          expect(parseQgisExpression('"id" = 2').test(props), isFalse);
        });

        test('直して保存: ほかの列を直しても id・fid は変わらず、id の列そのものも直せる', () async {
          final f = featureAt(0);
          f.name = 'x';
          await gpkg.flushChanges();
          expect(await onDisk('name'), ['x', 'b']);
          expect(await onDisk('id'), CollidingColumnsGpkg.idValues);
          expect(await onDisk('fid'), kind.fidValues);

          await f.setAttributeValue('id', 555);
          await gpkg.flushChanges();
          expect(await onDisk('id'), [555, 102]);
          expect(await onDisk('fid'), kind.fidValues);

          // 形と名前を書き換えても属性の id は id の列の値のまま
          expect(await (f as PointFeatureNode).updateGeometry(name: 'y', newGeometry: const LatLng(33.95, 135.98)), isTrue);
          await gpkg.flushChanges();
          expect(readAttribute(f, 'id'), 555);
          expect(await onDisk('id'), [555, 102]);
          expect(await onDisk('name'), ['y', 'b']);
        });

        test('編集パネル: id の列は自分の値で出て直せる。主キーは出さない', () async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final editor = container.read(featureEditorProvider.notifier);
          await editor.start(featureAt(0));
          final st = container.read(featureEditorProvider)!;
          expect(st.columns, contains('id'));
          expect(st.columns.contains('fid'), kind.primaryKey != 'fid');
          expect(st.attrs['id'], 101);
          editor.setAttr('id', 333);
          expect(await editor.save(), isTrue);
          await gpkg.flushChanges();
          expect(await onDisk('id'), [333, 102]);
          expect(await onDisk('fid'), kind.fidValues);
        });

        test('新しい地物: id の列は空、主キーの列は振られた番号', () async {
          final f = (await PointFeatureNode.createIn(layer, const LatLng(33.95, 135.98), 'c', null))!;
          expect(f.rowId, 3);
          expect(readAttribute(f, 'id'), isNull);
          if (kind.primaryKey == 'fid') expect(readAttribute(f, 'fid'), 3);
        });

        test('別のレイヤへ写す・足す: id の列（主キーでない）も写る', () async {
          await gpkg.addLayer('copy', GeometryType.point);
          await gpkg.addAttributeColumns('copy', {'name': 'TEXT', 'id': 'INTEGER'});
          expect(await gpkg.duplicateFilteredFeatures(_table, 'copy', '1 = 1'), 2);
          final copied = await gpkg.getFeaturesWithGeometry('copy');
          expect([for (final r in copied) r['id']], CollidingColumnsGpkg.idValues);
          expect([for (final r in copied) r['fid']], [1, 2], reason: '写す先の主キーは振り直す');

          await gpkg.addGeometries('copy', [
            (const geo.Point(geo.Geographic(lon: 135.98, lat: 33.95)), {'name': 'z', 'id': 7, 'fid': 99}),
          ]);
          final last = (await gpkg.getFeaturesWithGeometry('copy')).last;
          expect(last['id'], 7);
          expect(last['fid'], 3, reason: '主キーは書かない');
        });
      });

      testWidgets('属性表: id の列は自分の値で直せる。主キーの列は読み取り専用で出る', (tester) async {
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

        expect(c.columnNames, containsAll(['fid', 'name', 'id']));
        expect(c.canEdit('id'), isTrue);
        expect(c.writableColumnNames, contains('id'));
        // 主キーの fid は読み取り専用（QGIS と同じ）。主キーの無い表の fid はふつうの列
        expect(c.canEdit('fid'), kind.primaryKey != 'fid');
        expect(c.canAlterColumn('fid'), kind.primaryKey != 'fid');

        final rows = c.rows;
        expect([for (final r in rows) r.cells['id']!.value], CollidingColumnsGpkg.idValues);
        expect([for (final r in rows) r.cells['fid']!.value], kind.fidValues);

        final error = await tester.runAsync(() => c.saveAttributeChange(c.features.first, 'id', 777));
        expect(error, isNull);
        await tester.runAsync(gpkg.flushChanges);
        expect(await tester.runAsync(() => onDisk('id')), [777, 102]);
        expect(await tester.runAsync(() => onDisk('fid')), kind.fidValues);

        // 主キーは表から直しても書かない
        await tester.runAsync(() => c.saveAttributeChange(c.features.first, 'fid', 9));
        await tester.runAsync(gpkg.flushChanges);
        if (kind.primaryKey == 'fid') expect(await tester.runAsync(() => onDisk('fid')), kind.fidValues);
      });
    });
  }
}
