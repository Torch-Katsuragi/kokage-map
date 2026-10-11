// 主キーの無い表（rowid で読み書き）と、形の列が geom 以外の表が重なった gpkg で、
// 同じ夜に入った機能（検索・結合の書き出し・GNSS 品質の列・属性の読み書き）が噛み合うか。
//
// 片方ずつは gpkg_open_no_write_test・gpkg_geometry_column_test で見ている。ここは組み合わせ
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/feature_repository.dart' show metadataColumn;
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/feature_search.dart';
import 'package:root_maps/services/import_export/import_export_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/foreign_geom_gpkg.dart';

void main() {
  late Directory tmp;
  late String path;
  const kind = ForeignGeomGpkg.geopandas; // 表 parcels・形の列 geometry・geom というふつうの列あり
  const table = 'parcels';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_rowid_geom_');
    path = '${tmp.path}/r.gpkg';
    await kind.write(path);
    // 主キーを外す（pandas の to_sql などで作った表）。GDAL は rowid を FID にする
    final db = await openDatabase(path, singleInstance: false);
    await db.execute('CREATE TABLE tmp AS SELECT geometry, name, geom FROM $table');
    await db.execute('DROP TABLE $table');
    await db.execute('ALTER TABLE tmp RENAME TO $table');
    await db.close();
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String digest() => sha256.convert(File(path).readAsBytesSync()).toString();
  GeoPackageFile open() => GeoPackageFile(const ['r.gpkg'], absolutePath: path);

  test('地物・検索を読むだけならファイルを変えない', () async {
    final before = digest();
    final gpkg = open();
    expect(await gpkg.getPrimaryKeyColumn(table), 'rowid');
    final layer = PointLayerNode(gpkg, table, parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
    final features = layer.children.whereType<FeatureNode>().toList();
    expect([for (final f in features) f.rowId], [1, 2]);
    // geom はふつうの属性として読める（形の列 geometry とは別）
    expect(features.first.turfFeature.properties?['geom'], 'geom-a');

    final r = await FeatureSearch.search([layer], 'b');
    expect([for (final h in r.hits) h.feature.rowId], contains(2));
    await gpkg.dispose();
    expect(digest(), before);
  });

  test('点を足し・属性を書き換えても列は増えず、rowid で引ける', () async {
    final gpkg = open();
    final id = await gpkg.addPointWithAttributes(table, const LatLng(33.95, 135.98), {'name': 'c', 'geom': 'geom-c'});
    expect(id, 3);
    expect(await gpkg.updateFeatureAttribute(table, 3, 'name', 'C'), isTrue);
    await gpkg.flushChanges();
    final f = await gpkg.getFeature(table, 3);
    expect(f?['name'], 'C');
    expect(f?['geom'], 'geom-c');
    await gpkg.dispose();

    final db = await openDatabase(path, singleInstance: false, readOnly: true);
    final cols = [for (final r in await db.rawQuery('PRAGMA table_info($table)')) r['name']];
    await db.close();
    expect(cols, ['geometry', 'name', 'geom']);
  });

  test('結合・行番号・GNSS 品質の列を足す書き出しの SELECT が rowid の表で通る', () async {
    final gpkg = open();
    await gpkg.addAttributeColumns(table, {metadataColumn: 'TEXT'});
    final pk = await gpkg.getPrimaryKeyColumn(table);
    final joined = JoinedExport(pk: pk, columns: const ['j_area'], rows: const {
      2: [1.5],
    });
    final args = ImportExportService.exportArgs(
      format: FileFormat.geojson,
      layerName: table,
      geometryType: null,
      rowNumberPk: pk,
      gnssQuality: true,
      joined: joined,
    );
    final sql = args[args.indexOf('-sql') + 1];
    final db = await gpkg.getDatabase();
    final rows = await db.rawQuery(sql);
    expect(rows, hasLength(2));
    expect([for (final r in rows) r['j_area']], [null, 1.5]);
    expect([for (final r in rows) r['ROW_NUM']], [1, 2]);
    expect(rows.first.containsKey('gnss_fix'), isTrue);
    // 形の列は geometry のまま出る（GDAL が形として拾う）
    expect(rows.first.containsKey('geometry'), isTrue);
    await gpkg.dispose();
  });
}
