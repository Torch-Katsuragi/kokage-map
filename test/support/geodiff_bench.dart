// geodiff の行単位マージを、実データ規模の gpkg で測る（ホスト VM と実機で共有）。
//
// 森林簿のような面データを想定: n 筆のポリゴン（各 12 頂点）、属性 10 列。rtree 付き（QGIS 製を想定）。
// 測るもの: base の写し（makeCopySqlite）／片側 k 行ずつ変えたときの rebase／rebase 後の索引の焼き直し（全件）。
import 'dart:io';
import 'dart:math';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/gpkg_index_repair.dart';
import 'package:root_maps/services/geodiff/geodiff.dart';
import 'package:root_maps/services/google_drive/gpkg_merger.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite/sqflite.dart';

class GeodiffBenchResult {
  GeodiffBenchResult(this.features, this.bytes, this.ms);
  final int features;
  final int bytes;
  final Map<String, int> ms;

  @override
  String toString() =>
      '$features 筆 ${(bytes / 1024 / 1024).toStringAsFixed(1)}MB: '
      '${ms.entries.map((e) => '${e.key} ${e.value}ms').join(' / ')}';
}

Future<GeodiffBenchResult> runGeodiffBench(String dir, {int features = 20000, int edits = 50}) async {
  final base = p.join(dir, 'bench_base.gpkg');
  for (final f in ['bench_base.gpkg', 'bench_mine.gpkg', 'bench_theirs.gpkg']) {
    final file = File(p.join(dir, f));
    if (file.existsSync()) file.deleteSync();
  }
  final g0 = GeoPackageFile(const ['bench_base.gpkg'], absolutePath: base);
  await g0.addLayer('stands', GeometryType.polygon);
  await g0.addAttributeColumns('stands', {
    'rinpan': 'TEXT', 'shohan': 'TEXT', 'jusyu': 'TEXT', 'rinrei': 'INTEGER', 'menseki': 'REAL',
    'zaiseki': 'REAL', 'shoyu': 'TEXT', 'sagyo': 'TEXT', 'biko': 'TEXT', 'kosin': 'TEXT',
  });
  await g0.dispose();

  // QGIS 製を想定して rtree を付ける（中身は空で置き、最後の「索引の焼き直し」で全件入れる）。
  // Android の SQLite には rtree が無いので、そのときは geodiff の SQLite で作る
  const createRtree = 'CREATE VIRTUAL TABLE IF NOT EXISTS rtree_stands_geom USING rtree(id, minx, maxx, miny, maxy)';
  try {
    final d = await openDatabase(base, singleInstance: false);
    try {
      await d.execute(createRtree);
    } finally {
      await d.close();
    }
  } on DatabaseException {
    final g = Geodiff();
    final err = g.execSql(base, '$createRtree;');
    g.dispose();
    if (err != null) throw StateError('rtree を作れない: $err');
  }

  final rnd = Random(42);
  final db = await openDatabase(base, singleInstance: false);
  await db.transaction((txn) async {
    final batch = txn.batch();
    for (var i = 0; i < features; i++) {
      final cx = 135.9 + rnd.nextDouble() * 0.2;
      final cy = 33.9 + rnd.nextDouble() * 0.2;
      final ring = <LatLng>[
        for (var k = 0; k < 12; k++)
          LatLng(cy + 0.0005 * sin(k * pi / 6), cx + 0.0005 * cos(k * pi / 6)),
        LatLng(cy, cx + 0.0005),
      ];
      batch.rawInsert(
        'INSERT INTO stands (geom, rinpan, shohan, jusyu, rinrei, menseki, zaiseki, shoyu, sagyo, biko, kosin) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          createWkbPolygon([ring]), '${i ~/ 100}', '${i % 100}', ['スギ', 'ヒノキ', '広葉樹'][i % 3], 10 + i % 80,
          0.1 + rnd.nextDouble() * 5, rnd.nextDouble() * 400, '北山村', '', '', '2026-04-01',
        ],
      );
    }
    await batch.commit(noResult: true);
  });
  await db.close();
  final bytes = File(base).lengthSync();

  final ms = <String, int>{};
  final g = Geodiff();
  try {
    final mine = p.join(dir, 'bench_mine.gpkg');
    final theirs = p.join(dir, 'bench_theirs.gpkg');
    final sw = Stopwatch()..start();
    g.makeCopySqlite(base, mine);
    ms['base の写し'] = sw.elapsedMilliseconds;
    g.makeCopySqlite(base, theirs);

    Future<void> editRows(String path, int from, String what) async {
      final d = await openDatabase(path, singleInstance: false);
      await d.transaction((txn) async {
        for (var i = 0; i < edits; i++) {
          await txn.rawUpdate('UPDATE stands SET sagyo = ? WHERE fid = ?', [what, from + i * 37]);
        }
      });
      await d.close();
    }

    await editRows(mine, 1, '間伐(端末)');
    await editRows(theirs, 20, '下刈(相手)');

    sw.reset();
    final r = await GpkgMerger(g).rebase(base: base, theirs: theirs, mine: mine);
    ms['rebase(各$edits行)'] = sw.elapsedMilliseconds;
    if (!r.success) throw StateError('rebase 失敗: ${r.error}');

    sw.reset();
    await GpkgIndexRepair.rebuildFile(mine);
    ms['索引の焼き直し'] = sw.elapsedMilliseconds;
  } finally {
    g.dispose();
  }
  return GeodiffBenchResult(features, bytes, ms);
}
