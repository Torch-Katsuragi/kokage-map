// CRS の解決（.prj の WKT・GPKG の srs 定義）と、解決した CRS での座標の向きを固定する
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/coordinate/index.dart';
import 'package:root_maps/services/import_export/exporters/shapefile_writer.dart';
import 'package:root_maps/services/import_export/parsers/prj_reader.dart';
import 'package:root_maps/services/import_export/parsers/shapefile_binary_parser.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  final registry = EpsgRegistry.instance;
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

  Future<EpsgDefinition?> readPrj(String content) async {
    final path = '${tmp.path}/t.prj';
    await File(path).writeAsString(content);
    return PrjReader.read(path);
  }

  group('.prj の WKT から CRS を推定', () {
    test('AUTHORITY 付きはレジストリの定義を返す', () async {
      final def = await readPrj(
        'PROJCS["JGD2011 / Japan Plane Rectangular CS VI",AUTHORITY["EPSG","6674"]]',
      );
      expect(identical(def, registry.getByCode('EPSG:6674')), isTrue);
    });

    test('EPSG:XXXX 表記もレジストリの定義を返す', () async {
      final def = await readPrj('LOCAL_CS["x EPSG:2448"]');
      expect(def?.code, 'EPSG:2448');
      expect(def?.proj4String, startsWith('+proj=tmerc'));
    });

    test('コードの無い ESRI WKT は WKT のまま定義にする', () async {
      final wkt = registry.getWktString('EPSG:6674')!;
      final def = await readPrj(wkt);
      expect(def?.code, 'WKT');
      expect(def?.proj4String, wkt);
    });

    test('レジストリに無いコードは WKT のまま、コードは残す', () async {
      final wkt = registry
          .getWktString('EPSG:6674')!
          .replaceFirst(',UNIT["Meter",1.0]]', ',UNIT["Meter",1.0],AUTHORITY["EPSG","99999"]]');
      final def = await readPrj(wkt);
      expect(def?.code, 'EPSG:99999');
      expect(def?.proj4String, wkt);
    });

    test('proj4dart が読めない WKT は proj4 文字列を組み立てる', () async {
      final def = await readPrj('UNKNOWN["GCS_WGS_1984",DATUM["D_WGS_1984"]]');
      expect(def?.code, 'CONVERTED');
      expect(def?.proj4String, '+proj=longlat +datum=WGS84 +no_defs');
    });
  });

  group('Shapefile の読み込み（平面直角は入れ替えずに E, N として読む）', () {
    Future<LatLng> readPoint(List<double> xy, EpsgDefinition? crs) async {
      final r = encodeShpShx(ShapeType.point, [
        [
          [xy]
        ],
      ]);
      final path = '${tmp.path}/p.shp';
      File(path).writeAsBytesSync(r.shp);
      LatLng? got;
      await ShapefileBinaryParser.parseRecords(
        path,
        sourceCoordinateSystem: crs,
        onRecord: (i, t, g) async => got = g as LatLng,
      );
      return got!;
    }

    test('EPSG:6674 の (E, N) を緯度経度に戻す', () async {
      final vi = registry.getByCode('EPSG:6674')!;
      final xy = CoordinateService.instance.transformToXY(kitayama, vi)!;
      // transformToXY は X=Northing, Y=Easting。Shapefile は (E, N) で書く
      final got = await readPoint([xy['y']!, xy['x']!], vi);
      expect(got.latitude, closeTo(kitayama.latitude, 1e-6));
      expect(got.longitude, closeTo(kitayama.longitude, 1e-6));
    });

    test('WKT のまま持った定義でも同じ結果', () async {
      final vi = registry.getByCode('EPSG:6674')!;
      final xy = CoordinateService.instance.transformToXY(kitayama, vi)!;
      final fromWkt = await readPrj(registry.getWktString('EPSG:6674')!);
      final got = await readPoint([xy['y']!, xy['x']!], fromWkt);
      expect(got.latitude, closeTo(kitayama.latitude, 1e-6));
      expect(got.longitude, closeTo(kitayama.longitude, 1e-6));
    });

    test('CRS なしは緯度経度として読む', () async {
      final got = await readPoint([135.96, 33.93], null);
      expect(got, kitayama);
    });
  });

  group('GPKG のレイヤ CRS（平面直角は X=Northing, Y=Easting で保存）', () {
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
        expect(raw.x, closeTo(-230000, 10000)); // Northing
        expect(raw.y, closeTo(-3700, 1000)); // Easting
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
