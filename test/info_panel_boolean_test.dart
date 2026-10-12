// 情報パネル: 真偽の列（gpkg の BOOLEAN・QGIS のチェックボックス）を「はい／いいえ」で出す。
// 以前は「確認済: true」と生の値が出ていた（2026-10-12 実機、QGIS で作った小班の gpkg）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/qgis_form.dart';
import 'package:root_maps/presentation/attribute_display.dart';
import 'package:root_maps/widgets/feature_detail_panel.dart';
import 'package:root_maps/widgets/info_panel_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('attributeDisplayText', () {
    test('BOOLEAN の列は 1/0 も true/false も読む。読めない値はそのまま', () {
      expect(attributeDisplayText(1, sqlType: 'BOOLEAN'), t.featureDetail.boolTrue);
      expect(attributeDisplayText(0, sqlType: 'BOOLEAN'), t.featureDetail.boolFalse);
      expect(attributeDisplayText('true', sqlType: 'boolean'), t.featureDetail.boolTrue);
      expect(attributeDisplayText('false', sqlType: 'BOOLEAN'), t.featureDetail.boolFalse);
      expect(attributeDisplayText('たぶん', sqlType: 'BOOLEAN'), 'たぶん');
    });

    test('Dart の bool は列の型が分からなくても', () {
      expect(attributeDisplayText(true), t.featureDetail.boolTrue);
      expect(attributeDisplayText(false), t.featureDetail.boolFalse);
    });

    test('真偽の列でなければ 1・true もそのまま', () {
      expect(attributeDisplayText(1, sqlType: 'INTEGER'), '1');
      expect(attributeDisplayText('true', sqlType: 'TEXT'), 'true');
      expect(attributeDisplayText(null, sqlType: 'BOOLEAN'), '');
    });

    test('QGIS のチェックボックス: 決めた値で見分け、決めていなければ 1/0・true/false', () {
      const custom = QgisFieldForm(
        name: 'done',
        widgetType: 'CheckBox',
        config: {'CheckedState': '済', 'UncheckedState': '未'},
      );
      expect(attributeDisplayText('済', form: custom, sqlType: 'TEXT'), t.featureDetail.boolTrue);
      expect(attributeDisplayText('未', form: custom, sqlType: 'TEXT'), t.featureDetail.boolFalse);
      const plain = QgisFieldForm(name: 'done', widgetType: 'CheckBox');
      expect(attributeDisplayText('1', form: plain, sqlType: 'INTEGER'), t.featureDetail.boolTrue);
      expect(attributeDisplayText('false', form: plain, sqlType: 'TEXT'), t.featureDetail.boolFalse);
    });
  });

  testWidgets('BOOLEAN の列（1 と文字の true）を情報パネルで「はい」と出す', (tester) async {
    tester.view.physicalSize = const Size(412, 923);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Directory tmp;
    late GeoPackageFile gpkg;
    late PolygonLayerNode layer;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('info_panel_bool_');
      gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
      await gpkg.addLayer('小班', GeometryType.polygon);
      await gpkg.addAttributeColumns('小班', {'確認済': 'BOOLEAN', '再確認': 'BOOLEAN', 'メモ': 'TEXT'});
      const ring = [LatLng(33.0, 135.0), LatLng(33.0, 135.1), LatLng(33.1, 135.1), LatLng(33.0, 135.0)];
      await gpkg.addPolygonWithAttributes('小班', [ring], {'確認済': 1, '再確認': 'false', 'メモ': 'true'});
      layer = PolygonLayerNode(gpkg, '小班', parent: GeoPackageNode(gpkg));
      await layer.updateChildren();
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await gpkg.dispose();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        // 下パネルに敷いたときと同じく幅いっぱいで
        home: Scaffold(body: InfoPanelFill(child: FeatureDetailPanel(feature: layer.features.single))),
      ),
    ));

    expect(find.text(t.featureDetail.boolTrue), findsOneWidget);
    expect(find.text(t.featureDetail.boolFalse), findsOneWidget);
    // TEXT の列の 'true' はそのまま
    expect(find.text('true'), findsOneWidget);
    expect(find.text('確認済: '), findsOneWidget);
  });
}
