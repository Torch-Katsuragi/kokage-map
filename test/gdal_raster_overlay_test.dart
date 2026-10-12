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
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import 'support/gdal_host.dart';
import 'support/legacy_geotiff.dart';

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

    test('同じラスタの呼び出しが重なっても 1 本だけ作り、全員が読める PNG を受け取る', () async {
      // 地図の描き直しはクローン直後・開いた直後に続けて走る。以前は重なった呼び出しが同じ作業用ファイルを
      // 消し合い、「No such file」「Cannot open TIFF image」で落ちていた（2026-10-13）
      final src = at('ext_rgb_6674.tif');
      final probe = (await GdalRasterOverlay.probe(src))!;
      final results = await Future.wait([for (var i = 0; i < 6; i++) GdalRasterOverlay.render(src, probe)]);
      for (final r in results) {
        expect(r.pngPath, results.first.pngPath);
        expect(img.decodePng(File(r.pngPath).readAsBytesSync()), isNotNull);
      }
      // 済んだら次の呼び出しはキャッシュを読む（作り直さない）
      final t0 = File(results.first.pngPath).lastModifiedSync();
      await GdalRasterOverlay.render(src, probe);
      expect(File(results.first.pngPath).lastModifiedSync(), t0);
    }, skip: skip);

    test('QGIS で作った色表の GeoTIFF（EPSG:6674・4 m・nodata 0・Deflate・日本語の名前）: 色と透明と位置', () async {
      // 2026-10-13 Pixel 9 の `林相.tif`（120x90、4 m、1 バンド Byte の色表、nodata 0）と同じ形をその場で作る
      final idx = StringBuffer('ncols 120\nnrows 90\nxllcorner -3700\nyllcorner -229800\ncellsize 4\nNODATA_value 0\n');
      for (var y = 0; y < 90; y++) {
        idx.writeln([for (var x = 0; x < 120; x++) x < 10 && y < 10 ? 0 : 1 + (x ~/ 60) + 2 * (y ~/ 45)].join(' '));
      }
      final work = (await Directory(p.join(tmp.path, 'work')).create()).path;
      File(p.join(work, 'idx.asc')).writeAsStringSync(idx.toString());
      await gdal.translate(p.join(work, 'idx.asc'), p.join(work, 'idx.tif'), args: const ['-ot', 'Byte']);
      File(p.join(work, 'pal.vrt')).writeAsStringSync('''
<VRTDataset rasterXSize="120" rasterYSize="90">
  <VRTRasterBand dataType="Byte" band="1">
    <NoDataValue>0</NoDataValue>
    <ColorInterp>Palette</ColorInterp>
    <ColorTable>
      <Entry c1="0" c2="0" c3="0" c4="255"/>
      <Entry c1="200" c2="30" c3="30" c4="255"/>
      <Entry c1="30" c2="160" c3="60" c4="255"/>
      <Entry c1="40" c2="60" c3="200" c4="255"/>
      <Entry c1="220" c2="200" c3="40" c4="255"/>
    </ColorTable>
    <SimpleSource><SourceFilename relativeToVRT="1">idx.tif</SourceFilename><SourceBand>1</SourceBand></SimpleSource>
  </VRTRasterBand>
</VRTDataset>''');
      await gdal.translate(p.join(work, 'pal.vrt'), at('林相.tif'), args: const [
        '-a_srs', 'EPSG:6674', '-a_ullr', '-3700', '-229440', '-3220', '-229800', '-co', 'COMPRESS=DEFLATE', //
      ]);

      final root = FolderNode('Home', children: []);
      await root.updateChildren();
      final node = root.children.whereType<ExternalOverlayImageNode>().singleWhere((n) => n.name == '林相.tif');
      expect(node.probe.isPalette, isTrue);
      expect(node.probe.epsg, 6674);
      await node.ensureRendered();
      final png = img.decodePng(File(node.cachedPngPath!).readAsBytesSync())!;
      expect(png.numChannels, 4);
      expect([png.width, png.height], [120, 90], reason: '4 m の正方形の画素のまま（地上の縦横比）');
      expect(png.getPixel(2, 2).a, 0, reason: '左上の 10x10 は nodata');
      Iterable<int> rgb(int x, int y) {
        final px = png.getPixel(x, y);
        return [px.r.toInt(), px.g.toInt(), px.b.toInt(), px.a.toInt()];
      }

      expect(rgb(30, 20), [200, 30, 30, 255]);
      expect(rgb(90, 20), [30, 160, 60, 255]);
      expect(rgb(30, 70), [40, 60, 200, 255]);
      expect(rgb(90, 70), [220, 200, 40, 255]);
      expectBoundsMatch(node.probe, node.overlayParams);
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
      // 旧版の形（package:image で書いていた頃）。今の形（GDAL で書く）は geotiff_gdal_write_test.dart
      writeLegacyGeoTiff(
        at('app.tif'),
        img.Image(width: 4, height: 3),
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
