// 以前の版がトリガーを落としたまま上げた gpkg（rtree は登録され表もあるのにトリガーが無い）を直す（ホスト VM）。
//
// 2026-10-12: Drive に上がっていた「調査点」は行があるのに rtree が 0 行、gpkg_extensions に rtree の登録はあるが
// 7 つのトリガーが 1 つも無く、QGIS/GDAL の空間検索で行が見えなかった。控えはもう無いので規格のトリガーを作る。
//
// GDAL の ogr2ogr（QGIS 同梱、または Linux の gdal-bin）があれば、GDAL が作るトリガーと突き合わせる。無ければその段は skip。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/gpkg_index_repair.dart';
import 'package:root_maps/models/geopackage/gpkg_rtree_triggers.dart';
import 'package:root_maps/models/geopackage/spatial_index_manager.dart';
import 'package:root_maps/models/geopackage/sql_identifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/foreign_geom_gpkg.dart';
import 'support/gdal_host.dart';

/// ホストの ogr2ogr。無ければ null
String? _findOgr2ogr() {
  final dir = findHostGdal()?.dllSearchDir;
  if (dir != null) {
    final exe = p.join(dir, Platform.isWindows ? 'ogr2ogr.exe' : 'ogr2ogr');
    if (File(exe).existsSync()) return exe;
  }
  if (Platform.isLinux && File('/usr/bin/ogr2ogr').existsSync()) return '/usr/bin/ogr2ogr';
  return null;
}

/// GDAL で gpkg を作る（点 3 つ、rtree とトリガーつき）
Future<void> _ogr2ogr(String exe, String out, {required String table, required String geom, required String fid}) async {
  final csv = '${p.withoutExtension(out)}.csv';
  await File(csv).writeAsString('name,WKT\na,"POINT (135.96 33.93)"\nb,"POINT (135.97 33.94)"\nc,"POINT (136.1 34.1)"\n');
  final r = await Process.run(exe, [
    '-f', 'GPKG', out, csv, '-nln', table, '-a_srs', 'EPSG:4326', //
    '-oo', 'GEOM_POSSIBLE_NAMES=WKT', '-oo', 'KEEP_GEOM_COLUMNS=NO',
    '-lco', 'GEOMETRY_NAME=$geom', '-lco', 'FID=$fid',
  ]);
  if (r.exitCode != 0) throw StateError('ogr2ogr: ${r.stderr}');
}

Future<T> _read<T>(String path, Future<T> Function(Database db) f) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
  try {
    return await f(db);
  } finally {
    await db.close();
  }
}

/// [rtree] のトリガー（作られた順。名前 → SQL）
Future<Map<String, String>> _triggers(String path, String rtree) => _read(path, (db) async => {
      for (final r in await db.rawQuery("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY rowid"))
        if ((r['name']! as String).startsWith('${rtree}_')) r['name']! as String: r['sql']! as String,
    });

Future<List<Map<String, Object?>>> _rtreeRows(String path, String rtree) =>
    _read(path, (db) => db.rawQuery('SELECT * FROM ${quoteIdent(rtree)} ORDER BY id'));

/// トリガーを落とし rtree を空にする（以前の版が上げたファイルと同じ壊れ方）
Future<void> _damage(String path, String rtree) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
  for (final name in (await _triggers(path, rtree)).keys) {
    await db.execute('DROP TRIGGER ${quoteIdent(name)}');
  }
  await db.execute('DELETE FROM ${quoteIdent(rtree)}');
  await db.close();
}

