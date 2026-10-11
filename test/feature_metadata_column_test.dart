// 線・面の GPS 測量の点ごとの記録（drawing_points）を、メタデータの列（kmaps_metadata）に残す。
// 以前はアプリが列を作らず、列の無いレイヤ（アプリで作ったレイヤはすべて）では捨てていた。
//
// 実物の GeoPackage を使う（feature_node_create_update_test.dart と同じ作り）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/feature_repository.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/utils/attribute_columns.dart';
import 'package:root_maps/utils/global_drawing_state.dart';
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
    tmp = await Directory.systemTemp.createTemp('feature_metadata_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    gpkgNode = GeoPackageNode(gpkg);
  });

  tearDown(() async {
    GlobalDrawingState.instance.clearAll();
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const a = LatLng(35.68, 139.76);
  const b = LatLng(35.69, 139.77);
  const c = LatLng(35.68, 139.77);

  Map<String, dynamic> survey(LatLng p, int i) => {
        'latitude': p.latitude,
        'longitude': p.longitude,
        'accuracy': 3.0 + i,
        'data_source': 'gps_survey',
        'timestamp': '2026-10-11T10:00:0$i',
      };

  Future<bool> hasMetadataColumn(String layer) async =>
      (await gpkg.getColumnNames(layer, getAll: true)).contains(metadataColumn);

  test('GPS 測量した線: 列を作って点ごとの記録を残し、読み直しても残っている', () async {
    final layer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
    await gpkg.addAttributeColumns('lines', {'name': 'TEXT'});
    expect(await hasMetadataColumn('lines'), isFalse);

    final drawing = GlobalDrawingState.instance..clearAll();
    for (final (i, p) in [a, b, c].indexed) {
      drawing.addPoint(p, survey(p, i), isLine: true);
    }
    final ok = await drawing.confirmCurrentFeature(
      layerNode: layer,
      name: 'survey',
      description: '',
      closeRing: (pts) => pts,
    );
    expect(ok, isTrue);
    expect(await hasMetadataColumn('lines'), isTrue);

    await layer.updateChildren();
    final reloaded = layer.children.whereType<LineFeatureNode>().single;
    final points = (reloaded.metadata!['drawing_points'] as List).cast<Map>();
    expect(points, hasLength(3));
    expect(points.map((p) => p['accuracy']), [3.0, 4.0, 5.0]);
    expect(points.first['data_source'], 'gps_survey');

    // 属性表・編集パネルには出さない
    expect(isSystemColumn(metadataColumn), isTrue);
  });

  test('ペンだけで描いた線では列を作らない', () async {
    final layer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
    final drawing = GlobalDrawingState.instance..clearAll();
    drawing
      ..addPoint(a, null, isLine: true)
      ..addPoint(b, null, isLine: true);
    expect(
      await drawing.confirmCurrentFeature(
        layerNode: layer,
        name: 'pen',
        description: '',
        closeRing: (pts) => pts,
      ),
      isTrue,
    );
    expect(await hasMetadataColumn('lines'), isFalse);
  });

  test('列の無い面を GPS 測量で追記して更新しても、列を作って残す', () async {
    final layer = (await PolygonLayerNode.createIn(gpkgNode, 'polys'))!;
    final poly = (await PolygonFeatureNode.createIn(layer, [[a, b, c, a]], 'p', null))!;
    expect(await hasMetadataColumn('polys'), isFalse);

    expect(
      await poly.updateGeometry(
        name: 'p',
        metadata: {
          'drawing_points': [for (final (i, p) in [a, b, c].indexed) survey(p, i)],
        },
        newGeometry: [[a, b, c, a]],
      ),
      isTrue,
    );
    expect(await hasMetadataColumn('polys'), isTrue);

    await layer.updateChildren();
    final reloaded = layer.children.whereType<PolygonFeatureNode>().single;
    expect(reloaded.metadata!['drawing_points'] as List, hasLength(3));
  });

  test('残す中身の見分け', () {
    expect(metadataWorthStoring(null), isFalse);
    expect(metadataWorthStoring({}), isFalse);
    expect(
      metadataWorthStoring({
        'drawing_points': [
          {'data_source': 'pen_tool'},
        ],
      }),
      isFalse,
    );
    expect(
      metadataWorthStoring({
        'drawing_points': [
          {'data_source': 'pen_tool'},
          {'data_source': 'gps_survey'},
        ],
      }),
      isTrue,
    );
    expect(metadataWorthStoring({'source_layer': 'a'}), isTrue);
  });
}
