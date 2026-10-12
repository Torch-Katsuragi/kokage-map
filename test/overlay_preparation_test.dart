// オーバーレイ画像の表示用の画像の用意（lib/screens/map_page/overlay_preparation.dart）。
//
// 地図の描き直しは地物・可視性を先に流し、表示用の画像（GDAL のワープ）を後から待つ（2026-10-13）。
// 以前は全オーバーレイの PNG を待ってから流していて、ワープが遅い・止まると gpkg の目を消しても地図が変わらなかった。
// ここでは「PNG ができるまでは描けるものに数えない」「できたら変わったと返す」「1 枚の失敗で他を止めない」を固定する。
//
// GDAL は gdal_raster_overlay_test.dart と同じ（見つからなければ skip）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/nodes/external_overlay_image_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/image_node.dart';
import 'package:root_maps/models/nodes/overlay_image_node.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/screens/map_page/overlay_preparation.dart';
import 'package:root_maps/services/gdal_raster_overlay.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/gdal_host.dart';

void main() {
  final config = findHostGdal();
  final skip = config == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null;
  late Directory tmp;
  late String proj;

  setUp(() async {
    if (config == null) return;
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('overlay_prep_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    for (final f in ['ext_rgb_6674.tif', 'ext_pal_6674.tif']) {
      File(p.join('test/fixtures/gdal', f)).copySync(p.join(proj, f));
    }
    GdalRasterOverlay.configureForTest(gdal: GdalFfi(config), cacheDir: p.join(tmp.path, 'cache'));
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

  Future<List<ExternalOverlayImageNode>> load() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    return root.children.whereType<ExternalOverlayImageNode>().toList();
  }

  test('外のラスタは PNG ができるまで描けるものに数えず、用意したら変わったと返す。2 回目は変わらない', () async {
    final nodes = await load();
    expect(nodes, hasLength(2));
    expect(nodes.where((n) => overlayDrawableNow(n, web: false)), isEmpty, reason: 'GDAL のワープを待たずに流すぶんには入らない');

    expect(await prepareOverlayImages(nodes, web: false), isTrue);
    expect(nodes.every((n) => overlayDrawableNow(n, web: false)), isTrue);
    expect(nodes.every((n) => File(n.cachedPngPath!).existsSync()), isTrue);

    expect(await prepareOverlayImages(nodes, web: false), isFalse, reason: 'キャッシュを使い、形も置き場も同じ');
  }, skip: skip);

  test('1 枚が作れなくても他は用意する', () async {
    final nodes = await load();
    final broken = nodes.firstWhere((n) => n.name == 'ext_rgb_6674.tif');
    File(broken.filePath).deleteSync(); // 判定のあとで消えた（同期で消された など）
    expect(await prepareOverlayImages(nodes, web: false), isTrue);
    expect(overlayDrawableNow(broken, web: false), isFalse);
    expect(overlayDrawableNow(nodes.firstWhere((n) => n.name == 'ext_pal_6674.tif'), web: false), isTrue);
  }, skip: skip);

  test('PNG やアプリの GeoTIFF でない画像はそのまま描ける（web の GeoTIFF も元ファイルを読む）', () {
    OverlayImageNode node(String name) => OverlayImageNode(
          p.join(tmp.path, name),
          null,
          ImageMetadata(fileSize: 0),
          overlayParams: const KMetaImageOverlay(centerLng: 135.96, centerLat: 33.93, scale: 1, imageWidth: 4, imageHeight: 3),
        );
    expect(overlayDrawableNow(node('a.png'), web: false), isTrue);
    expect(overlayDrawableNow(node('a.tif'), web: false), isFalse, reason: 'Android は PNG キャッシュを待つ');
    expect(overlayDrawableNow(node('a.tif'), web: true), isTrue);
  }, skip: skip);
}
