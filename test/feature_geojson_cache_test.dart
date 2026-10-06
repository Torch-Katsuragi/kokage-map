// FeatureGeoJsonCache の使い回し（2026-10-06）。
// GPS 軌跡の統合で 20 秒ごとに全件を組み直すが、中身が同じならリストの同一性を保ち（描画側のタイルごとのシーンが外れない）、
// 変換もやり直さない。形が変われば新しいリストになり、中身の世代が進む
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/screens/map_page/feature_geojson_cache.dart';
import 'package:root_maps/tutorial/practice_project.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:turf/turf.dart' as turf;

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('geojson_cache_');
    final proj = await PracticeProject.recreate(at: p.join(tmp.path, 'practice'));
    gpkg = GeoPackageFile([p.basename(proj.gpkgPath)], absolutePath: proj.gpkgPath);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  FeatureGeoJsonInput input(List<PolygonFeatureNode> polys, {Set<PolygonFeatureNode> selected = const {}}) => FeatureGeoJsonInput(
        lines: const [],
        polygons: polys,
        points: const [],
        photos: const [],
        selected: selected,
        hidden: const {},
        stylePropKey: 'k-style',
        lineVertices: false,
        polygonVertices: false,
      );

  test('中身が同じなら組み直してもリストは同じもの・世代も進まない。形が変われば新しいリストで世代が進む', () async {
    final areas = PolygonLayerNode(gpkg, PracticeProject.areaLayer, parent: GeoPackageNode(gpkg));
    await areas.updateChildren();
    final polys = areas.children.whereType<PolygonFeatureNode>().toList();
    expect(polys, hasLength(2));

    final cache = FeatureGeoJsonCache()..rebuildAll(input(polys));
    final first = cache.polygons;
    final rev = cache.contentRevision;
    expect(first, hasLength(2));

    // 同じ地物で組み直す（新しいリストで渡しても中身は同じ）
    cache.rebuildAll(input(List.of(polys)));
    expect(identical(cache.polygons, first), isTrue);
    expect(cache.contentRevision, rev);
    expect(identical(cache.selectedPolygons, const <Object>[]) || cache.selectedPolygons.isEmpty, isTrue);
    final emptySel = cache.selectedPolygons;
    cache.rebuildSelection(input(polys));
    expect(identical(cache.selectedPolygons, emptySel), isTrue);

    // 選ぶと選択リストは変わるが、通常リストの Feature は使い回す
    cache.rebuildSelection(input(polys, selected: {polys.first}));
    expect(cache.selectedPolygons, hasLength(1));
    expect(identical(cache.selectedPolygons.single, first.first), isTrue);

    // 1 件の形を差し替える（編集は新しい turf の形を地図に入れる）
    final f = polys.first;
    final old = f.turfFeature;
    final rings = (old.geometry! as turf.MultiPolygon).coordinates.first;
    final moved = turf.MultiPolygon(coordinates: [
      [
        for (final ring in rings) [for (final pos in ring) turf.Position(pos.lng.toDouble() + 0.001, pos.lat.toDouble())],
      ],
    ]);
    areas.addFeatureToMap(f.rowId, turf.Feature(geometry: moved, properties: old.properties));
    cache.rebuildAll(input(polys));
    expect(identical(cache.polygons, first), isFalse);
    expect(identical(cache.polygons[1], first[1]), isTrue, reason: '変えていない地物は変換し直さない');
    expect(cache.contentRevision, rev + 1);
    expect(cache.lastChangeLonLat, isNotNull);
  });
}
