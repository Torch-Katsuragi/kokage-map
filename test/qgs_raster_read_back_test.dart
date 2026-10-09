// `.qgs` のラスタの読み戻し（2026-10-09）。
//
// QGIS 側で足した GeoTIFF はオーバーレイ画像の可視性に、XYZ タイルは背景地図に読み戻す。
// dir のファイルが正で、`.qgs` は表示の設定だけを運ぶ（docs/technical/external-formats の「`.qgs` との往復」）。
// fixture `qgis_4_2_raster_xyz.qgs` は QGIS 4.2.2 に書かせた本物（tool/qgis/write_raster_fixture.py）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/basemap_layer.dart';
import 'package:root_maps/models/basemap_provider.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/overlay_image_node.dart';
import 'package:root_maps/services/geotiff_service.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_base_map_import.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis/qgs_raster_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

const _fixture = 'test/fixtures/qgis_4_2_raster_xyz.qgs';

/// こかげマップが書く形の GeoTIFF（ModelTransformationTag）。[geo] が false なら位置タグの無い TIFF
Future<void> _tiff(String path, {bool geo = true}) async {
  File(path).writeAsBytesSync(img.encodeTiff(img.Image(width: 4, height: 3)));
  if (!geo) return;
  await GeoTiffService.updateGeoTiffTags(
    path,
    const KMetaImageOverlay(centerLng: 135.97, centerLat: 33.94, scale: 2, imageWidth: 4, imageHeight: 3),
  );
}

