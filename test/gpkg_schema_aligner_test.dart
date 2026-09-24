// GpkgSchemaAligner（片側だけの列の追加に限って 3 つのスキーマをそろえる）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/google_drive/gpkg_schema_aligner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => tmp = await Directory.systemTemp.createTemp('schema_align_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> make(String name) async {
    final path = '${tmp.path}/$name';
    final g = GeoPackageFile([name], absolutePath: path);
    await g.addLayer('trees', GeometryType.point);
    await g.addAttributeColumns('trees', {'name': 'TEXT'});
    await g.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {'name': 'a'});
    await g.flushChanges();
    await g.dispose();
    return path;
  }

  Future<void> sql(String path, String stmt) async {
    final db = await openDatabase(path, singleInstance: false);
    await db.execute(stmt);
    await db.close();
  }

  Future<List<String>> cols(String path) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      return (await db.rawQuery('PRAGMA table_info(trees)')).map((r) => r['name']! as String).toList();
    } finally {
      await db.close();
    }
  }

  test('相手だけが列を足した → base とこちらにも足す', () async {
    final base = await make('b.gpkg');
    final theirs = await make('t.gpkg');
    final mine = await make('m.gpkg');
    await sql(theirs, 'ALTER TABLE trees ADD COLUMN height REAL DEFAULT 0');
    final r = await GpkgSchemaAligner.align(base: base, theirs: theirs, mine: mine);
    expect(r.added, ['trees.height']);
    expect(await cols(base), await cols(theirs));
    expect(await cols(mine), await cols(theirs));
  });

  test('両側が同じ列を足した → base にだけ足す', () async {
    final base = await make('b.gpkg');
    final theirs = await make('t.gpkg');
    final mine = await make('m.gpkg');
    await sql(theirs, 'ALTER TABLE trees ADD COLUMN height REAL');
    await sql(mine, 'ALTER TABLE trees ADD COLUMN height REAL');
    final r = await GpkgSchemaAligner.align(base: base, theirs: theirs, mine: mine);
    expect(r.added, ['trees.height']);
    expect(await cols(base), await cols(mine));
  });

  test('列を消した・既定値の無い NOT NULL を足した → そろえない（何も書かない）', () async {
    final base = await make('b.gpkg');
    final theirs = await make('t.gpkg');
    final mine = await make('m.gpkg');
    await sql(theirs, 'ALTER TABLE trees DROP COLUMN name');
    final before = await cols(base);
    expect((await GpkgSchemaAligner.align(base: base, theirs: theirs, mine: mine)).added, isEmpty);
    expect(await cols(base), before);

    final theirs2 = await make('t2.gpkg');
    // SQLite は既定値の無い NOT NULL 列を足せないので、テーブルを作り直した状態を模す
    await sql(theirs2, 'ALTER TABLE trees ADD COLUMN code TEXT NOT NULL DEFAULT ""');
    // 既定値ありなら足せる
    expect((await GpkgSchemaAligner.align(base: base, theirs: theirs2, mine: mine)).added, ['trees.code']);
  });
}
