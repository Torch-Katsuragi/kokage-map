// 開いて見るだけの gpkg を書き換えない。
// Drive 同期では端末で更新されたファイルはこちらの変更として上げるので、見ただけで
// 持ち主（QGIS 側）のファイルが変わってしまう（2026-10-12 の試験で見つけた）
//
// - 主キーの無い表: 以前は主キーを調べるだけで fid 列を足していた。QGIS（GDAL）と同じく rowid で読み書きする
// - 定義の無い CRS: 以前は epsg.io に問い合わせて gpkg に書き戻していた。手元の表とメモリだけで解く
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/coordinate/index.dart';
import 'package:root_maps/services/google_drive/sync_base_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/foreign_geom_gpkg.dart';

void main() {
  late Directory tmp;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_open_');
    path = '${tmp.path}/o.gpkg';
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String digest() => sha256.convert(File(path).readAsBytesSync()).toString();
  GeoPackageFile open() => GeoPackageFile(const ['o.gpkg'], absolutePath: path);

  /// 点を 2 つ持つレイヤ pts を作り、[raw] で gpkg を直接いじる
  Future<void> build(Future<void> Function(Database db) raw) async {
    final gpkg = open();
    await gpkg.addLayer('pts', GeometryType.point);
    await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
    await gpkg.addPointWithAttributes('pts', const LatLng(33.93, 135.96), {'name': 'a'});
    await gpkg.addPointWithAttributes('pts', const LatLng(33.94, 135.97), {'name': 'b'});
    await gpkg.flushChanges();
    await gpkg.dispose();
    final db = await openDatabase(path, singleInstance: false);
    await raw(db);
    await db.close();
    GpkgCrsResolver.instance.clearCache();
  }

  /// 主キーの無い表に作り直す（GDAL は「no integer primary key」と言って rowid を FID に使う）
  Future<void> dropPrimaryKey(Database db) async {
    await db.execute('CREATE TABLE tmp AS SELECT geom, name FROM pts');
    await db.execute('DROP TABLE pts');
    await db.execute('ALTER TABLE tmp RENAME TO pts');
  }

  Future<List<String>> columns() async {
    final db = await openDatabase(path, singleInstance: false, readOnly: true);
    final rows = await db.rawQuery('PRAGMA table_info(pts)');
    await db.close();
    return [for (final r in rows) r['name']! as String];
  }

  group('主キーの無い表', () {
    test('読んで地物を選ぶだけならファイルを変えない（fid 列を足さない）', () async {
      await build(dropPrimaryKey);
      final before = digest();

      final gpkg = open();
      expect(await gpkg.getPrimaryKeyColumn('pts'), 'rowid');
      final features = await gpkg.getFeaturesWithGeometry('pts');
      expect(features, hasLength(2));
      final ids = [for (final f in features) f['id']];
      expect(ids, [1, 2]);
      expect(await gpkg.getFeatureAttribute('pts', 2, 'name'), 'b');
      await gpkg.dispose();

      expect(await columns(), ['geom', 'name']);
      expect(digest(), before);
    });

    test('編集も rowid で行い、列は足さない（QGIS と同じ FID のまま）', () async {
      await build(dropPrimaryKey);
      final gpkg = open();
      final id = await gpkg.addPointWithAttributes('pts', const LatLng(33.95, 135.98), {'name': 'c'});
      expect(id, 3);
      expect(await gpkg.getFeatureAttribute('pts', 3, 'name'), 'c');
      expect(await gpkg.updateFeatureAttribute('pts', 1, 'name', 'A'), isTrue);
      await gpkg.flushChanges();
      expect(await gpkg.getFeatureAttribute('pts', 1, 'name'), 'A');
      expect(await gpkg.removeFeature('pts', 2), isTrue);
      final ids = [for (final f in await gpkg.getFeaturesWithGeometry('pts')) f['id']];
      expect(ids, [1, 3]);
      await gpkg.dispose();
      expect(await columns(), ['geom', 'name']);
    });
  });

  group('形の列が geom 以外', () {
    for (final kind in ForeignGeomGpkg.all) {
      test('${kind.label}: 地物・列・検索を読むだけならファイルを変えない', () async {
        await kind.write(path);
        final before = digest();

        final gpkg = open();
        expect(await gpkg.getFeaturesWithGeometry(kind.table), hasLength(2));
        expect(await gpkg.getFeature(kind.table, 1), isNotNull);
        await gpkg.getColumnNames(kind.table, getAll: true);
        await gpkg.getAttributeColumnInfo(kind.table);
        await gpkg.searchAttributeRows(kind.table, ['a']);
        await gpkg.dispose();

        expect(digest(), before);
      });
    }
  });

  // 見ただけの gpkg を閉じるときに書き直さない（2fa11fbf）× Drive の上書きダウンロード（closeAllFor で閉じる）。
  // 置き換える前に書いていると「書いた」印が残り、落としたファイルを見ただけで閉じるときに範囲と rtree を書き直していた
  test('書いたあと Drive から落として置き換えたファイルは、見ただけなら閉じても変えない', () async {
    const kind = ForeignGeomGpkg.arcgis; // rtree つき
    await kind.write(path);
    final edited = open();
    await edited.addPointWithAttributes(kind.table, const LatLng(33.95, 135.98), {'name': 'c'});
    await edited.flushChanges();

    await SyncBaseStore.releaseBeforeOverwrite(path);
    File(path).deleteSync();
    await kind.write(path); // 落とした中身
    await SyncBaseStore.settleAfterDownload(path);
    final before = digest();

    final viewer = open();
    expect(await viewer.getFeaturesWithGeometry(kind.table), hasLength(2));
    await viewer.dispose();
    expect(digest(), before);
    await edited.dispose(); // 置き換える前の接続も、閉じるだけ
    expect(digest(), before);
    expect(GeoPackageConnection.openCountFor(path), 0);
  });

  group('定義の無い CRS', () {
    for (final (srsId, name) in [
      (4612, 'JGD2000'),
      (2448, 'JGD2000 / Japan Plane Rectangular CS VI'),
      (2456, 'JGD2000 / Japan Plane Rectangular CS XIV'),
      (4301, 'Tokyo'),
      (30166, 'Tokyo / Japan Plane Rectangular CS VI'),
    ]) {
      test('EPSG:$srsId（$name）は手元で解き、gpkg に書き戻さない', () async {
        await build((db) async {
          await db.execute(
            'INSERT OR IGNORE INTO gpkg_spatial_ref_sys (srs_name, srs_id, organization, organization_coordsys_id, definition) '
            "VALUES (?, ?, 'EPSG', ?, 'undefined')",
            [name, srsId, srsId],
          );
          await db.execute('UPDATE gpkg_geometry_columns SET srs_id = ? WHERE table_name = ?', [srsId, 'pts']);
        });
        final before = digest();

        final gpkg = open();
        final crs = await GpkgCrsResolver.instance.resolveLayerCrs(await gpkg.getDatabase(), 'pts');
        expect(crs.epsgCode, 'EPSG:$srsId');
        expect(crs.isWgs84 || crs.projection != null, isTrue, reason: 'WGS84 に落ちていない');
        expect(crs.srsId, srsId);
        await gpkg.getFeaturesWithGeometry('pts');
        await gpkg.dispose();

        expect(digest(), before);
      });
    }
  });
}
