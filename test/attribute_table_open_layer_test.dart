// 属性表を開く先: レイヤ一覧でレイヤを選ばず、地図で地物を選んで開いたら、その地物のレイヤ（ホスト VM）。
// 以前は「レイヤーが選択されていません」と断っていた（2026-10-12 に Pixel 9 で）
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  Future<PointLayerNode> layerWith(String name) async {
    await gpkg.addLayer(name, GeometryType.point);
    await gpkg.addAttributeColumns(name, {'name': 'TEXT'});
    await gpkg.addPointWithAttributes(name, const LatLng(33.9, 135.9), {'name': '${name}1'});
    await gpkg.addPointWithAttributes(name, const LatLng(33.8, 135.8), {'name': '${name}2'});
    final layer = PointLayerNode(gpkg, name, parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
    return layer;
  }

  test('選んだ地物がみな同じレイヤならそのレイヤ。混ざる・空なら null', () async {
    final a = await layerWith('a');
    final b = await layerWith('b');
    expect(layerOfSelectedFeatures([a.features.first]), same(a));
    expect(layerOfSelectedFeatures(a.features.toList()), same(a));
    expect(layerOfSelectedFeatures([a.features.first, b.features.first]), isNull);
    expect(layerOfSelectedFeatures(const []), isNull);
  });

  // 最後に選んだものを開く（2026-10-12 に Pixel 9 で。レイヤ一覧で調査点を押したあと、検索で小班の地物へ飛んで
  // 属性表を開くと調査点が開いていた）
  test('属性表で開くレイヤ: 最後に選んだもの（一覧のレイヤ／地図で選んだ地物のレイヤ）', () async {
    final chousa = await layerWith('調査点');
    final shohan = await layerWith('小班');
    final c = ProviderContainer();
    addTearDown(c.dispose);
    LayerNode? target() => attributeTableLayerFor(c.read(selectedLayerNodeProvider), c.read(selectedFeaturesProvider));

    expect(target(), isNull); // 何も選んでいなければ警告を出す
    c.read(selectedLayerNodeProvider.notifier).select(chousa);
    expect(target(), same(chousa));
    // 検索・タップ・表の行で地物を選ぶと、レイヤ一覧の選択もそのレイヤへ移る
    c.read(selectedFeaturesProvider.notifier).selectOnMap(shohan.features.first);
    expect(c.read(selectedLayerNodeProvider), same(shohan));
    expect(target(), same(shohan));
    // そのあとレイヤ一覧で別のレイヤを押したら、押したほう
    c.read(selectedLayerNodeProvider.notifier).select(chousa);
    expect(target(), same(chousa));
    // 一覧で選んでいなければ地図で選んだ地物のレイヤ
    c.read(selectedLayerNodeProvider.notifier).select(null);
    expect(target(), same(shohan));
  });
}
