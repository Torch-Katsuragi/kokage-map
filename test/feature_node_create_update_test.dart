// FeatureNode の作成・形の更新（点・線・面）と LayerNode の読み込み・レイヤ作成
//
// 実物の GeoPackage を使う（view_hide_reload_test.dart と同じ作り）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
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
    tmp = await Directory.systemTemp.createTemp('feature_node_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    gpkgNode = GeoPackageNode(gpkg);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const a = LatLng(35.68, 139.76);
  const b = LatLng(35.69, 139.77);
  const c = LatLng(35.68, 139.77);

  test('同じ名前のレイヤは番号を付けて作る', () async {
    final first = await PointLayerNode.createIn(gpkgNode, 'pts');
    final second = await PointLayerNode.createIn(gpkgNode, 'pts');
    expect(first?.layerName, 'pts');
    expect(second?.layerName, isNot('pts'));
    expect(await gpkg.getLayerNames(), containsAll([first!.layerName, second!.layerName]));
  });

  test('点: 作る → 動かす → 読み直しても動いた位置', () async {
    final layer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
    await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
    final p = (await PointFeatureNode.createIn(layer, a, 'p1', null))!;
    expect(layer.children, contains(p));
    expect(p.name, 'p1');

    expect(await p.updateLocation(b), isTrue);
    // 地図に渡す地物の一覧も動いた位置に差し替わる
    final coords = layer.getFeatureById(p.rowId)!.geometry!.toJson()['coordinates'] as List;
    expect(coords[1], closeTo(b.latitude, 1e-9));

    await layer.updateChildren();
    final reloaded = layer.children.single as PointFeatureNode;
    expect(reloaded.point.latitude, closeTo(b.latitude, 1e-9));
    expect(reloaded.name, 'p1');
  });

  test('線: 作る → 頂点を変える → updateGeometry で名前も変える', () async {
    final layer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
    await gpkg.addAttributeColumns('lines', {'name': 'TEXT'});
    final l = (await LineFeatureNode.createIn(layer, [a, b], 'l1', null))!;

    expect(await l.updateLine([a, b, c]), isTrue);
    expect(await l.updateGeometry(name: 'l2'), isTrue);

    await layer.updateChildren();
    final reloaded = layer.children.single as LineFeatureNode;
    expect(reloaded.line, hasLength(3));
    expect(reloaded.name, 'l2');
  });

  test('面: 作る（行を読み直す）→ 形を変える', () async {
    final layer = (await PolygonLayerNode.createIn(gpkgNode, 'polys'))!;
    final g = (await PolygonFeatureNode.createIn(layer, [
      [a, b, c, a],
    ], 'g1', null))!;
    expect(layer.children, contains(g));

    const d = LatLng(35.70, 139.78);
    expect(await g.updatePolygon([
      [a, d, c, a],
    ]), isTrue);

    await layer.updateChildren();
    final reloaded = layer.children.single as PolygonFeatureNode;
    expect(
      reloaded.polygon.first.any((p) => (p.latitude - d.latitude).abs() < 1e-9),
      isTrue,
    );
  });
}
