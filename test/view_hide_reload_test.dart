// View を消灯した直後の読み直しのテスト
//
// 2026-09-01 に実機で「View を hide してもフィーチャが地図から消えない」を確認した。
// 犯人は `LayerNode.updateChildren()` の二重実行ガード: 進行中の読み込み（古い WHERE）の
// Future をそのまま返していたので、消灯直後の呼び出しが古い結果を掴んだまま終わっていた。
// ここでは「進行中に呼ばれたら、終わってからもう一度読む」ことを固定する。
//
// 実物の GeoPackage を使う（view_style_test.dart と同じ作り）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/view_node.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  late PointLayerNode layer;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('view_hide_');
    final path = '${tmp.path}/t.gpkg';
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: path);
    await gpkg.addLayer('chiten', GeometryType.point);
    await gpkg.addAttributeColumns('chiten', {'area': 'REAL'});
    final db = await gpkg.getDatabase();
    // fid 1..12、area は 100..111（>105 は fid 7..12 の 6 件）
    for (var i = 0; i < 12; i++) {
      await db.insert('chiten', {
        'geom': _gpkgPoint(139.76 + i * 0.001, 35.68),
        'area': 100.0 + i,
      });
    }
    final gpkgNode = GeoPackageNode(gpkg);
    layer = PointLayerNode(gpkg, 'chiten', parent: gpkgNode);
    layer.views.addAll([
      ViewNode(name: '大きい', parent: layer, filter: 'area > 105'),
      ViewNode(name: '小さい', parent: layer, filter: 'area <= 105'),
    ]);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('両方見えていれば 12 件、片方を消灯して読み直せば 6 件', () async {
    await layer.updateChildren();
    expect(layer.children.length, 12);

    layer.views[1].visible = false;
    await layer.updateChildren();
    expect(layer.children.length, 6, reason: 'area <= 105 の View を消灯したぶんが消える');
  });

  test('読み込みの進行中に消灯して呼び直すと、終わってから新しい WHERE で読み直す', () async {
    await layer.updateChildren();
    expect(layer.children.length, 12);

    // 1 本目（両方見えている WHERE）が走っている間に消灯して 2 本目を呼ぶ
    final first = layer.updateChildren();
    layer.views[1].visible = false;
    final second = layer.updateChildren();
    await Future.wait([first, second]);

    expect(layer.children.length, 6,
        reason: '進行中の Future をそのまま返すと 12 件のまま（消灯前の結果を掴む）');
  });

  test('進行中に何本呼ばれても読み直しは 1 回で、全員が新しい結果で戻る', () async {
    await layer.updateChildren();
    final first = layer.updateChildren();
    layer.views[1].visible = false;
    final waiters = [for (var i = 0; i < 3; i++) layer.updateChildren()];
    await Future.wait([first, ...waiters]);
    expect(layer.children.length, 6);
    expect(layer.featuresLoaded, isTrue);
  });
}

/// GeoPackage のバイナリヘッダ + WKB Point（little endian）
Uint8List _gpkgPoint(double lon, double lat) {
  final b = BytesBuilder();
  b.add([0x47, 0x50, 0x00, 0x01]); // magic 'GP', version 0, flags: LE, no envelope
  b.add((ByteData(4)..setInt32(0, 4326, Endian.little)).buffer.asUint8List());
  b.add([1]); // WKB byte order LE
  b.add((ByteData(4)..setUint32(0, 1, Endian.little)).buffer.asUint8List()); // Point
  b.add((ByteData(8)..setFloat64(0, lon, Endian.little)).buffer.asUint8List());
  b.add((ByteData(8)..setFloat64(0, lat, Endian.little)).buffer.asUint8List());
  return b.toBytes();
}
