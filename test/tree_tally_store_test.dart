// 毎木調査のレイヤ（gpkg）: 列の作成・円形標準地・集計
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/tree_tally/tree_tally_stats.dart';
import 'package:root_maps/services/tree_tally/tree_tally_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  late GeoPackageNode gpkgNode;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tree_tally_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    gpkgNode = GeoPackageNode(gpkg);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('2レイヤを作り、列の型が決まっている。2回目は作り直さない', () async {
    final layers = (await TreeTallyLayers.ensure(gpkgNode))!;
    expect(layers.plots.layerName, TreeTallySchema.plotsLayer);
    expect(layers.trees.layerName, TreeTallySchema.treesLayer);

    final info = await gpkg.getAttributeColumnInfo(TreeTallySchema.treesLayer);
    final types = {for (final c in info) '${c['name']}': '${c['type']}'.toUpperCase()};
    for (final e in TreeTallySchema.treeColumns.entries) {
      expect(types[e.key], e.value, reason: e.key);
    }

    final again = (await TreeTallyLayers.ensure(gpkgNode))!;
    expect(again.trees, same(layers.trees));
    expect((await gpkg.getLayerNames()).where((n) => n.startsWith('tally_')), hasLength(2));
  });

  test('同じ名前で形の違うレイヤがあると開かずに知らせる（表は変えない）', () async {
    final wrong = (await PointLayerNode.createIn(gpkgNode, TreeTallySchema.plotsLayer))!;
    final before = await gpkg.getAttributeColumnInfo(wrong.layerName);
    await expectLater(
      TreeTallyLayers.ensure(gpkgNode),
      throwsA(isA<TreeTallyLayerConflict>().having((e) => e.layerName, 'layerName', TreeTallySchema.plotsLayer)),
    );
    expect(await gpkg.getAttributeColumnInfo(wrong.layerName), before);
    expect((await gpkg.getLayerNames()).where((n) => n.startsWith('tally_')), [TreeTallySchema.plotsLayer]);
  });

  test('同じ名前の地物でない表があっても別名のレイヤを作らずに知らせる', () async {
    final db = await gpkg.getDatabase();
    await db.execute('CREATE TABLE tally_trees (x TEXT)');
    await expectLater(
      TreeTallyLayers.ensure(gpkgNode),
      throwsA(isA<TreeTallyLayerConflict>().having((e) => e.layerName, 'layerName', TreeTallySchema.treesLayer)),
    );
    final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'tally_%'");
    expect(tables.map((r) => r['name']), ['tally_trees']);
  });

  test('円形標準地（0.05 ha）と、立木を足して集計する', () async {
    final layers = (await TreeTallyLayers.ensure(gpkgNode))!;
    const center = LatLng(33.93, 135.97);
    final plot = (await layers.createCirclePlot('P1', center, circlePlotRadiusM(0.05)))!;
    expect(plot.areaM2, closeTo(500, 1e-6));

    final plots = await layers.loadPlots();
    expect(plots.single.plotId, 'P1');
    expect(plots.single.center.latitude, closeTo(center.latitude, 1e-12));
    expect(TreeTallyLayers.nextPlotId(plots.map((p) => p.plotId)), 'P2');

    expect(await layers.nextTreeNo('P1'), 1);
    for (final (no, sp, dbh, h) in [(1, 'スギ', 20.0, 15.0), (2, 'スギ', 30.0, null), (3, 'ヒノキ', 18.0, 12.0)]) {
      await layers.addTreeAt(center, {'plot_id': 'P1', 'tree_no': no, 'species': sp, 'dbh_cm': dbh, 'height_m': h});
    }
    // 標準地の外の立木（標準地の無い plot_id）
    await layers.addTreeAt(center, {'plot_id': 'X', 'tree_no': 1, 'species': 'スギ', 'dbh_cm': 10.0});
    expect(await layers.nextTreeNo('P1'), 4);
    expect(await layers.usedSpecies(), ['スギ', 'ヒノキ']);

    final tallies = await layers.summarize();
    final p1 = tallies.firstWhere((p) => p.plotId == 'P1');
    expect(p1.all.count, 3);
    expect(p1.all.stemsPerHa, closeTo(60, 1e-6));
    expect(p1.all.basalAreaPerHa, closeTo((basalAreaM2(20) + basalAreaM2(30) + basalAreaM2(18)) * 20, 1e-6));
    expect(p1.bySpecies['スギ']!.count, 2);
    final x = tallies.firstWhere((p) => p.plotId == 'X');
    expect(x.all.count, 1);
    expect(x.all.stemsPerHa, isNull);
  });

  test('多角形の標準地は形から面積を出す', () async {
    final layers = (await TreeTallyLayers.ensure(gpkgNode))!;
    const a = LatLng(33.93, 135.97);
    final ring = [
      a,
      const Distance().offset(a, 20, 90),
      const Distance().offset(const Distance().offset(a, 20, 90), 20, 0),
      const Distance().offset(a, 20, 0),
      a,
    ];
    final f = (await PolygonFeatureNode.createIn(layers.plots, [ring], '', ''))!;
    await f.setAttributeValues({'plot_id': 'Q1', 'shape': 'polygon'});
    final plot = (await layers.loadPlots()).single;
    expect(plot.plotId, 'Q1');
    expect(plot.radiusM, isNull);
    expect(plot.areaM2, closeTo(400, 1));
  });

  test('立木の plot_id の前後の空白は標準地の番号とそろえる（集計・次の番号）', () async {
    final layers = (await TreeTallyLayers.ensure(gpkgNode))!;
    const center = LatLng(33.93, 135.97);
    await layers.createCirclePlot('P1', center, circlePlotRadiusM(0.05));
    await layers.addTreeAt(center, {'plot_id': 'P1', 'tree_no': 1, 'species': 'スギ', 'dbh_cm': 20.0});
    await layers.addTreeAt(center, {'plot_id': ' P1 ', 'tree_no': 2, 'species': 'スギ', 'dbh_cm': 22.0});
    expect(await layers.nextTreeNo('P1'), 3);
    final tallies = await layers.summarize();
    expect(tallies.map((p) => p.plotId), ['P1']);
    expect(tallies.single.all.count, 2);
    expect(tallies.single.all.stemsPerHa, closeTo(40, 1e-6));
  });
}
