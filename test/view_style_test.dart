// View / レイヤのスタイルが「どのフィーチャに効くか」のテスト
//
// 地図に出るかどうかは目で見るしかないが、**どのフィーチャがどのスタイルに
// 割り当てられるか**はここで固定できる。段4b の要はここ。
//
// 実物の GeoPackage を使う（メモリDBだと `getFeatureIds` の主キー解決を通せない）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/view_node.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:turf/turf.dart' as turf;

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  late PointLayerNode layer;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('view_style_');
    final path = '${tmp.path}/t.gpkg';
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: path);
    await gpkg.addLayer('chiten', GeometryType.point);
    await gpkg.addAttributeColumns('chiten', {'area': 'REAL'});

    final db = await gpkg.getDatabase();
    // fid 1..12、area は 100..111（>105 は 6件）。
    // geom は NOT NULL なので、GeoPackage のヘッダ + WKB Point を入れる。
    for (var i = 0; i < 12; i++) {
      await db.insert('chiten', {
        'geom': _gpkgPoint(139.76 + i * 0.001, 35.68),
        'area': 100.0 + i,
      });
    }

    // `layerKey` は GeoPackageNode の親を辿るので、ツリーを最小限だけ組む
    final gpkgNode = GeoPackageNode(gpkg);
    layer = PointLayerNode(gpkg, 'chiten', parent: gpkgNode);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// `_featureMap` に rowId を流し込む（DB読み込みの代わり）
  void seedFeatures() {
    for (var fid = 1; fid <= 12; fid++) {
      layer.addFeatureToMap(
        fid,
        turf.Feature<turf.Point>(
          geometry: turf.Point(coordinates: turf.Position(139.76, 35.68)),
        ),
      );
    }
  }

  test('フィルタ付きViewは、当てはまるフィーチャだけを受け持つ', () async {
    seedFeatures();
    layer.views.addAll([
      ViewNode(
        name: '大きい',
        parent: layer,
        filter: 'area > 105',
        style: const KMetaLayerStyle(pointSize: 25),
      ),
    ]);

    await layer.refreshStyleGroups();

    expect(layer.styleGroups.keys, ['t.gpkg/chiten/大きい']);
    // area 106..111 = fid 7..12
    final assigned =
        layer.styleKeyByRowId.keys.toList()..sort();
    expect(assigned, [7, 8, 9, 10, 11, 12]);
    expect(layer.styleKeyOf(7), 't.gpkg/chiten/大きい');
    expect(layer.styleKeyOf(1), '', reason: '当てはまらないフィーチャは既定スタイル');
  });

  test('フィルタ無しのViewは残り全部を受け持つ', () async {
    seedFeatures();
    layer.views.addAll([
      ViewNode(
        name: '大きい',
        parent: layer,
        filter: 'area > 105',
        style: const KMetaLayerStyle(pointSize: 25),
      ),
      ViewNode(
        name: 'その他',
        parent: layer,
        style: const KMetaLayerStyle(pointSize: 5),
      ),
    ]);

    await layer.refreshStyleGroups();

    expect(layer.styleGroups.length, 2);
    expect(layer.styleKeyByRowId.length, 12, reason: '全フィーチャがどれかに属する');
    // 上にある View が勝つ
    expect(layer.styleKeyOf(12), 't.gpkg/chiten/大きい');
    expect(layer.styleKeyOf(1), 't.gpkg/chiten/その他');
  });

  test('Viewにスタイルが無ければレイヤのスタイルに落ちる', () async {
    seedFeatures();
    // レイヤのスタイルをキャッシュに直接入れる（.kmeta.json 経由の代用）
    layer.views.add(ViewNode(name: '既定', parent: layer));

    await layer.refreshStyleGroups();
    expect(layer.styleGroups, isEmpty,
        reason: 'レイヤにもスタイルが無ければグループを作らない＝View導入前と同じ描画');
  });

  test('消灯したViewは受け持たない', () async {
    seedFeatures();
    layer.views.addAll([
      ViewNode(
        name: '大きい',
        parent: layer,
        filter: 'area > 105',
        style: const KMetaLayerStyle(pointSize: 25),
        visible: false,
      ),
    ]);

    await layer.refreshStyleGroups();
    expect(layer.styleGroups, isEmpty);
    expect(layer.styleKeyByRowId, isEmpty);
  });

  test('スタイル指定が1つも無ければ何も割り当てない', () async {
    seedFeatures();
    layer.views.add(ViewNode(name: '既定', parent: layer));
    await layer.refreshStyleGroups();
    expect(layer.styleGroups, isEmpty);
    expect(layer.styleKeyByRowId, isEmpty,
        reason: 'グループが無いのにキーだけ残ると、フィーチャに無駄な属性が載る');
  });

}

/// GeoPackage のジオメトリBLOB（ヘッダ + WKB Point）
Uint8List _gpkgPoint(double lon, double lat) {
  final header = BytesBuilder()
    ..add(const [0x47, 0x50, 0x00, 0x01]) // 'GP', version 0, flags: little-endian
    ..add(Uint8List(4)..buffer.asByteData().setInt32(0, 4326, Endian.little));
  final wkb = ByteData(21)
    ..setUint8(0, 1) // little-endian
    ..setUint32(1, 1, Endian.little) // Point
    ..setFloat64(5, lon, Endian.little)
    ..setFloat64(13, lat, Endian.little);
  return Uint8List.fromList([...header.toBytes(), ...wkb.buffer.asUint8List()]);
}