void main() {
  late Directory tmp;
  final ogr2ogr = _findOgr2ogr();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => tmp = await Directory.systemTemp.createTemp('gpkg_rtree_triggers_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('GDAL と同じトリガーを作る', () {
    for (final (table, geom, fid) in const [('調査点', 'geom', 'fid'), ('Stands', 'Shape', 'OBJECTID'), ('a"b', 'geom', 'fid')]) {
      test('$table（$geom・$fid）', () async {
        final path = p.join(tmp.path, 'gdal.gpkg');
        await _ogr2ogr(ogr2ogr!, path, table: table, geom: geom, fid: fid);
        final rtree = 'rtree_${table}_$geom';
        final gdal = await _triggers(path, rtree);
        expect(gdal, hasLength(7));
        // 名前・並び・SQL まで GDAL と同じ
        expect(GpkgRtreeTriggers.standard(table: table, geomColumn: geom, pk: fid).entries.map((e) => (e.key, e.value)).toList(),
            gdal.entries.map((e) => (e.key, e.value)).toList());

        final rows = await _rtreeRows(path, rtree);
        expect(rows, hasLength(3));
        await _damage(path, rtree);
        expect(await _read(path, GpkgRtreeTriggers.findMissing), hasLength(1));

        expect(await GpkgIndexRepair.healRtreeTriggers(path), 1);
        expect(await _triggers(path, rtree), gdal);
        expect(await _rtreeRows(path, rtree), rows, reason: 'rtree を実データから焼き直す');
        expect(await GpkgIndexRepair.healRtreeTriggers(path), 0, reason: '直したあとは何もしない');

        // GDAL の空間検索で全部見える（足した点 c も）
        final ogrinfo = p.join(p.dirname(ogr2ogr), Platform.isWindows ? 'ogrinfo.exe' : 'ogrinfo');
        final r = await Process.run(ogrinfo, ['-ro', '-so', path, table, '-spat', '135.0', '33.0', '137.0', '35.0']);
        expect('${r.stdout}', contains('Feature Count: 3'), reason: '${r.stderr}');
      });
    }

    test('健全なファイルは書かない', () async {
      final path = p.join(tmp.path, 'healthy.gpkg');
      await _ogr2ogr(ogr2ogr!, path, table: '調査点', geom: 'geom', fid: 'fid');
      final before = File(path).readAsBytesSync();
      expect(await GpkgIndexRepair.healRtreeTriggers(path), 0);
      expect(File(path).readAsBytesSync(), before);
    });
  }, skip: ogr2ogr == null ? 'ホストに ogr2ogr が無い' : null);

  group('SQL で作った gpkg', () {
    const g = ForeignGeomGpkg.arcgis;

    test('トリガーが丸ごと無い表: 規格のトリガーを作り rtree を焼き直す', () async {
      final path = p.join(tmp.path, 'damaged.gpkg');
      await g.write(path);
      final rows = await _rtreeRows(path, g.rtree);
      await _damage(path, g.rtree);
      expect(await GpkgIndexRepair.healRtreeTriggers(path), 1);
      expect(await _triggers(path, g.rtree), GpkgRtreeTriggers.standard(table: g.table, geomColumn: g.geomColumn, pk: g.pk));
      expect(await _rtreeRows(path, g.rtree), rows);
    });

    test('一部だけ残っている表は触らない（どの版の組か分からない）', () async {
      final path = p.join(tmp.path, 'partial.gpkg');
      await g.write(path); // insert と delete だけ
      final before = File(path).readAsBytesSync();
      expect(await GpkgIndexRepair.healRtreeTriggers(path), 0);
      expect(File(path).readAsBytesSync(), before);
    });

    test('gpkg_extensions に rtree の登録が無い表は触らない', () async {
      final path = p.join(tmp.path, 'unregistered.gpkg');
      await g.write(path);
      await _damage(path, g.rtree);
      final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      await db.execute('DELETE FROM gpkg_extensions');
      await db.close();
      final before = File(path).readAsBytesSync();
      expect(await GpkgIndexRepair.healRtreeTriggers(path), 0);
      expect(File(path).readAsBytesSync(), before);
    });

    test('アプリが作った rtree の無い gpkg は書かない', () async {
      final path = p.join(tmp.path, 'own.gpkg');
      final gpkg = GeoPackageFile(const ['own.gpkg'], absolutePath: path);
      await gpkg.addLayer('t', GeometryType.point);
      await gpkg.addPointWithAttributes('t', const LatLng(34.1, 136.1), {});
      await gpkg.dispose();
      final before = File(path).readAsBytesSync();
      expect(await GpkgIndexRepair.healRtreeTriggers(path), 0);
      expect(File(path).readAsBytesSync(), before);
    });
  });

  group('外へ出す前（prepareForHandOff）', () {
    const g = ForeignGeomGpkg.arcgis;
    setUp(() => SpatialIndexManager.debugWithoutRtreeModule = true); // Android と同じく rtree を書けない
    tearDown(() => SpatialIndexManager.debugWithoutRtreeModule = false);

    test('トリガーの無いファイルに書いて外へ出すと、規格のトリガーが付き足した点も rtree に載る。続けて書ける', () async {
      final path = p.join(tmp.path, 'damaged.gpkg');
      await g.write(path);
      await _damage(path, g.rtree);
      final standard = GpkgRtreeTriggers.standard(table: g.table, geomColumn: g.geomColumn, pk: g.pk);

      final gpkg = GeoPackageFile(const ['damaged.gpkg'], absolutePath: path);
      expect(await gpkg.addPointWithAttributes(g.table, const LatLng(34.1, 136.1), {'name': 'app'}), isNotNull);
      await GeoPackageFile.prepareForHandOff(path);
      expect(await _triggers(path, g.rtree), standard);
      expect([for (final r in await _rtreeRows(path, g.rtree)) r['id']], [1, 2, 3]);

      // 開いたまま続けて書ける（作ったトリガーは次に書く前にまた落とし、閉じるときに戻す）
      expect(await gpkg.addPointWithAttributes(g.table, const LatLng(34.2, 136.2), {'name': 'again'}), isNotNull);
      await gpkg.dispose();
      expect(await _triggers(path, g.rtree), standard);
      expect([for (final r in await _rtreeRows(path, g.rtree)) r['id']], [1, 2, 3, 4]);
    });

    test('閉じたあと（dispose）も直す', () async {
      final path = p.join(tmp.path, 'damaged.gpkg');
      await g.write(path);
      await _damage(path, g.rtree);
      final gpkg = GeoPackageFile(const ['damaged.gpkg'], absolutePath: path);
      await gpkg.addPointWithAttributes(g.table, const LatLng(34.1, 136.1), {'name': 'app'});
      await gpkg.dispose();
      expect(await _triggers(path, g.rtree), GpkgRtreeTriggers.standard(table: g.table, geomColumn: g.geomColumn, pk: g.pk));
      expect([for (final r in await _rtreeRows(path, g.rtree)) r['id']], [1, 2, 3]);
    });

    test('読んだだけのファイルは直さない（書いたファイルだけ）', () async {
      final path = p.join(tmp.path, 'damaged.gpkg');
      await g.write(path);
      await _damage(path, g.rtree);
      final before = File(path).readAsBytesSync();
      final gpkg = GeoPackageFile(const ['damaged.gpkg'], absolutePath: path);
      expect(await gpkg.getFeatures(g.table), hasLength(2));
      await GeoPackageFile.prepareForHandOff(path);
      await gpkg.dispose();
      expect(File(path).readAsBytesSync(), before);
    });
  });
}
