// GPKG の srs 定義から CRS を解決し、その CRS での座標の向きを固定する
// （.prj の読み取りと Shapefile の読み込みは GDAL に置き換えた。2026-10-10）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/coordinate/index.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  // 和歌山県北山村付近。VI 系（原点 36N, 136E）では北に約 -230 km、東に約 -4 km
  const kitayama = LatLng(33.93, 135.96);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => tmp = await Directory.systemTemp.createTemp('crs_res_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('GPKG のレイヤ CRS（どの定義でも GDAL と同じ x = 東・y = 北で保存）', () {
    Future<GeoPackageFile> layerWithSrs(int srsId, String definition) async {
      final path = '${tmp.path}/c.gpkg';
      final gpkg = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
      await gpkg.addLayer('pts', GeometryType.point);
      await gpkg.flushChanges();
      await gpkg.dispose();
      final db = await openDatabase(path, singleInstance: false);
      await db.execute(
        'INSERT OR IGNORE INTO gpkg_spatial_ref_sys (srs_name, srs_id, organization, organization_coordsys_id, definition) '
        "VALUES ('test', ?, 'EPSG', ?, ?)",
        [srsId, srsId, definition],
      );
      await db.execute('UPDATE gpkg_geometry_columns SET srs_id = ? WHERE table_name = ?', [srsId, 'pts']);
      await db.close();
      GpkgCrsResolver.instance.clearCache();
      return GeoPackageFile(const ['c.gpkg'], absolutePath: path);
    }

    Future<(geo.Position, LatLng)> writeAndRead(GeoPackageFile gpkg) async {
      await gpkg.addPointWithAttributes('pts', kitayama, {});
      await gpkg.flushChanges();
      final rows = await (await gpkg.getDatabase()).rawQuery('SELECT geom FROM pts');
      final raw = (parseGpkgGeometry(rows.single['geom']! as dynamic)! as geo.Point).position;
      final features = await gpkg.getFeaturesWithGeometry('pts');
      final back = (features.single['geometry'] as List<LatLng>).single;
      await gpkg.dispose();
      return (raw, back);
    }

    for (final (label, definition) in [
      ('定義なし（レジストリで解決）', 'undefined'),
      ('ESRI WKT の定義', EpsgRegistry.instance.getWktString('EPSG:6674')!),
      ('proj4 の定義', EpsgRegistry.instance.getByCode('EPSG:6674')!.proj4String),
    ]) {
      test('EPSG:6674 $label', () async {
        final (raw, back) = await writeAndRead(await layerWithSrs(6674, definition));
        expect(raw.x, closeTo(-3700, 1000)); // Easting
        expect(raw.y, closeTo(-230000, 10000)); // Northing
        expect(back.latitude, closeTo(kitayama.latitude, 1e-6));
        expect(back.longitude, closeTo(kitayama.longitude, 1e-6));
      });
    }

    test('UTM は入れ替えない（X=Easting）', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(32653, 'undefined'));
      expect(raw.x, closeTo(588700, 2000)); // Easting
      expect(raw.y, closeTo(3755000, 5000)); // Northing
      expect(back.latitude, closeTo(kitayama.latitude, 1e-6));
      expect(back.longitude, closeTo(kitayama.longitude, 1e-6));
    });

    test('JGD2011 地理座標系（6668）は変換しない', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(6668, 'undefined'));
      expect(raw.x, 135.96);
      expect(raw.y, 33.93);
      expect(back, kitayama);
    });
  });
}
