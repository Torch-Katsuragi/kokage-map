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
    Future<GeoPackageFile> layerWithSrs(int srsId, String definition, {int? epsg}) async {
      final path = '${tmp.path}/c.gpkg';
      final gpkg = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
      await gpkg.addLayer('pts', GeometryType.point);
      await gpkg.flushChanges();
      await gpkg.dispose();
      final db = await openDatabase(path, singleInstance: false);
      await db.execute(
        'INSERT OR IGNORE INTO gpkg_spatial_ref_sys (srs_name, srs_id, organization, organization_coordsys_id, definition) '
        "VALUES ('test', ?, 'EPSG', ?, ?)",
        [srsId, epsg ?? srsId, definition],
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
      final back = (features.single[featureGeometryKey] as List<LatLng>).single;
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

    // GDAL の書く地理座標系の WKT は緯度・経度の順の AXIS を持つ。gpkg の中は経度・緯度のまま
    for (final (label, srsId, epsg, wkt) in [
      ('WGS 84', 100000, 4326, _gdalWgs84),
      ('JGD2011', 100001, 6668, _gdalJgd2011),
    ]) {
      test('独自の srs_id に入った $label（EPSG:$epsg・緯度経度の AXIS 付き）も x = 経度で読み書きする', () async {
        final (raw, back) = await writeAndRead(await layerWithSrs(srsId, wkt, epsg: epsg));
        expect(raw.x, closeTo(135.96, 1e-9));
        expect(raw.y, closeTo(33.93, 1e-9));
        expect(back.latitude, closeTo(kitayama.latitude, 1e-9));
        expect(back.longitude, closeTo(kitayama.longitude, 1e-9));
      });
    }

    // 定義の無い日本の CRS は手元の表で解く（epsg.io に問い合わせず、gpkg にも書き戻さない → gpkg_open_no_write_test）
    test('JGD2000 地理座標系（4612）は 6668 と同じく変換しない', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(4612, 'undefined'));
      expect(raw.x, 135.96);
      expect(raw.y, 33.93);
      expect(back, kitayama);
    });

    test('JGD2000 平面直角 VI 系（2448）は JGD2011 の VI 系と同じ値', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(2448, 'undefined'));
      expect(raw.x, closeTo(-3700, 1000));
      expect(raw.y, closeTo(-230000, 10000));
      expect(back.latitude, closeTo(kitayama.latitude, 1e-6));
      expect(back.longitude, closeTo(kitayama.longitude, 1e-6));
    });

    // 期待値は PROJ 9（pyproj）で WGS 84 → Tokyo。PROJ が既定に選ぶ EPSG:15484（Tokyo to WGS 84 (108)）の
    // 3 パラメータ（-146.414, 507.337, 680.507）。QGIS もグリッドが無ければこれを使う
    test('旧日本測地系の地理座標系（4301）は測地系を変換する', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(4301, 'undefined'));
      expect(raw.x, closeTo(135.962844, 1e-5));
      expect(raw.y, closeTo(33.926659, 1e-5));
      expect(back.latitude, closeTo(kitayama.latitude, 1e-6));
      expect(back.longitude, closeTo(kitayama.longitude, 1e-6));
    });

    test('旧日本測地系の平面直角 VI 系（30166）は測地系を変換し、x = 東で書く', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(30166, 'undefined'));
      expect(raw.x, closeTo(-3434.86, 1));
      expect(raw.y, closeTo(-229968.39, 1));
      expect(back.latitude, closeTo(kitayama.latitude, 1e-6));
      expect(back.longitude, closeTo(kitayama.longitude, 1e-6));
    });

    test('Web メルカトル（3857）はメートルで書き、同じ位置で読み戻す', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(3857, 'undefined'));
      expect(raw.x, closeTo(15134998, 1));
      expect(raw.y, closeTo(4019407, 1));
      expect(back.latitude, closeTo(kitayama.latitude, 1e-6));
      expect(back.longitude, closeTo(kitayama.longitude, 1e-6));
    });

    test('3 次元の地理座標系（WGS 84 の 4979）も変換しない（epsg.io に問い合わせない）', () async {
      final (raw, back) = await writeAndRead(await layerWithSrs(4979, 'undefined'));
      expect(raw.x, 135.96);
      expect(raw.y, 33.93);
      expect(back, kitayama);
    });
  });
}

const _gdalWgs84 = 'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],'
    'AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,'
    'AUTHORITY["EPSG","9122"]],AXIS["Latitude",NORTH],AXIS["Longitude",EAST],AUTHORITY["EPSG","4326"]]';
const _gdalJgd2011 = 'GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS 1980",6378137,298.257222101,'
    'AUTHORITY["EPSG","7019"]],AUTHORITY["EPSG","1128"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],'
    'UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AXIS["Latitude",NORTH],AXIS["Longitude",EAST],'
    'AUTHORITY["EPSG","6668"]]';
