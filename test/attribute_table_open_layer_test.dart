// 属性表を開く先: レイヤ一覧でレイヤを選ばず、地図で地物を選んで開いたら、その地物のレイヤ（ホスト VM）。
// 以前は「レイヤーが選択されていません」と断っていた（2026-10-12 に Pixel 9 で）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/selection_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('open_layer_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
  });

  tearDown(() async {
    await gpkg.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('選んだ地物がみな同じレイヤならそのレイヤ。混ざる・空なら null', () async {
    Future<PointLayerNode> layerWith(String name) async {
      await gpkg.addLayer(name, GeometryType.point);
      await gpkg.addAttributeColumns(name, {'name': 'TEXT'});
      await gpkg.addPointWithAttributes(name, const LatLng(33.9, 135.9), {'name': '${name}1'});
      await gpkg.addPointWithAttributes(name, const LatLng(33.8, 135.8), {'name': '${name}2'});
      final layer = PointLayerNode(gpkg, name, parent: GeoPackageNode(gpkg));
      await layer.updateChildren();
      return layer;
    }

    final a = await layerWith('a');
    final b = await layerWith('b');
    expect(layerOfSelectedFeatures([a.features.first]), same(a));
    expect(layerOfSelectedFeatures(a.features.toList()), same(a));
    expect(layerOfSelectedFeatures([a.features.first, b.features.first]), isNull);
    expect(layerOfSelectedFeatures(const []), isNull);
  });
}