void main() {
  group('部品', () {
    test('XYZ の URI から URL を取り出す（符号化を外す）。本物の WMS は null', () {
      expect(
        QgsRasterSource.xyzUrl(
          'type=xyz&url=https%3A%2F%2Fcyberjapandata.gsi.go.jp%2Fxyz%2Fpale%2F%7Bz%7D%2F%7Bx%7D%2F%7By%7D.png&zmax=18&zmin=0',
        ),
        'https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png',
      );
      expect(QgsRasterSource.xyzUrl('crs=EPSG:4326&format=image/png&layers=foo&styles&url=https://wms.example.com/wms'), isNull);
    });

    test('URL から背景地図の一覧を引く（http/https・OSM のサブドメインを無視）', () {
      expect(BaseMapProvider.findByTileUrl('https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png')?.id, 'gsi_pale');
      expect(BaseMapProvider.findByTileUrl('http://CyberJapanData.gsi.go.jp/xyz/std/{z}/{x}/{y}.png')?.id, 'gsi_std');
      expect(BaseMapProvider.findByTileUrl('https://a.tile.openstreetmap.org/{z}/{x}/{y}.png')?.id, 'osm');
      expect(BaseMapProvider.findByTileUrl('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png')?.id, 'osm');
      expect(BaseMapProvider.findByTileUrl('https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}'), isNull);
      expect(BaseMapProvider.findByTileUrl(''), isNull);
    });

    test('ファイルではないラスタのデータソース', () {
      expect(QgsRasterSource.isNonFileSource('/vsicurl/https://example.com/a.tif'), isTrue);
      expect(QgsRasterSource.isNonFileSource('GPKG:./a.gpkg:ortho'), isTrue);
      expect(QgsRasterSource.isNonFileSource(r'C:\data\a.tif'), isFalse);
      expect(QgsRasterSource.isNonFileSource('./a.tif'), isFalse);
    });

    test('不透明度は <pipe><rasterrenderer opacity> を百分率で（fixture）', () {
      final doc = XmlDocument.parse(File(_fixture).readAsStringSync());
      int opacityOf(String name) => QgsRasterSource.opacityPercent(
            doc.findAllElements('maplayer').firstWhere((e) => e.getElement('layername')?.innerText == name),
          );
      expect(opacityOf('地理院 淡色'), 60);
      expect(opacityOf('オルソ'), 50);
      expect(opacityOf('どこかのタイル'), 100);
    });
  });

  group('背景地図への足し方（端末の設定）', () {
    const pale = QgsBaseMap(providerId: 'gsi_pale', layerName: '地理院 淡色', visible: false, opacity: 60);
    const std = QgsBaseMap(providerId: 'gsi_std', layerName: '地理院', visible: true, opacity: 100);
    const current = [BaseMapLayer(providerId: 'gsi_std', opacity: 80)];

    test('一覧に無いものだけ上に足し、可視・不透明度は .qgs のもの', () {
      final r = QgsBaseMapImport.merge(current, [pale, std], const {});
      expect(r.added, ['gsi_pale']);
      expect(r.layers, [
        const BaseMapLayer(providerId: 'gsi_std', opacity: 80), // 既にあるものは触らない
        const BaseMapLayer(providerId: 'gsi_pale', visible: false, opacity: 60),
      ]);
    });

    test('一度 .qgs から足したものは、消されていても二度と足さない', () {
      final r = QgsBaseMapImport.merge(current, [pale], const {'gsi_pale'});
      expect(r.added, isEmpty);
      expect(r.layers, current);
    });

    test('同じプロバイダが何枚あっても 1 枚', () {
      final r = QgsBaseMapImport.merge(const [], [pale, pale], const {});
      expect(r.added, ['gsi_pale']);
      expect(r.layers, hasLength(1));
    });
  });

  group('インポータ（QGIS 4.2.2 が書いた fixture）', () {
    late Directory tmp;
    late String proj;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      KMetaService.instance.clearCache();
      tmp = await Directory.systemTemp.createTemp('qgs_raster_');
      proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
      await Directory(p.join(tmp.path, 'outside')).create();
      ProjectPathResolver.instance.setRootPathGetter(() => proj);
      File(_fixture).copySync(p.join(proj, 'proj.qgs'));
      File(p.join(proj, 'scan.png')).writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 3)));
      await _tiff(p.join(tmp.path, 'outside', 'kyoyu.tif'));
    });

    tearDown(() async {
      KMetaService.instance.clearCache();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<FolderNode> loadTree() async {
      final root = FolderNode('Home', children: []);
      await root.updateChildren();
      return root;
    }

    test('GeoTIFF は可視性をオーバーレイに、XYZ は背景地図として返し、扱えないものは理由つきで報告する', () async {
      await _tiff(p.join(proj, 'ortho.tif'));
      await _tiff(p.join(proj, 'hidden.tif'));
      final root = await loadTree();
      expect(root.children.whereType<OverlayImageNode>(), hasLength(2));

      final result = await const QgsImporter().import(p.join(proj, 'proj.qgs'), root);

      expect(result.overlayCount, 2);
      final hidden = root.children.whereType<OverlayImageNode>().firstWhere((n) => n.name == 'hidden.tif');
      expect(hidden.visible, isFalse, reason: 'QGIS で消灯していた');
      KMetaService.instance.clearCache();
      final meta = await KMetaService.instance.getMeta(proj);
      expect(meta.visibility.images['hidden.tif'], isFalse, reason: 'フォルダ設定にも書かれる');
      expect(meta.visibility.images['ortho.tif'] ?? true, isTrue);

      expect(result.baseMaps, hasLength(1));
      final pale = result.baseMaps.single;
      expect(pale.providerId, 'gsi_pale');
      expect(pale.visible, isFalse);
      expect(pale.opacity, 60);

      expect(result.discarded, containsAll(<Matcher>[
        contains('スキャン（GeoTIFF 以外のラスタは未対応）'),
        contains('共有オルソ（プロジェクトフォルダの外を参照している）'),
        contains('どこかのタイル（背景地図の一覧に無い XYZ タイル: tiles.example.com）'),
        contains('何かの WMS（WMS は未対応）'),
      ]));
      expect(result.discarded, hasLength(4));
    });

    test('位置を読めない TIFF・無いファイルは理由つきで報告する', () async {
      await _tiff(p.join(proj, 'ortho.tif'), geo: false); // GDAL の既定の形などは写真として並ぶ
      final root = await loadTree();
      final result = await const QgsImporter().import(p.join(proj, 'proj.qgs'), root);
      expect(result.overlayCount, 0);
      expect(result.discarded, contains(contains('オルソ（ortho.tif の位置を読めません')));
      expect(result.discarded, contains('hidden（hidden.tif が見つかりません）'));
    });

    test('こかげマップが書いた形では、dir グループを消灯してもオーバーレイ自身は点いたまま', () async {
      await Directory(p.join(proj, 'sub')).create();
      await _tiff(p.join(proj, 'sub', 'a.tif'));
      File(p.join(proj, 'proj.qgs')).deleteSync();
      final root = await loadTree();
      for (final c in root.children.whereType<FolderNode>()) {
        await c.updateChildren();
      }
      final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
      final doc = XmlDocument.parse(File(qgs).readAsStringSync());
      doc.findAllElements('layer-tree-group').firstWhere((g) => g.getAttribute('name') == 'sub').setAttribute(
            'checked',
            'Qt::Unchecked',
          );
      File(qgs).writeAsStringSync(doc.toXmlString());

      final result = await const QgsImporter().import(qgs, root);
      expect(result.overlayCount, 1);
      final sub = root.children.whereType<FolderNode>().single;
      expect(sub.children.whereType<OverlayImageNode>().single.visible, isTrue);
    });
  });

  group('書き戻し（QgsDocument.apply）', () {
    late QgsDocument doc;
    const ortho = QgsRasterLayer(id: 'raster_app', name: 'ortho', dataSourcePath: './ortho.tif');

    setUp(() {
      doc = QgsDocument.parse(File(_fixture).readAsStringSync());
      doc.apply(const QgsProject(name: 'proj', root: [ortho]));
    });

    List<String?> treeIds() =>
        doc.root.getElement('layer-tree-group')!.findAllElements('layer-tree-layer').map((e) => e.getAttribute('id')).toList();

    test('QGIS で足した XYZ・WMS は外さずに残す（ツリーの一番下・layerorder の後ろ）', () {
      final names = doc.mapLayers.map((e) => e.getElement('layername')!.innerText).toSet();
      expect(names, containsAll(['地理院 淡色', 'どこかのタイル', '何かの WMS']));
      final xyz = doc.mapLayers.firstWhere((e) => e.getElement('layername')!.innerText == '地理院 淡色');
      final xyzId = xyz.getElement('id')!.innerText;
      expect(treeIds().first, 'raster_app');
      expect(treeIds(), contains(xyzId));
      final order = doc.root.getElement('layerorder')!.findElements('layer').map((e) => e.getAttribute('id')).toList();
      expect(order.first, 'raster_app');
      expect(order, contains(xyzId));
      // 消灯したまま残る
      final treeXyz = doc.root.findAllElements('layer-tree-layer').firstWhere((e) => e.getAttribute('id') == xyzId);
      expect(treeXyz.getAttribute('checked'), 'Qt::Unchecked');
    });

    test('同じ GeoTIFF を指す QGIS のラスタはアプリの id に付け替え、不透明度（pipe）を残す', () {
      final e = doc.findMapLayer('raster_app')!;
      expect(e.getElement('pipe')?.getElement('rasterrenderer')?.getAttribute('opacity'), '0.5');
      expect(doc.mapLayers.where((m) => m.getElement('datasource')!.innerText == './ortho.tif'), hasLength(1));
    });

    test('アプリに無いファイルのラスタは従来どおり外す', () {
      final sources = doc.mapLayers.map((e) => e.getElement('datasource')!.innerText).toList();
      expect(sources, isNot(contains('./scan.png')));
      expect(sources, isNot(contains('../outside/kyoyu.tif')));
    });

    test('2 回目の apply で変わらない（積み上がらない）', () {
      final once = doc.toXmlString();
      doc.apply(const QgsProject(name: 'proj', root: [ortho]));
      expect(doc.toXmlString(), once);
    });
  });
}
