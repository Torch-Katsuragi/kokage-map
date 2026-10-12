// GPS 軌跡の統合（20 秒ごと）を地図に映す（2026-10-12）。
// 統合のたびに全地物を集め直し、3D の下地を焼き直していた。今日の 1 本だけを差し替え、
// 軌跡のレイヤが見えているときだけその 1 本を差分で流す。面の一覧は前のまま、変わった範囲は足した区間だけ
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/screens/map_page/feature_geojson_cache.dart';
import 'package:root_maps/screens/map_page/gps_track_sync.dart';
import 'package:root_maps/screens/map_page/map_scene_store.dart';
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
    tmp = await Directory.systemTemp.createTemp('gps_track_sync_');
    final proj = await PracticeProject.recreate(at: p.join(tmp.path, 'practice'));
    gpkg = GeoPackageFile([p.basename(proj.gpkgPath)], absolutePath: proj.gpkgPath);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 線の座標（LineString / MultiLineString の 1 本目）
  List<LatLng> coordsOf(LineFeatureNode f) {
    final g = f.turfFeature.geometry;
    final List<turf.Position> ps = switch (g) {
      turf.LineString(:final coordinates) => coordinates,
      turf.MultiLineString(:final coordinates) => coordinates.first,
      _ => throw StateError('線ではない: $g'),
    };
    return [for (final q in ps) LatLng(q.lat.toDouble(), q.lng.toDouble())];
  }

  Future<(LineLayerNode, PolygonLayerNode)> load() async {
    final root = GeoPackageNode(gpkg);
    final route = LineLayerNode(gpkg, PracticeProject.routeLayer, parent: root);
    final areas = PolygonLayerNode(gpkg, PracticeProject.areaLayer, parent: root);
    await route.updateChildren();
    await areas.updateChildren();
    return (route, areas);
  }

  FeatureGeoJsonInput input(LineLayerNode route, PolygonLayerNode areas) => FeatureGeoJsonInput(
        lines: route.children.whereType<LineFeatureNode>().toList(),
        polygons: areas.children.whereType<PolygonFeatureNode>().toList(),
        points: const [],
        photos: const [],
        selected: const {},
        lineVertices: false,
        polygonVertices: false,
      );

  test('軌跡のレイヤが見えていなければ、差し替えだけして地図は組み直さない', () async {
    final (route, _) = await load();
    route.visible = false;
    final track = route.children.whereType<LineFeatureNode>().single;
    final line = [...coordsOf(track), const LatLng(33.9285, 135.9800)];
    var rows = 0, all = 0;
    final r = await syncConsolidatedTrack(
      layer: route,
      featureId: track.rowId,
      line: line,
      refreshRows: (_) => rows++,
      refreshAll: () async => all++,
    );
    expect(r, TrackSyncResult.hidden);
    expect(rows, 0);
    expect(all, 0);
    expect(coordsOf(track), hasLength(line.length), reason: '点けたときに今の形で出るよう、差し替えは済ませる');
  });

  test('見えていない・読み込んでいないレイヤで差し替えられなければ、読み込みもしない', () async {
    final route = LineLayerNode(gpkg, PracticeProject.routeLayer, parent: GeoPackageNode(gpkg), visible: false);
    var all = 0;
    final r = await syncConsolidatedTrack(
      layer: route,
      featureId: 1,
      line: const [LatLng(33.92, 135.96), LatLng(33.93, 135.97)],
      refreshRows: (_) => fail('組み直さない'),
      refreshAll: () async => all++,
    );
    expect(r, TrackSyncResult.none);
    expect(route.featuresLoaded, isFalse);
    expect(all, 0);
  });

  test('見えていれば今日の 1 本だけ差分で流す: 面の一覧は前のまま、変わった範囲は足した区間だけ、塗りは含まない', () async {
    final (route, areas) = await load();
    final store = MapSceneStore(overlayImagesOf: () => const []);
    store.pushFeatures(input(route, areas), selectionOnly: false);
    final polys = store.features.polygons;
    final lines = store.features.polylines;
    final rev = store.features.contentRevision;
    var revisions = 0;
    store.revision.addListener(() => revisions++);

    final track = route.children.whereType<LineFeatureNode>().single;
    final before = coordsOf(track);
    const added = LatLng(33.9285, 135.9800);
    final r = await syncConsolidatedTrack(
      layer: route,
      featureId: track.rowId,
      line: [...before, added],
      refreshRows: (changed) => store.pushFeatureChanges(input(route, areas), changed),
      refreshAll: () async => fail('全件は組み直さない'),
    );
    expect(r, TrackSyncResult.rows);
    expect(revisions, 1);
    final g = store.features;
    expect(identical(g.polygons, polys), isTrue, reason: '面は触らない（タイルのシーン・焼き込みが外れない）');
    expect(identical(g.polylines, lines), isFalse);
    expect(g.polylines, hasLength(lines.length));
    expect(g.contentRevision, rev + 1);
    expect(g.lastChangeHasFills, isFalse, reason: '寄った段のテクスチャ（塗りだけ）は焼き直さない');
    // 足した区間（前の最後の点 → 足した点）だけ
    final last = before.last;
    expect(g.lastChangeLonLat!.left, closeTo(last.longitude, 1e-9));
    expect(g.lastChangeLonLat!.right, closeTo(added.longitude, 1e-9));
    expect(g.lastChangeLonLat!.top, closeTo(last.latitude, 1e-9));
    expect(g.lastChangeLonLat!.bottom, closeTo(added.latitude, 1e-9));
    expect(g.lastChangeExtension, g.lastChangeLonLat, reason: '線を伸ばしただけ（1 texel 未満なら焼き直しを見送れる）');

    // 同じ形でもう一度（統合で点が増えなかった）: 世代は進まない
    await syncConsolidatedTrack(
      layer: route,
      featureId: track.rowId,
      line: [...before, added],
      refreshRows: (changed) => store.pushFeatureChanges(input(route, areas), changed),
      refreshAll: () async => fail('全件は組み直さない'),
    );
    expect(store.features.contentRevision, rev + 1);

    // 全件の組み直しでも同じ結果（差分と全件で食い違わない）
    final afterRows = store.features.polylines;
    store.pushFeatures(input(route, areas), selectionOnly: false);
    expect(identical(store.features.polylines, afterRows), isTrue);
    expect(store.features.contentRevision, rev + 1);
  });

  test('全件の組み直しでも、線の後ろに足しただけなら変わった範囲は足した区間。途中が動けば全体', () async {
    final (route, areas) = await load();
    final cache = FeatureGeoJsonCache()..rebuildAll(input(route, areas));
    final track = route.children.whereType<LineFeatureNode>().single;
    final before = coordsOf(track);
    final whole = turf.LineString(coordinates: [for (final q in before) turf.Position(q.longitude, q.latitude)]);

    const added = LatLng(33.9290, 135.9810);
    route.addFeatureToMap(
      track.rowId,
      turf.Feature(
        geometry: turf.LineString(coordinates: [...whole.coordinates, turf.Position(added.longitude, added.latitude)]),
        properties: track.turfFeature.properties,
      ),
    );
    cache.rebuildAll(input(route, areas));
    expect(cache.lastChangeHasFills, isFalse);
    expect(cache.lastChangeLonLat!.left, closeTo(before.last.longitude, 1e-9));
    expect(cache.lastChangeExtension, cache.lastChangeLonLat);

    // 最初の点を動かす → 線全体の範囲
    final moved = [turf.Position(before.first.longitude - 0.001, before.first.latitude), ...whole.coordinates.skip(1)];
    route.addFeatureToMap(track.rowId, turf.Feature(geometry: turf.LineString(coordinates: moved), properties: track.turfFeature.properties));
    cache.rebuildAll(input(route, areas));
    expect(cache.lastChangeLonLat!.left, closeTo(before.first.longitude - 0.001, 1e-9));
    expect(cache.lastChangeLonLat!.right, closeTo(added.longitude, 1e-9), reason: '前の形（足した点まで）も含む');
    expect(cache.lastChangeExtension, isNull, reason: '途中が動いたら伸ばしただけではない（必ず焼く）');
  });

  test('線の本数が増えたら（離れた所に新しい本）伸ばしただけではない', () async {
    final (route, areas) = await load();
    final cache = FeatureGeoJsonCache()..rebuildAll(input(route, areas));
    final track = route.children.whereType<LineFeatureNode>().single;
    final whole = [for (final q in coordsOf(track)) turf.Position(q.longitude, q.latitude)];
    void put(List<List<turf.Position>> chains) => route.addFeatureToMap(
          track.rowId,
          turf.Feature(geometry: turf.MultiLineString(coordinates: chains), properties: track.turfFeature.properties),
        );
    final last = whole.last;
    put([
      [...whole, turf.Position(last.lng.toDouble() + 0.00001, last.lat.toDouble())],
    ]);
    cache.rebuildAll(input(route, areas));
    expect(cache.lastChangeExtension, isNotNull, reason: '1 本のまま後ろに足した');
    put([
      [...whole, turf.Position(last.lng.toDouble() + 0.00001, last.lat.toDouble())],
      [turf.Position(last.lng.toDouble() + 0.00002, last.lat.toDouble()), turf.Position(last.lng.toDouble() + 0.00003, last.lat.toDouble())],
    ]);
    cache.rebuildAll(input(route, areas));
    expect(cache.lastChangeLonLat, isNotNull);
    expect(cache.lastChangeExtension, isNull, reason: '新しい本は短くても丸い点として現れる');
  });

  test('面が変われば塗りを含む', () async {
    final (route, areas) = await load();
    final cache = FeatureGeoJsonCache()..rebuildAll(input(route, areas));
    expect(cache.lastChangeHasFills, isTrue, reason: '最初の組み立ては全部');
    final f = areas.children.whereType<PolygonFeatureNode>().first;
    final old = f.turfFeature;
    final rings = (old.geometry! as turf.MultiPolygon).coordinates.first;
    areas.addFeatureToMap(
      f.rowId,
      turf.Feature(
        geometry: turf.MultiPolygon(coordinates: [
          [for (final ring in rings) [for (final q in ring) turf.Position(q.lng.toDouble() + 0.001, q.lat.toDouble())]],
        ]),
        properties: old.properties,
      ),
    );
    expect(cache.rebuildFeatures(input(route, areas), {f}), isTrue);
    expect(cache.lastChangeHasFills, isTrue);
    expect(cache.lastChangeExtension, isNull);
  });
}
