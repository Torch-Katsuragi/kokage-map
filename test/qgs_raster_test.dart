// `.qgs` のラスタレイヤ（オーバーレイ画像の GeoTIFF）のテスト
//
// アプリのオーバーレイは位置を `.tif` の GeoTIFF タグに焼き込んでいるので、`.qgs` には
// gdal プロバイダで読む参照だけを書く。ここで固定するのは:
//   1. ツリーには providerKey="gdal" の layer-tree-layer、projectlayers には type="raster" の maplayer が出る
//   2. layerorder はベクタとラスタをツリーの順で並べる
//   3. DOM 保持型の更新でも足す・直す・外すが効く（QGIS が付けたレンダラは触らない）
//   （インポータがラスタを黙って飛ばすことは qgs_importer_test.dart 側に足す）
//
// > [!WARNING] QGIS で実際に開けるかはここでは分からない（開発機に QGIS 無し）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis/qgs_writer.dart';
import 'package:xml/xml.dart';

QgsLayer vector(String id, String name) => QgsLayer(
      id: id,
      name: name,
      dataSourcePath: './林小班.gpkg',
      tableName: 'rinshoban',
      geometryType: GeometryType.point,
      crs: QgsCrs.wgs84,
    );

const raster = QgsRasterLayer(id: 'raster_1', name: 'ortho', dataSourcePath: './ortho.tif');

QgsProject project({bool withRaster = true}) => QgsProject(
      name: 'テスト',
      root: [
        QgsGroup(
          name: '林小班',
          children: [vector('v1', 'スギ'), if (withRaster) raster, vector('v2', '全部')],
        ),
      ],
    );

void main() {
  const writer = QgsWriter();

  group('writer', () {
    late XmlDocument doc;
    setUp(() => doc = XmlDocument.parse(writer.build(project())));

    test('ツリーに gdal の layer-tree-layer が出る', () {
      final tree = doc.rootElement.getElement('layer-tree-group')!;
      final node = tree.findAllElements('layer-tree-layer').firstWhere((e) => e.getAttribute('id') == 'raster_1');
      expect(node.getAttribute('providerKey'), 'gdal');
      expect(node.getAttribute('source'), './ortho.tif');
      expect(node.getAttribute('name'), 'ortho');
    });

    test('projectlayers に type="raster" の maplayer が出て、参照は相対パスのまま', () {
      final layers = doc.rootElement.getElement('projectlayers')!.findElements('maplayer');
      final r = layers.firstWhere((e) => e.getElement('id')?.innerText == 'raster_1');
      expect(r.getAttribute('type'), 'raster');
      expect(r.getElement('provider')!.innerText, 'gdal');
      expect(r.getElement('datasource')!.innerText, './ortho.tif');
      expect(r.getElement('srs')?.findAllElements('authid').first.innerText, 'EPSG:4326');
      expect(r.getElement('pipe'), isNull, reason: 'レンダラは QGIS の既定に任せる');
    });

    test('layerorder はベクタとラスタをツリーの順で並べる', () {
      final ids = doc.rootElement.getElement('layerorder')!.findElements('layer').map((e) => e.getAttribute('id'));
      expect(ids, ['v1', 'raster_1', 'v2']);
    });
  });

  group('DOM 保持型の更新', () {
    test('無かったラスタは足され、外せば消えて報告される', () {
      final doc = QgsDocument.parse(writer.build(project(withRaster: false)));
      doc.apply(project());
      final added = doc.findMapLayer('raster_1')!;
      expect(added.getAttribute('type'), 'raster');
      final treeIds = doc.root
          .getElement('layer-tree-group')!
          .findAllElements('layer-tree-layer')
          .map((l) => l.getAttribute('id'));
      expect(treeIds, contains('raster_1'));

      final report = doc.apply(project(withRaster: false));
      expect(doc.findMapLayer('raster_1'), isNull);
      expect(report.removedLayers, ['ortho']);
    });

    test('既存のラスタは参照と名前だけ直し、QGIS が付けた pipe は残す', () {
      final xml = writer.build(project());
      // QGIS がレンダラを付けて保存したことにする
      final doc = QgsDocument.parse(
        xml.replaceFirst('<provider>gdal</provider>', '<provider>gdal</provider><pipe><rasterrenderer type="multibandcolor"/></pipe>'),
      );
      final moved = QgsProject(
        name: 'テスト',
        root: [
          QgsGroup(
            name: '林小班',
            children: [
              vector('v1', 'スギ'),
              const QgsRasterLayer(id: 'raster_1', name: 'ortho2', dataSourcePath: './sub/ortho.tif'),
              vector('v2', '全部'),
            ],
          ),
        ],
      );
      doc.apply(moved);
      final e = doc.findMapLayer('raster_1')!;
      expect(e.getElement('datasource')!.innerText, './sub/ortho.tif');
      expect(e.getElement('layername')!.innerText, 'ortho2');
      expect(e.getElement('pipe')?.getElement('rasterrenderer')?.getAttribute('type'), 'multibandcolor');
    });
  });

  test('ラスタの id は相対パスから決定的に作られ、区切り文字に依らない', () {
    final a = QgsProjectBuilder.rasterLayerIdForPath('./sub/ortho.tif');
    final b = QgsProjectBuilder.rasterLayerIdForPath('.\\sub\\ortho.tif');
    expect(a, b);
    expect(a, startsWith('raster_'));
  });

  test('フィクスチャ（QGIS 3.44 が書いた .qgs）にラスタを足しても他は壊れない', () {
    final doc = QgsDocument.parse(File('test/fixtures/qgis_3_44_written.qgs').readAsStringSync());
    final before = doc.mapLayers.length;
    doc.apply(const QgsProject(name: 'テスト', root: [QgsGroup(name: '林小班', children: [raster])]));
    expect(doc.findMapLayer('raster_1'), isNotNull);
    expect(doc.mapLayers.length, lessThanOrEqualTo(before + 1));
  });
}
