// QGIS 4.2.0 が保存し直した .qgs（実機の Kitayama-2026 にラスタを足して QGIS で開き、
// subset・消灯・ラスタ不透明度を変えて write() したもの）をアプリ側で DOM 更新しても
// QGIS の設定が残ることを固定する。2026-09-12 に QGIS 本体で確認した往復の片側。
//
// fixture: test/fixtures/qgis_4_2_saved.qgs（tool/qgis/edit_qgs.py の出力）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:xml/xml.dart';

void main() {
  late QgsDocument doc;

  setUp(() {
    doc = QgsDocument.parse(
      File('test/fixtures/qgis_4_2_saved.qgs').readAsStringSync(),
    );
  });

  test('QGIS 4.2 が書いた文書を読める（ベクタ 3 + ラスタ 1、subset 付き）', () {
    final layers = doc.mapLayers.toList();
    expect(layers, hasLength(4));
    final raster = layers.where((e) => e.getAttribute('type') == 'raster');
    expect(raster, hasLength(1));
    final subset = layers
        .map((e) => QgsDataSource.parse(e.getElement('datasource')!.innerText))
        .where((s) => s?.subset != null)
        .map((s) => s!.subset);
    expect(subset, ['area_ha > 5']);
  });

  test('ラスタの id は QGIS で保存し直しても決定的', () {
    final ids = doc.mapLayers.map((e) => e.getElement('id')!.innerText);
    expect(ids, contains(QgsProjectBuilder.rasterLayerIdForPath('./test_overlay.tif')));
  });

  test('DOM 更新で名前と参照は直り、QGIS の pipe と projectCrs は残る', () {
    final layers = <QgsTreeNode>[];
    for (final e in doc.mapLayers) {
      final id = e.getElement('id')!.innerText;
      if (e.getAttribute('type') == 'raster') {
        // アプリ側の名前は元のファイル名（QGIS 側で改名されていても戻す）
        layers.add(QgsRasterLayer(id: id, name: 'test_overlay', dataSourcePath: './test_overlay.tif'));
        continue;
      }
      final ds = QgsDataSource.parse(e.getElement('datasource')!.innerText)!;
      layers.add(QgsLayer(
        id: id,
        name: e.getElement('layername')!.innerText,
        dataSourcePath: ds.path,
        tableName: ds.layerName!,
        geometryType: GeometryType.polygon,
        crs: QgsCrs.wgs84,
      ));
    }
    final report = doc.apply(
      QgsProject(name: 'Kitayama-2026', root: [QgsGroup(name: 'Kitayama-2026', children: layers)]),
    );
    expect(report.removedLayers, isEmpty);
    expect(report.untouchedRenderers, isEmpty);

    final raster = doc.mapLayers.firstWhere((e) => e.getAttribute('type') == 'raster');
    expect(raster.getElement('layername')!.innerText, 'test_overlay');
    final renderer = raster.findAllElements('rasterrenderer').first;
    expect(renderer.getAttribute('opacity'), '0.5', reason: 'QGIS が付けた pipe は触らない');

    final out = doc.toXmlString();
    expect(out, contains('<projectCrs>'));
    expect(out, contains('saveUser="mtmtk"'), reason: 'QGIS 4 の属性は残す');
  });
}
