// 属性フォーム・編集パネルの数値の列: 全角で打っても半角の数値として保存する
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/editing/edit_session.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/utils/attribute_columns.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('全角の数字・小数点・符号を半角にする', () {
    expect(toHalfWidthNumber('３３'), '33');
    expect(toHalfWidthNumber('－１２．５'), '-12.5');
    expect(toHalfWidthNumber(' 42 '), '42');
    expect(toHalfWidthNumber('abc'), 'abc');
  });

  test('数値の列を型名で見分ける', () {
    for (final t in ['INTEGER', 'INT', 'MEDIUMINT', 'REAL', 'DOUBLE', 'FLOAT', 'NUMERIC']) {
      expect(isNumericSqlType(t), isTrue, reason: t);
    }
    for (final t in ['TEXT', 'BLOB', 'DATE', '']) {
      expect(isNumericSqlType(t), isFalse, reason: t);
    }
  });

  test('入力の正規化は数値の列の文字だけ', () {
    expect(normalizeAttributeInput('REAL', '１２．５'), '12.5');
    expect(normalizeAttributeInput('TEXT', '１２．５'), '１２．５');
    expect(normalizeAttributeInput('INTEGER', null), isNull);
    expect(normalizeAttributeInput('INTEGER', 3), 3);
  });

  group('編集パネルの属性欄', () {
    late Directory tmp;
    late GeoPackageFile gpkg;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('edit_attr_number_');
      gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    });

    tearDown(() async {
      await gpkg.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('数値の列に全角で打っても半角で保存する（文字の列はそのまま）', () async {
      final layer = (await PointLayerNode.createIn(GeoPackageNode(gpkg), 'pts'))!;
      await gpkg.addAttributeColumns('pts', {'name': 'TEXT', 'h': 'REAL'});
      final p = (await PointFeatureNode.createIn(layer, const LatLng(35.68, 139.76), 'p1', null))!;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final editor = container.read(featureEditorProvider.notifier);
      await editor.start(p);
      expect(container.read(featureEditorProvider)!.columns, containsAll(['name', 'h']));

      editor.setAttr('h', '１２．５');
      editor.setAttr('name', '２号');
      expect(container.read(featureEditorProvider)!.attrs['h'], '12.5');
      expect(await editor.save(), isTrue);
      await gpkg.flushChanges(); // 属性は後ろでまとめて書く

      expect(await gpkg.getFeatureAttribute('pts', p.rowId, 'h'), 12.5);
      expect(await gpkg.getFeatureAttribute('pts', p.rowId, 'name'), '２号');
    });
  });
}
