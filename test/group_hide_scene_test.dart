// gpkg（グループ）の目を消したら、中の View の地物が地図に流れず、焼き込みも焼き直しになる（2026-10-13）。
//
// Pixel 9 で QGIS から持ってきた gpkg（View 3 枚の小班）の目を消しても、林齢の View の色の面が出たままだった。
// 地図ページ（MapFeatureCacheMixin.updateFeatures → syncFeatureSources）と同じ手順を部品で辿り、
// 「見えるレイヤ → 地物 → GeoJSON の中身の世代と変わった範囲 → 3D の焼き込みの台帳」が消灯を運ぶことを固定する。
// 地図ページでは、これより前にオーバーレイの表示用の画像（GDAL）を待っていたのが止まる元だった（overlay_preparation_test.dart）
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/terrain/feature_bake_ledger.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/view_node.dart';
import 'package:root_maps/screens/map_page/feature_geojson_cache.dart';
import 'package:root_maps/tutorial/practice_project.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('group_hide_');
    final proj = await PracticeProject.recreate(at: p.join(tmp.path, 'practice'));
    gpkg = GeoPackageFile([p.basename(proj.gpkgPath)], absolutePath: proj.gpkgPath);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 地図ページと同じ選び方: 見えるレイヤのうち、見える View のあるものの面
  List<PolygonFeatureNode> visiblePolygons(FolderNode root) => [
        for (final l in root.getVisibleLayerNodes().whereType<PolygonLayerNode>())
          if (l.hasVisibleView) ...l.children.whereType<PolygonFeatureNode>().where((f) => !f.isDisposed),
      ];

  FeatureGeoJsonInput input(List<PolygonFeatureNode> polys) => FeatureGeoJsonInput(
        lines: const [],
        polygons: polys,
        points: const [],
        photos: const [],
        selected: const {},
        stylePropKey: 'k-style',
        lineVertices: false,
        polygonVertices: false,
      );

  test('gpkg を消灯すると View 3 枚の面がどれも流れず、面の掛かるタイルが焼き直しになる', () async {
    final root = FolderNode('Home', children: []);
    final gpkgNode = GeoPackageNode(gpkg, parent: root);
    root.children.add(gpkgNode);
    final layer = PolygonLayerNode(gpkg, PracticeProject.areaLayer, parent: gpkgNode);
    gpkgNode.children.add(layer);
    layer.views.addAll([
      ViewNode(name: '樹種', parent: layer),
      ViewNode(name: '林齢', parent: layer),
      ViewNode(name: 'ルール', parent: layer),
    ]);
    await layer.updateChildren();

    final cache = FeatureGeoJsonCache()..rebuildAll(input(visiblePolygons(root)));
    expect(cache.polygons, isNotEmpty);

    // 面の掛かる z15 のタイルを今の世代で焼いた
    final at = layer.getAllCoordinates().first;
    final mx = WebMercator.xFromLon(at.longitude), my = WebMercator.yFromLat(at.latitude);
    final tile = TileKey(15, WebMercator.tileXAt(mx, 15), WebMercator.tileYAt(my, 15));
    final ledger = FeatureBakeLedger(fillsOnlyAbove: 13)..addEvent(null);
    for (final k in ledger.takeStale([tile])) {
      ledger
        ..composed(k)
        ..applied(k);
    }
    expect(ledger.takeStale([tile]), isEmpty);

    // gpkg の目を消す（子の View・レイヤの目はそのまま）
    gpkgNode.visible = false;
    expect(layer.views.every((v) => v.visible), isTrue);
    final rev = cache.contentRevision;
    cache.rebuildAll(input(visiblePolygons(root)));
    expect(cache.polygons, isEmpty, reason: '親の消灯は View にも効く');
    expect(cache.contentRevision, greaterThan(rev));
    expect(cache.lastChangeHasFills, isTrue);

    // 地図面（_onSceneRevision）と同じく、変わった範囲を Mercator にして台帳に積む
    final c = cache.lastChangeLonLat!;
    ledger.addEvent(Rect.fromLTRB(
      WebMercator.xFromLon(c.left),
      WebMercator.yFromLat(c.top),
      WebMercator.xFromLon(c.right),
      WebMercator.yFromLat(c.bottom),
    ).inflate(50));
    expect(ledger.takeStale([tile]), {tile}, reason: '寄った段（塗りだけ焼く）でも面が消えたら焼き直す');
  });
}
