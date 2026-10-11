// Z・M 付きのレイヤの編集（docs/technical/external-formats.md「Z・M 付きのレイヤの編集」）
//
// - 動かしていない頂点は元の Z・M、動かした頂点・足した頂点・新しい地物は標高（ここでは偽の標高）、M は 0
// - 2D のレイヤは 2D のまま
// - GDAL（QGIS の gdal*.dll）で作った Z 付き gpkg を編集し、GDAL で Z 付きのまま読めること（無ければ skip）
//
// ⚠ GDAL を sqflite より先に読み込む（QGIS の DLL は sqlite3.dll を名前で読む。test/gdal_test.dart の注意）
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/core/terrain/dem_point_sampler.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/vertex_z.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/gdal_host.dart';
import 'support/gdal_scenarios.dart';

const _dem = 777.0;

/// 偽の標高: どこでも [_dem] m。引かれた点を覚える
final _asked = <(double, double)>[];
Future<List<double?>> _fakeDem(List<(double, double)> pts) async {
  _asked.addAll(pts);
  return [for (final _ in pts) _dem];
}

/// blob の全頂点（保存した CRS のまま）
List<geo.Position> _positions(Object? blob) {
  final g = parseGpkgGeometry(blob! as Uint8List)!;
  return switch (g) {
    geo.Point() => [g.position],
    geo.MultiPoint() => g.positions.toList(),
    geo.LineString() => g.chain.positions.toList(),
    geo.MultiLineString() => [for (final c in g.chains) ...c.positions],
    geo.Polygon() => [for (final r in g.rings) ...r.positions],
    geo.MultiPolygon() => [for (final poly in g.polygons) for (final r in poly.rings) ...r.positions],
    _ => throw StateError('$g'),
  };
}

/// WKB の型番号（GPB ヘッダーの後ろ、リトルエンディアン前提）
int _wkbType(Object? blob) {
  final b = blob! as Uint8List;
  final flags = b[3];
  final env = switch ((flags >> 1) & 7) { 1 => 32, 2 || 3 => 48, 4 => 64, _ => 0 };
  return ByteData.sublistView(b, 8 + env + 1, 8 + env + 5).getUint32(0, Endian.little);
}

