// ConflictRestorer（衝突を相手の値に戻す）と、通知の操作ボタン
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/services/google_drive/conflict_restorer.dart';
import 'package:root_maps/services/google_drive/gpkg_merger.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:root_maps/widgets/notification/notification_popup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.ja);
    tmp = await Directory.systemTemp.createTemp('restore_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<List<Map<String, Object?>>> q(String path, String sql) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      return await db.rawQuery(sql);
    } finally {
      await db.close();
    }
  }

  test('値とジオメトリを相手の値に戻す。QGIS のトリガーが付いていても書けて、閉じたら戻っている', () async {
    final path = '${tmp.path}/d.gpkg';
    final g = GeoPackageFile(const ['d.gpkg'], absolutePath: path);
    await g.addLayer('trees', GeometryType.point);
    await g.addAttributeColumns('trees', {'name': 'TEXT', 'dbh': 'INTEGER'});
    await g.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {'name': 'こちら', 'dbh': 31});
    await g.flushChanges();
    await g.dispose();
    // GDAL と同じ、ST_ 関数を使うトリガー（このホストの SQLite にも ST_ 関数は無い）
    final db = await openDatabase(path, singleInstance: false);
    await db.execute('CREATE TRIGGER "rtree_trees_geom_update1" AFTER UPDATE OF "geom" ON "trees" '
        'WHEN NOT ST_IsEmpty(NEW."geom") BEGIN SELECT ST_MinX(NEW."geom"); END');
    await db.close();

    final info = await q(path, 'PRAGMA table_info(trees)');
    int col(String name) => info.firstWhere((r) => r['name'] == name)['cid']! as int;
    final cloudGeom = base64Encode(createWkbPoint(136.0, 34.0));

    final n = await ConflictRestorer.restoreTheirs([
      GpkgConflict(table: 'trees', fid: '1', column: col('name'), base: '元', theirs: 'クラウド', mine: 'こちら', filePath: path),
      GpkgConflict(table: 'trees', fid: '1', column: col('dbh'), base: 30, theirs: 33, mine: 31, filePath: path),
      GpkgConflict(table: 'trees', fid: '1', column: col('geom'), theirs: cloudGeom, filePath: path),
      // 削除がらみは戻さない
      GpkgConflict(table: 'trees', fid: '9', column: col('name'), mine: 'x', theirsDeleted: true, filePath: path),
    ]);
    expect(n, 3);

    final row = (await q(path, 'SELECT name, dbh, geom FROM trees WHERE fid = 1')).single;
    expect(row['name'], 'クラウド');
    expect(row['dbh'], 33);
    final env = gpkgEnvelope(row['geom']! as dynamic)!;
    expect(env.minX, closeTo(136.0, 1e-9));
    expect(env.minY, closeTo(34.0, 1e-9));
    expect((await q(path, "SELECT name FROM sqlite_master WHERE type = 'trigger'")).map((r) => r['name']),
        contains('rtree_trees_geom_update1'), reason: '閉じたらトリガーを戻す');
  });

  test('戻せる衝突が無ければ何もしない', () async {
    expect(
      await ConflictRestorer.restoreTheirs([
        const GpkgConflict(table: 't', fid: '1', column: 2, mineDeleted: true, filePath: 'x'),
        const GpkgConflict(table: 't', fid: '1', column: 2), // ファイル不明
      ]),
      0,
    );
  });

  testWidgets('通知の操作ボタンは一度だけ押せて、押したら「済み」になる', (tester) async {
    var calls = 0;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(notificationCenterProvider.notifier).add(
          title: '両方で変えた行が 1 行ありました',
          actionLabel: t.drive.restoreTheirs,
          onAction: () async => calls++,
        );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) => NotificationPopup(onDismiss: () {}, ref: ref)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.drive.restoreTheirs), findsOneWidget);
    await tester.tap(find.text(t.drive.restoreTheirs));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text(t.notification.actionDone), findsOneWidget);
    await tester.tap(find.text(t.notification.actionDone));
    await tester.pumpAndSettle();
    expect(calls, 1, reason: '二度は押せない');
  });
}
