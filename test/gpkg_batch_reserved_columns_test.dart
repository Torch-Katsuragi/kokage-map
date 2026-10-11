// 一度に足す（addPointsBatch・addLinesBatch・addPolygonsBatch）: point・line・rings という列も属性として書く（ホスト VM）。
//
// 以前は形を属性と同じ表の point・line・rings に入れて渡していて、同名の列は書けなかった（2026-10-12）。
// 形は属性と別に渡す
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  const columns = {'name': 'TEXT', 'point': 'TEXT', 'line': 'TEXT', 'rings': 'TEXT'};
  const attrs = {'name': 'a', 'point': 'p', 'line': 'l', 'rings': 'r'};

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_batch_reserved_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
  });

  tearDown(() async {
    await gpkg.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> expectAttrs(String table, int id) async {
    final row = (await gpkg.getFeature(table, id))!;
    for (final MapEntry(:key, :value) in attrs.entries) {
      expect(row[key], value, reason: key);
    }
  }

  test('点', () async {
    await gpkg.addLayer('pts', GeometryType.point);
    await gpkg.addAttributeColumns('pts', columns);
    final ids = await gpkg.addPointsBatch('pts', [(const LatLng(33.9, 135.9), attrs)]);
    expect(ids, hasLength(1));
    await expectAttrs('pts', ids.single);
  });

  test('線', () async {
    await gpkg.addLayer('lns', GeometryType.linestring);
    await gpkg.addAttributeColumns('lns', columns);
    final ids = await gpkg.addLinesBatch('lns', [(const [LatLng(33.9, 135.9), LatLng(33.91, 135.91)], attrs)]);
    expect(ids, hasLength(1));
    await expectAttrs('lns', ids.single);
  });

  test('面', () async {
    await gpkg.addLayer('pls', GeometryType.polygon);
    await gpkg.addAttributeColumns('pls', columns);
    const ring = [LatLng(33.0, 135.0), LatLng(33.0, 135.1), LatLng(33.1, 135.1), LatLng(33.0, 135.0)];
    final ids = await gpkg.addPolygonsBatch('pls', [(const [ring], attrs)]);
    expect(ids, hasLength(1));
    await expectAttrs('pls', ids.single);
  });
}
