// QGIS / GDAL で作ったラスタをオーバーレイとして開く（lib/services/gdal_raster_overlay.dart）。
//
// 使う GDAL は gdal_test.dart と同じ（Windows は QGIS 同梱の gdal*.dll、CI は apt の libgdal）。見つからなければ skip。
// 入力は test/fixtures/gdal/ext_*（作り方は make_raster_fixtures.sh）。
// ⚠ gdal_test.dart と同じ理由で sqflite_common_ffi を読み込まない（gpkg の無いフォルダだけ使う）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/external_overlay_image_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/image_node.dart';
import 'package:root_maps/models/nodes/overlay_image_node.dart';
import 'package:root_maps/services/gdal_raster_overlay.dart';
import 'package:root_maps/services/geotiff_service.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import 'support/gdal_host.dart';

const _fx = 'test/fixtures/gdal';
const _ext = [
  'ext_rgb_6674.tif',
  'ext_gray_4326.tif',
  'ext_png.png',
  'ext_png.pgw',
  'ext_png.png.aux.xml',
  'ext_dem_6674.tif',
  'ext_pal_6674.tif',
  'ext_gcp_6674.tif',
];

void main() {
  final config = findHostGdal();
  final skip = config == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null;
  late GdalFfi gdal;
  late Directory tmp;
  late String proj;

  setUpAll(() async {
    if (config == null) return;
    gdal = GdalFfi(config);
  });

  setUp(() async {
    if (config == null) return;
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('gdal_overlay_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    for (final f in _ext) {
      File(p.join(_fx, f)).copySync(p.join(proj, f));
    }
    GdalRasterOverlay.configureForTest(gdal: gdal, cacheDir: p.join(tmp.path, 'cache'));
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
  });

  tearDown(() async {
    if (config == null) return;
    GdalRasterOverlay.configureForTest();
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(proj, name);

  group('判定', () {
    test('GeoTIFF（LZW・タイル・EPSG:6674 ／ Deflate・nodata・EPSG:4326 ／ Float32 の DEM）は位置と座標系が読める', () async {
      final rgb = (await GdalRasterOverlay.probe(at('ext_rgb_6674.tif')))!;
      expect(rgb.epsg, 6674);
      expect(rgb.bandTypes, ['Byte', 'Byte', 'Byte']);
      expect(rgb.needsStretch, isFalse);
      expect(rgb.crsName, contains('JGD2011'));
      expect(rgb.isGeographic, isFalse);

      final gray = (await GdalRasterOverlay.probe(at('ext_gray_4326.tif')))!;
      expect(gray.epsg, 4326);
      expect(gray.isGeographic, isTrue);
      expect(gray.west, closeTo(135.958, 1e-6));
      expect(gray.north, closeTo(33.930, 1e-6));

      final dem = (await GdalRasterOverlay.probe(at('ext_dem_6674.tif')))!;
      expect(dem.bandTypes, ['Float32']);
      expect(dem.needsStretch, isTrue);
    }, skip: skip);

    test('PNG はワールドファイルか .aux.xml があるときだけ GDAL に聞く', () async {
      final names = {for (final f in _ext) f.toLowerCase()};
      expect(GdalRasterOverlay.worthProbing(at('ext_png.png'), names), isTrue);
      expect(GdalRasterOverlay.worthProbing(at('photo.jpg'), names), isFalse);
      expect(GdalRasterOverlay.worthProbing(at('photo.jpg'), {...names, 'photo.jgw'}), isTrue);
      expect(GdalRasterOverlay.worthProbing(at('a.vrt'), const {}), isTrue);
      final png = (await GdalRasterOverlay.probe(at('ext_png.png')))!;
      expect(png.epsg, 6674);
    }, skip: skip);

    test('位置の無い TIFF は null（写真のまま）', () async {
      File(at('plain.tif')).writeAsBytesSync(img.encodeTiff(img.Image(width: 4, height: 3)));
      expect(await GdalRasterOverlay.probe(at('plain.tif')), isNull);
    }, skip: skip);
  });

  group('PNG キャッシュ（gdalwarp → gdal_translate）', () {
    Future<(GdalRasterProbe, GdalRasterRender, img.Image)> renderOf(String name) async {
      final probe = (await GdalRasterOverlay.probe(at(name)))!;
      final r = await GdalRasterOverlay.render(at(name), probe);
      final png = img.decodePng(File(r.pngPath).readAsBytesSync())!;
      return (probe, r, png);
    }

    /// オーバーレイの四隅（回転なし）の外接矩形が gdalinfo の wgs84Extent と 1 画素以内で合う
    void expectBoundsMatch(GdalRasterProbe probe, KMetaImageOverlay params) {
      final node = OverlayImageNode(at('x'), null, ImageMetadata(fileSize: 0), overlayParams: params);
      final c = node.cornerCoordinates;
      final pxLat = (probe.north - probe.south) / params.imageHeight;
      final pxLng = (probe.east - probe.west) / params.imageWidth;
      expect(params.rotation, 0);
      expect(c[0].latitude, closeTo(probe.north, pxLat));
      expect(c[2].latitude, closeTo(probe.south, pxLat));
      expect(c[0].longitude, closeTo(probe.west, pxLng));
      expect(c[2].longitude, closeTo(probe.east, pxLng));
    }

    test('RGB（EPSG:6674）: RGBA の PNG、範囲は wgs84Extent と合う', () async {
      final (probe, r, png) = await renderOf('ext_rgb_6674.tif');
      expect(png.numChannels, 4);
      expect([png.width, png.height], [r.params.imageWidth, r.params.imageHeight]);
      expect(png.width, 40, reason: '長辺は元の画素数（上限 4096）');
      final px = png.getPixel(png.width ~/ 2, png.height ~/ 2);
      expect([px.r, px.g, px.b, px.a], [30, 120, 60, 255]);
      expectBoundsMatch(probe, r.params);
    }, skip: skip);

    test('灰色・nodata（EPSG:4326）: nodata は透明', () async {
      final (probe, r, png) = await renderOf('ext_gray_4326.tif');
      expect(png.numChannels, 2);
      expect(png.getPixel(0, 0).a, 0, reason: '左上は nodata');
      expect(png.getPixel(png.width - 1, png.height - 1).a, 255);
      expectBoundsMatch(probe, r.params);
    }, skip: skip);

    test('PNG ＋ワールドファイル（EPSG:6674）', () async {
      final (probe, r, png) = await renderOf('ext_png.png');
      expect(png.numChannels, 4);
      expectBoundsMatch(probe, r.params);
    }, skip: skip);

    test('Float32 の DEM: 最小〜最大で 0〜255 の灰色に伸ばす（nodata は透明）', () async {
      final (probe, r, png) = await renderOf('ext_dem_6674.tif');
      expect(png.numChannels, 2);
      final values = [
        for (final px in png)
          if (px.a > 0) px.r.toInt(),
      ];
      expect(values, isNotEmpty);
      expect(values.reduce((a, b) => a < b ? a : b), lessThan(30));
      expect(values.reduce((a, b) => a > b ? a : b), greaterThan(225));
      expect(png.any((px) => px.a == 0), isTrue, reason: 'nodata の画素');
      expectBoundsMatch(probe, r.params);
    }, skip: skip);

    test('色表（Palette）: RGBA に開いて色が残り、nodata は透明', () async {
      final (probe, r, png) = await renderOf('ext_pal_6674.tif');
      expect(probe.isPalette, isTrue);
      expect(probe.needsStretch, isFalse);
      expect(png.numChannels, 4);
      final colors = {
        for (final px in png)
          if (px.a > 0) (px.r.toInt(), px.g.toInt(), px.b.toInt()),
      };
      expect(colors, {(255, 0, 0), (0, 255, 0), (0, 0, 255)}, reason: '最近傍なので色表の色だけ');
      expect(png.any((px) => px.a == 0), isTrue, reason: 'nodata（番号 0）の画素');
      expectBoundsMatch(probe, r.params);
    }, skip: skip);

    test('GCP だけのラスタ: 小さくワープして範囲を取り、同じ範囲の GeoTIFF と同じ所に出る', () async {
      final gcp = (await GdalRasterOverlay.probe(at('ext_gcp_6674.tif')))!;
      final ref = (await GdalRasterOverlay.probe(at('ext_rgb_6674.tif')))!;
      expect(gcp.epsg, 6674);
      final (_, r, png) = await renderOf('ext_gcp_6674.tif');
      expect(png.numChannels, 4);
      expectBoundsMatch(ref, r.params);
      expect(Directory(p.join(tmp.path, 'cache')).listSync().where((e) => p.basename(e.path).startsWith('probe_')), isEmpty);
    }, skip: skip);

    test('キャッシュ: 変わらなければ作り直さず、元が変われば作り直す', () async {
      final src = at('ext_rgb_6674.tif');
      final probe = (await GdalRasterOverlay.probe(src))!;
      final first = await GdalRasterOverlay.render(src, probe);
      final t0 = File(first.pngPath).lastModifiedSync();
      final again = await GdalRasterOverlay.render(src, probe);
      expect(again.pngPath, first.pngPath);
      expect(File(again.pngPath).lastModifiedSync(), t0);
      expect(again.params.toJson(), first.params.toJson());

      File(src).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      await GdalRasterOverlay.render(src, probe);
      expect(File(first.pngPath).lastModifiedSync(), isNot(t0));
      expect(Directory(p.join(tmp.path, 'cache')).listSync().map((e) => p.extension(e.path)).toSet(), {'.png', '.json'},
          reason: '作業用の .tif・.aux.xml は残さない');
    }, skip: skip);
  });

  group('フォルダの読み込み', () {
    Future<FolderNode> loadTree() async {
      final root = FolderNode('Home', children: []);
      await root.updateChildren();
      return root;
    }

    test('外のラスタは読み取り専用のオーバーレイ、こかげマップの GeoTIFF は従来どおり編集できる、写真は写真', () async {
      File(at('app.tif')).writeAsBytesSync(img.encodeTiff(img.Image(width: 4, height: 3)));
      await GeoTiffService.updateGeoTiffTags(
        at('app.tif'),
        const KMetaImageOverlay(centerLng: 135.97, centerLat: 33.94, scale: 2, imageWidth: 4, imageHeight: 3),
      );
      File(at('photo.jpg')).writeAsBytesSync(img.encodeJpg(img.Image(width: 4, height: 3)));

      final root = await loadTree();
      final byName = {for (final n in root.children.whereType<ImageNode>()) n.name: n};
      for (final name in [
        'ext_rgb_6674.tif',
        'ext_gray_4326.tif',
        'ext_png.png',
        'ext_dem_6674.tif',
        'ext_pal_6674.tif',
        'ext_gcp_6674.tif',
      ]) {
        expect(byName[name], isA<ExternalOverlayImageNode>(), reason: name);
        expect((byName[name]! as OverlayImageNode).isReadOnly, isTrue);
      }
      final app = byName['app.tif']!;
      expect(app, isA<OverlayImageNode>());
      expect(app, isNot(isA<ExternalOverlayImageNode>()));
      expect((app as OverlayImageNode).isReadOnly, isFalse);
      expect(byName['photo.jpg'].runtimeType, ImageNode);

      // 外のラスタは位置を保存しようとしても書き換えない
      final ext = byName['ext_rgb_6674.tif']! as ExternalOverlayImageNode;
      final before = File(at('ext_rgb_6674.tif')).readAsBytesSync();
      ext.overlayParams = ext.overlayParams.copyWith(centerLng: 0);
      await ext.saveOverlayParams();
      expect(File(at('ext_rgb_6674.tif')).readAsBytesSync(), before);
    }, skip: skip);

    test('削除: 元のファイル一式（.pgw・.aux.xml）と PNG キャッシュを消す', () async {
      final root = await loadTree();
      final node = root.children.whereType<ExternalOverlayImageNode>().firstWhere((n) => n.name == 'ext_png.png');
      final files = (await node.sourceFiles()).map((f) => p.basename(f).toLowerCase()).toSet();
      expect(files, containsAll(['ext_png.png', 'ext_png.pgw', 'ext_png.png.aux.xml']));
      await node.ensureRendered();
      final png = node.cachedPngPath!;
      expect(File(png).existsSync(), isTrue);

      await node.dispose();
      for (final f in ['ext_png.png', 'ext_png.pgw', 'ext_png.png.aux.xml']) {
        expect(File(at(f)).existsSync(), isFalse, reason: f);
      }
      expect(File(png).existsSync(), isFalse);
      expect(File(p.setExtension(png, '.json')).existsSync(), isFalse);
      expect(File(at('ext_rgb_6674.tif')).existsSync(), isTrue, reason: 'ほかのラスタは残る');
    }, skip: skip);

    test('.qgs: 元のファイル・座標系で書き、QGIS で消灯したものを読み戻す', () async {
      final root = await loadTree();
      final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
      final doc = XmlDocument.parse(File(qgs).readAsStringSync());
      XmlElement layerOf(String source) =>
          doc.findAllElements('maplayer').firstWhere((e) => e.getElement('datasource')?.innerText == source);
      final png = layerOf('./ext_png.png');
      expect(png.getElement('provider')?.innerText, 'gdal');
      expect(png.findAllElements('authid').first.innerText, 'EPSG:6674');
      expect(layerOf('./ext_gray_4326.tif').findAllElements('authid').first.innerText, 'EPSG:4326');

      // QGIS 側で PNG を消灯
      final id = png.getElement('id')!.innerText;
      doc.findAllElements('layer-tree-layer').firstWhere((e) => e.getAttribute('id') == id).setAttribute(
            'checked',
            'Qt::Unchecked',
          );
      File(qgs).writeAsStringSync(doc.toXmlString());

      final result = await const QgsImporter().import(qgs, root);
      expect(result.overlayCount, 6);
      expect(result.discarded, isEmpty);
      final nodes = {for (final n in root.children.whereType<ExternalOverlayImageNode>()) n.name: n};
      expect(nodes['ext_png.png']!.visible, isFalse);
      expect(nodes['ext_rgb_6674.tif']!.visible, isTrue);
    }, skip: skip);
  });
}
