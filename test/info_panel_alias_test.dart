// 情報パネル: QGIS の属性フォームの設定があれば、QGIS の「地物情報の表示」と同じく
// 列は別名、ValueMap・ValueRelation は表示名で出す。以前は「直径: 24」と列名のまま出ていた（2026-10-12 実機）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/qgis_form.dart';
import 'package:root_maps/presentation/attribute_display.dart';
import 'package:root_maps/presentation/feature_display_name.dart';
import 'package:root_maps/services/qgis_form_options.dart';
import 'package:root_maps/widgets/feature_detail_panel.dart';
import 'package:root_maps/widgets/info_panel_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _speciesMap = QgisFieldForm(
  name: '樹種',
  alias: '樹種名',
  widgetType: 'ValueMap',
  config: {
    'map': [
      {'スギ': 'SUGI'},
      {'ヒノキ': 'HINOKI'},
    ],
  },
);

const _ownerRelation = QgisFieldForm(
  name: '所有者',
  widgetType: 'ValueRelation',
  config: {'Key': 'id', 'Value': 'name', 'AllowMulti': true},
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('attributeLabel / attributeDisplayText', () {
    test('別名があれば別名、無ければ列名', () {
      const form = QgisForm(fields: {'直径': QgisFieldForm(name: '直径', alias: '胸高直径（cm）')});
      expect(attributeLabel('直径', form), '胸高直径（cm）');
      expect(attributeLabel('樹高', form), '樹高');
      expect(attributeLabel('直径', null), '直径');
    });

    test('ValueMap は表示名、選択肢に無い値はそのまま', () {
      expect(attributeDisplayText('HINOKI', form: _speciesMap), 'ヒノキ');
      expect(attributeDisplayText('MATSU', form: _speciesMap), 'MATSU');
    });

    test('ValueRelation は参照先の値。複数選択の {a,b} もつなぐ。選択肢が無ければ値のまま', () {
      const opts = [QgisValueOption('1', '山田'), QgisValueOption('2', '鈴木')];
      expect(attributeDisplayText(2, form: _ownerRelation, relationOptions: opts), '鈴木');
      expect(attributeDisplayText('{1,2}', form: _ownerRelation, relationOptions: opts), '山田, 鈴木');
      expect(attributeDisplayText(9, form: _ownerRelation, relationOptions: opts), '9');
      expect(attributeDisplayText(2, form: _ownerRelation), '2');
    });
  });

  testWidgets('情報パネルで別名・ValueMap の表示名・ValueRelation の表示名を出す（Hidden の列も出す）', (tester) async {
    tester.view.physicalSize = const Size(412, 923);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Directory tmp;
    late GeoPackageFile gpkg;
    late PointLayerNode layer;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('info_panel_alias_');
      gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
      await gpkg.addLayer('立木', GeometryType.point);
      await gpkg.addAttributeColumns('立木', {'直径': 'INTEGER', '樹種': 'TEXT', '所有者': 'INTEGER', '内部': 'TEXT'});
      await gpkg.addPointWithAttributes(
        '立木',
        const LatLng(33.0, 135.0),
        {'直径': 24, '樹種': 'SUGI', '所有者': 2, '内部': 'x1'},
      );
      layer = PointLayerNode(gpkg, '立木', parent: GeoPackageNode(gpkg));
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

    final form = QgisForm(fields: {
      '直径': const QgisFieldForm(name: '直径', alias: '胸高直径（cm）'),
      '樹種': _speciesMap,
      '所有者': _ownerRelation,
      '内部': const QgisFieldForm(name: '内部', alias: '内部番号', widgetType: 'Hidden'),
    });
    layer.debugQgisForm = form;
    QgisFormOptions.debugSetRelations(form, {
      '所有者': const [QgisValueOption('1', '山田'), QgisValueOption('2', '鈴木')],
    });

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: InfoPanelFill(child: FeatureDetailPanel(feature: layer.features.single))),
      ),
    ));
    await tester.pump();

    expect(find.text('胸高直径（cm）: '), findsOneWidget);
    expect(find.text('直径: '), findsNothing);
    expect(find.text('24'), findsOneWidget);
    expect(find.text('樹種名: '), findsOneWidget);
    expect(find.text('スギ'), findsOneWidget);
    expect(find.text('SUGI'), findsNothing);
    expect(find.text('所有者: '), findsOneWidget);
    expect(find.text('鈴木'), findsOneWidget);
    // Hidden の列も出す（QGIS の地物情報の表示と同じ）
    expect(find.text('内部番号: '), findsOneWidget);
    expect(find.text('x1'), findsOneWidget);

    // 地物を見分ける文字（検索の結果）も別名で
    expect(featureIdentifier(layer.features.single, maxFields: 1), startsWith('樹種名: '));
  });
}
