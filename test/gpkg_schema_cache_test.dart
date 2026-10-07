// 列の一覧（PRAGMA table_info）と主キー名の控えが、列の追加・改名・削除と開き直しで古くならないかのテスト
//
// 控えは同じファイルを開いている接続で共有する。別の GeoPackageFile が足した列も見えること、
// 閉じている間に外（geodiff・Drive）で書き換えられた列も開き直せば見えること。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late String path;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_schema_cache_');
    path = '${tmp.path}/t.gpkg';
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: path);
    await gpkg.addLayer('pts', GeometryType.point);
    await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<List<String>> columns(GeoPackageFile g) => g.getColumnNames('pts', getAll: true);

  test('列を足す・改名する・消すと、列の一覧にすぐ出る', () async {
    expect(await columns(gpkg), ['fid', 'name']);

    await gpkg.addAttributeColumn('pts', 'dbh', 'REAL');
    expect(await columns(gpkg), ['fid', 'name', 'dbh']);
    expect(await gpkg.getTableColumns('pts'), ['fid', 'geom', 'name', 'dbh']);

    await gpkg.renameColumn('pts', 'dbh', '胸高直径');
    expect(await columns(gpkg), ['fid', 'name', '胸高直径']);
    expect(
      (await gpkg.getAttributeColumnInfo('pts')).map((c) => c['name']),
      ['fid', 'name', '胸高直径'],
    );

    await gpkg.dropColumn('pts', '胸高直径');
    expect(await columns(gpkg), ['fid', 'name']);
  });

  test('足した列にすぐ属性を書ける（列の確認が古い控えで弾かない）', () async {
    final id = await gpkg.addPointWithAttributes('pts', const LatLng(35, 135), {'name': 'a'});
    expect(await gpkg.updateFeatureAttributes('pts', id!, {'memo': 'x'}), isTrue); // 列が無いので書かない
    expect(await gpkg.getFeatureAttribute('pts', id, 'memo'), isNull);

    await gpkg.addAttributeColumn('pts', 'memo', 'TEXT');
    expect(await gpkg.updateFeatureAttributes('pts', id, {'memo': 'x'}), isTrue);
    expect(await gpkg.getFeatureAttribute('pts', id, 'memo'), 'x');
  });

  test('同じファイルを開いた別の GeoPackageFile が足した列も見える', () async {
    final other = GeoPackageFile(const ['t.gpkg'], absolutePath: path);
    try {
      expect(await columns(other), ['fid', 'name']);
      await gpkg.addAttributeColumn('pts', 'dbh', 'REAL');
      expect(await columns(other), ['fid', 'name', 'dbh']);
    } finally {
      await other.dispose();
    }
  });

  test('閉じている間に外で足された列も、開き直せば見える', () async {
    expect(await columns(gpkg), ['fid', 'name']);
    await GeoPackageConnection.closeAllFor(path);

    final db = await openDatabase(path, singleInstance: false);
    await db.execute('ALTER TABLE pts ADD COLUMN height REAL');
    await db.close();

    expect(await columns(gpkg), ['fid', 'name', 'height']);
  });

  test('レイヤを消して同じ名前で作り直すと、新しい列と主キーを読む', () async {
    await gpkg.addAttributeColumn('pts', 'dbh', 'REAL');
    expect(await gpkg.getPrimaryKeyColumn('pts'), 'fid');
    await gpkg.removeLayer('pts');
    await gpkg.addLayer('pts', GeometryType.point);
    expect(await columns(gpkg), ['fid']);
    expect(await gpkg.getPrimaryKeyColumn('pts'), 'fid');
  });
}