void main() {
  late Directory tmp;
  final gdalConfig = findHostGdal();
  final skipGdal = gdalConfig == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null;
  GdalFfi? gdal;

  setUpAll(() async {
    if (gdalConfig != null) {
      gdal = GdalFfi(gdalConfig);
      await gdal!.version();
    }
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_z_');
    _asked.clear();
    VertexZ.elevationLookup = _fakeDem;
  });
  tearDown(() async {
    VertexZ.elevationLookup = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// アプリでレイヤを作り、z・m を書き換えて Z 付きの行を 1 つ入れる
  Future<(GeoPackageFile, int)> zLayer(String name, GeometryType type, geo.Geometry geom, {int z = 1, int m = 0}) async {
    final path = p.join(tmp.path, '$name.gpkg');
    var gpkg = GeoPackageFile(['$name.gpkg'], absolutePath: path);
    await gpkg.addLayer(name, type);
    await gpkg.flushChanges();
    await gpkg.dispose();
    final db = await openDatabase(path, singleInstance: false);
    await db.execute('UPDATE gpkg_geometry_columns SET z = ?, m = ? WHERE table_name = ?', [z, m, name]);
    final id = await db.rawInsert('INSERT INTO "$name" (geom) VALUES (?)', [createGpkgWkb(geom)]);
    await db.close();
    gpkg = GeoPackageFile(['$name.gpkg'], absolutePath: path);
    return (gpkg, id);
  }

  Future<Object?> blobOf(GeoPackageFile gpkg, String table, int id) async =>
      (await (await gpkg.getDatabase()).rawQuery('SELECT geom FROM "$table" WHERE fid = ?', [id])).single['geom'];

  group('Z 付きのレイヤ（WKB を直に作る）', () {
    test('線: 動かしていない頂点の Z は元のまま、動かした・足した頂点は標高', () async {
      final line = geo.MultiLineString.from([
        [
          const geo.Geographic(lon: 135.90, lat: 33.90, elev: 100.5),
          const geo.Geographic(lon: 135.91, lat: 33.91, elev: 200.25),
          const geo.Geographic(lon: 135.92, lat: 33.92, elev: 300.125),
        ],
      ]);
      final (gpkg, id) = await zLayer('lines', GeometryType.linestring, line);
      final f = await gpkg.getFeature('lines', id);
      final pts = List<LatLng>.of((f![featureGeometryKey] as List).first as List<LatLng>);
      pts[1] = const LatLng(33.915, 135.912); // 動かす
      pts.insert(2, const LatLng(33.918, 135.918)); // 足す
      expect(await gpkg.updateLine('lines', id, pts), isTrue);
      final out = _positions(await blobOf(gpkg, 'lines', id));
      final type = _wkbType(await blobOf(gpkg, 'lines', id));
      await gpkg.dispose();

      expect(type, 1005, reason: 'ISO WKB の MultiLineString Z');
      expect([for (final q in out) q.optZ], [100.5, _dem, _dem, 300.125]);
      expect(out.every((q) => !q.isMeasured), isTrue);
      expect(_asked, hasLength(2), reason: '標高を引くのは動かした・足した頂点だけ');
    });

    test('点: 属性だけ書き換えると元の Z、動かすと標高。新しい点も標高', () async {
      final (gpkg, id) = await zLayer('pts', GeometryType.point, const geo.Point(geo.Geographic(lon: 135.9, lat: 33.9, elev: 42.0)));
      await gpkg.updatePoint('pts', id, const LatLng(33.9, 135.9), name: 'a');
      expect(_positions(await blobOf(gpkg, 'pts', id)).single.optZ, 42.0);
      await gpkg.updatePoint('pts', id, const LatLng(33.95, 135.95));
      expect(_positions(await blobOf(gpkg, 'pts', id)).single.optZ, _dem);
      final added = await gpkg.addPoint('pts', const LatLng(33.8, 135.8));
      final batch = await gpkg.addPointsBatch('pts', [
        {'point': const LatLng(33.7, 135.7)},
      ]);
      expect(_positions(await blobOf(gpkg, 'pts', added!)).single.optZ, _dem);
      expect(_positions(await blobOf(gpkg, 'pts', batch.single)).single.optZ, _dem);
      expect(_wkbType(await blobOf(gpkg, 'pts', added)), 1001);
      await gpkg.dispose();
    });

    test('面（EPSG:6674）: 投影座標を往復しても動かしていない頂点の Z が残る。z=1 のまま', () async {
      const ring = [(135.95, 33.90, 10.0), (135.97, 33.90, 20.0), (135.97, 33.92, 30.0), (135.95, 33.90, 10.0)];
      final (gpkg0, _) = await zLayer('polys', GeometryType.polygon, const geo.Point(geo.Geographic(lon: 0, lat: 0)));
      await gpkg0.dispose();
      // CRS を 6674 にし、平面直角座標で Z 付きの面を入れ直す
      final path = p.join(tmp.path, 'polys.gpkg');
      final db = await openDatabase(path, singleInstance: false);
      await db.execute(
        'INSERT OR IGNORE INTO gpkg_spatial_ref_sys (srs_name, srs_id, organization, organization_coordsys_id, definition) '
        "VALUES ('JGD2011 / Japan Plane Rectangular CS VI', 6674, 'EPSG', 6674, 'undefined')",
      );
      await db.execute("UPDATE gpkg_geometry_columns SET srs_id = 6674 WHERE table_name = 'polys'");
      await db.execute('DELETE FROM polys');
      await db.close();
      var gpkg = GeoPackageFile(const ['polys.gpkg'], absolutePath: path);
      final id = await gpkg.addPolygonWithAttributes('polys', [
        [for (final (lon, lat, _) in ring) LatLng(lat, lon)],
      ], {});
      await gpkg.dispose();
      // 書いた面に Z を付ける（GDAL で変換した Z 付きの面の代わり）
      final db2 = await openDatabase(path, singleInstance: false);
      final stored = _positions((await db2.rawQuery('SELECT geom FROM polys')).single['geom']);
      final withZ = geo.MultiPolygon.from([
        [
          [for (var i = 0; i < stored.length; i++) geo.Projected(x: stored[i].x, y: stored[i].y, z: ring[i].$3)],
        ],
      ]);
      await db2.execute('UPDATE polys SET geom = ? WHERE fid = ?', [createGpkgWkb(withZ, srsId: 6674), id]);
      await db2.close();

      gpkg = GeoPackageFile(const ['polys.gpkg'], absolutePath: path);
      final f = await gpkg.getFeature('polys', id!);
      final rings = ((f![featureGeometryKey] as List).first as List).cast<List<LatLng>>();
      final outer = List<LatLng>.of(rings.first);
      outer[2] = const LatLng(33.925, 135.972); // 動かす
      outer.insert(3, const LatLng(33.91, 135.955)); // 足す
      await gpkg.updatePolygon('polys', id, [outer]);
      final out = _positions(await blobOf(gpkg, 'polys', id));
      final cols = (await (await gpkg.getDatabase()).rawQuery("SELECT z, m FROM gpkg_geometry_columns WHERE table_name = 'polys'")).single;
      await gpkg.dispose();

      expect([for (final q in out) q.optZ], [10.0, 20.0, _dem, _dem, 10.0]);
      expect(out.first.x.abs(), lessThan(1e5), reason: '平面直角座標（m）で書いている');
      expect(cols['z'], 1);
    });

    test('M 付き（m=1）: 動かしていない頂点の M は元のまま、足した頂点は 0', () async {
      final line = geo.MultiLineString.from([
        [
          const geo.Geographic(lon: 135.90, lat: 33.90, elev: 1, m: 5),
          const geo.Geographic(lon: 135.91, lat: 33.91, elev: 2, m: 6),
        ],
      ]);
      final (gpkg, id) = await zLayer('zm', GeometryType.linestring, line, m: 1);
      final f = await gpkg.getFeature('zm', id);
      final pts = List<LatLng>.of((f![featureGeometryKey] as List).first as List<LatLng>)..add(const LatLng(33.92, 135.92));
      await gpkg.updateLine('zm', id, pts);
      final blob = await blobOf(gpkg, 'zm', id);
      await gpkg.dispose();
      final out = _positions(blob);
      expect(_wkbType(blob), 3005, reason: 'ISO WKB の MultiLineString ZM');
      expect([for (final q in out) q.optZ], [1, 2, _dem]);
      expect([for (final q in out) q.optM], [5, 6, 0]);
    });

    test('標高が引けないときは Z を 0 にする', () async {
      VertexZ.elevationLookup = (pts) async => [for (final _ in pts) null];
      final (gpkg, id) = await zLayer('pts', GeometryType.point, const geo.Point(geo.Geographic(lon: 135.9, lat: 33.9, elev: 42.0)));
      await gpkg.updatePoint('pts', id, const LatLng(33.95, 135.95));
      expect(_positions(await blobOf(gpkg, 'pts', id)).single.optZ, 0);
      await gpkg.dispose();
    });

    test('2D のレイヤは 2D のまま（標高も引かない）', () async {
      final (gpkg, id) = await zLayer('flat', GeometryType.linestring,
          geo.MultiLineString.from([
            [const geo.Geographic(lon: 135.9, lat: 33.9), const geo.Geographic(lon: 135.91, lat: 33.91)],
          ]),
          z: 0);
      await gpkg.updateLine('flat', id, const [LatLng(33.9, 135.9), LatLng(33.92, 135.92)]);
      final added = await gpkg.addLine('flat', const [LatLng(33.8, 135.8), LatLng(33.81, 135.81)]);
      final blobs = [await blobOf(gpkg, 'flat', id), await blobOf(gpkg, 'flat', added!)];
      await gpkg.dispose();
      for (final b in blobs) {
        expect(_wkbType(b), 5);
        expect(_positions(b).every((q) => !q.is3D && !q.isMeasured), isTrue);
      }
      expect(_asked, isEmpty);
    });
  });

  group('標高タイルから引く（DemPointSampler）', () {
    /// 地理院 PNG の 1 色のタイル（h m。null は無効値 128,0,0）
    Uint8List gsiTile(double? h) {
      final im = img.Image(width: 256, height: 256);
      final (r, g, b) = h == null
          ? (128, 0, 0)
          : (() {
              final x = (h * 100).round();
              return ((x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff);
            })();
      img.fill(im, color: img.ColorRgb8(r, g, b));
      return Uint8List.fromList(img.encodePng(im));
    }

    test('細かいソースが無効値なら次のソース、どれも無ければ null', () async {
      final asked = <String>[];
      final sampler = DemPointSampler(fetch: (s, z, x, y) async {
        asked.add('${s.id}/$z');
        if (s.id == DemTileSource.gsiDem1a.id) return gsiTile(null); // 整備範囲外
        if (s.id == DemTileSource.gsiDem5a.id) return gsiTile(512.34);
        return null;
      });
      final h = await sampler.sample([(135.9, 33.9), (135.90001, 33.90001)]);
      expect(h[0], closeTo(512.34, 1e-3));
      expect(h[1], closeTo(512.34, 1e-3));
      expect(asked, ['gsi_dem1a_png/17', 'gsi_dem5a_png/15'], reason: '同じタイルは 1 回だけ取る');

      final none = DemPointSampler(fetch: (s, z, x, y) async => null);
      expect(await none.sample([(135.9, 33.9)]), [null]);
    });
  });

  group('GDAL で作った Z 付き gpkg（QGIS と同じ読み書き）', () {
    Future<String> makeZGpkg(String name, Map<String, Object?> geometry, {List<String> extra = const []}) async {
      final src = p.join(tmp.path, '$name.geojson');
      File(src).writeAsStringSync(jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {'type': 'Feature', 'properties': {'name': name}, 'geometry': geometry},
        ],
      }));
      final dst = p.join(tmp.path, '$name.gpkg');
      await gdal!.vectorTranslate(src, dst, args: ['-f', 'GPKG', '-nln', name,
        // GeoJSON の Z 付きは EPSG:4979（3 次元）になる。アプリが epsg.io に聞きに行かないよう 4326 に
        ...extra.contains('-t_srs') ? ['-s_srs', 'EPSG:4326'] : ['-a_srs', 'EPSG:4326'], ...extra]);
      return dst;
    }

    List<Object?> coordsOf(Map<String, dynamic> info) {
      final c = dig(firstLayer(info), ['features', 0, 'geometry', 'coordinates']);
      final flat = <Object?>[];
      void walk(Object? v) {
        if (v is List && v.isNotEmpty && v.first is num) {
          flat.add(v);
        } else if (v is List) {
          v.forEach(walk);
        }
      }

      walk(c);
      return flat;
    }

    test('線（EPSG:6674・Multi に）: 1 頂点を動かし 1 頂点を足す → GDAL で Z 付きに読める', () async {
      final path = await makeZGpkg('road', {
        'type': 'LineString',
        'coordinates': [
          [135.90, 33.90, 100.5],
          [135.91, 33.91, 200.25],
          [135.92, 33.92, 300.125],
        ],
      }, extra: ['-nlt', 'PROMOTE_TO_MULTI', '-t_srs', 'EPSG:6674']);
      final before = await gdal!.vectorInfo(path, args: ['-so']);
      expect(dig(firstLayer(before), ['geometryFields', 0, 'type']), 'MultiLineStringZ');

      final gpkg = GeoPackageFile(const ['road.gpkg'], absolutePath: path);
      final f = await gpkg.getFeature('road', 1);
      final pts = List<LatLng>.of((f![featureGeometryKey] as List).first as List<LatLng>);
      expect(pts, hasLength(3));
      pts[1] = const LatLng(33.915, 135.912);
      pts.insert(2, const LatLng(33.918, 135.918));
      expect(await gpkg.updateLine('road', 1, pts, name: 'road'), isTrue);
      final cols = (await (await gpkg.getDatabase()).rawQuery("SELECT z FROM gpkg_geometry_columns WHERE table_name = 'road'")).single;
      await gpkg.flushChanges();
      await gpkg.dispose();
      expect(cols['z'], 1);

      final info = await gdal!.vectorInfo(path, args: ['-features']);
      expect(dig(firstLayer(info), ['geometryFields', 0, 'type']), 'MultiLineStringZ');
      final coords = coordsOf(info);
      expect(coords, hasLength(4));
      expect([for (final c in coords) (c! as List)[2]], [100.5, _dem, _dem, 300.125]);
      expect(((coords.first! as List)[0] as num).abs(), lessThan(1e5), reason: '平面直角座標（m）のまま');
    }, skip: skipGdal);

    test('点・面（EPSG:4326）: 元の Z を保ち、新しい地物は標高', () async {
      final ptPath = await makeZGpkg('tree', {
        'type': 'Point',
        'coordinates': [135.9, 33.9, 55.5],
      });
      final polyPath = await makeZGpkg('stand', {
        'type': 'Polygon',
        'coordinates': [
          [
            [135.95, 33.90, 10.0],
            [135.97, 33.90, 20.0],
            [135.97, 33.92, 30.0],
            [135.95, 33.90, 10.0],
          ],
        ],
      }, extra: ['-nlt', 'PROMOTE_TO_MULTI']);

      final pt = GeoPackageFile(const ['tree.gpkg'], absolutePath: ptPath);
      await pt.updatePoint('tree', 1, const LatLng(33.9, 135.9), name: 'renamed');
      await pt.addPoint('tree', const LatLng(33.91, 135.91), name: 'new');
      await pt.flushChanges();
      await pt.dispose();

      final poly = GeoPackageFile(const ['stand.gpkg'], absolutePath: polyPath);
      final f = await poly.getFeature('stand', 1);
      final outer = List<LatLng>.of(((f![featureGeometryKey] as List).first as List).first as List<LatLng>);
      outer.insert(1, const LatLng(33.899, 135.96));
      await poly.updatePolygon('stand', 1, [outer]);
      await poly.flushChanges();
      await poly.dispose();

      final ptInfo = await gdal!.vectorInfo(ptPath, args: ['-features']);
      expect(dig(firstLayer(ptInfo), ['geometryFields', 0, 'type']), 'PointZ');
      expect(dig(firstLayer(ptInfo), ['features', 0, 'geometry', 'coordinates', 2]), 55.5);
      expect(dig(firstLayer(ptInfo), ['features', 1, 'geometry', 'coordinates', 2]), _dem);

      final polyInfo = await gdal!.vectorInfo(polyPath, args: ['-features']);
      expect(dig(firstLayer(polyInfo), ['geometryFields', 0, 'type']), 'MultiPolygonZ');
      expect([for (final c in coordsOf(polyInfo)) (c! as List)[2]], [10.0, _dem, 20.0, 30.0, 10.0]);
    }, skip: skipGdal);
  });
}
