// 新規 .gpkg の版マーカー（PRAGMA application_id / user_version）
//
// sqflite の `version:` を使うと user_version が sqflite の版数（1）で上書きされ、
// GDAL/QGIS が「unrecognized user_version=0x00000001」と警告する。
// 開くだけの既存ファイル（QGIS が作った 1.3 / 1.4）は触らないことも固定する。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_version_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<(int, int)> markersOf(String path) async {
    final db = await openDatabase(path);
    final app = (await db.rawQuery('PRAGMA application_id')).first.values.first! as int;
    final ver = (await db.rawQuery('PRAGMA user_version')).first.values.first! as int;
    await db.close();
    return (app, ver);
  }

  test('新規作成した .gpkg は GPKG / 1.3.1 のマーカーを持つ', () async {
    final path = '${tmp.path}/new.gpkg';
    final gpkg = GeoPackageFile(const ['new.gpkg'], absolutePath: path);
    await gpkg.addLayer('t', GeometryType.point);
    await gpkg.dispose();

    expect(await markersOf(path), (0x47504B47, 10301));
  });

  test('外部ツールが作った .gpkg を開いても user_version は書き換えない', () async {
    // QGIS / GDAL が書く 1.4 の空 GeoPackage を模す
    final path = '${tmp.path}/external.gpkg';
    final db = await openDatabase(path);
    await db.execute('PRAGMA application_id = 0x47504B47');
    await db.execute('PRAGMA user_version = 10400');
    await db.execute('CREATE TABLE gpkg_contents (table_name TEXT NOT NULL PRIMARY KEY, data_type TEXT NOT NULL)');
    await db.close();

    final gpkg = GeoPackageFile(const ['external.gpkg'], absolutePath: path);
    await gpkg.getDatabase();
    await gpkg.dispose();

    expect(await markersOf(path), (0x47504B47, 10400));
  });
}
