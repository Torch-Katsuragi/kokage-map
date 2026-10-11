// レイヤの書き出し（ImportExportService.exportLayer = gpkg → GDAL の ogr2ogr）のホスト VM テスト。
//
// 使う GDAL は test/support/gdal_host.dart（Windows は QGIS 同梱の gdal*.dll）。見つからなければ全部 skip。
// 書いたファイルは GDAL で読み直して確かめる（QGIS が読むのと同じ部品）。
// ⚠ GDAL を先に読み込む（version()）。sqflite_common_ffi の sqlite3.dll が先だと QGIS の DLL 群と食い違いうる
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/coordinate/epsg_registry.dart';
import 'package:root_maps/services/external/external_source.dart';
import 'package:root_maps/services/import_export/import_export_service.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/colliding_columns_gpkg.dart';
import 'support/foreign_geom_gpkg.dart';
import 'support/gdal_host.dart';
import 'support/gdal_scenarios.dart';

void main() {
  late Directory tmp;
  late String proj;
  final gdalConfig = findHostGdal();
  final skip = gdalConfig == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null;

  setUpAll(() async {
    if (gdalConfig == null) return;
    final gdal = GdalFfi(gdalConfig);
    await gdal.version();
    ExternalGdal.instance = gdal;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('layer_export_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 点・線・面と属性（日本語・カンマと引用符・null・数値）を持つ gpkg
  Future<void> makeSourceGpkg(String path) async {
    final g = GeoPackageFile([p.basename(path)], absolutePath: path);
    const attrs = {'name': 'TEXT', 'description': 'TEXT', 'h': 'REAL', 'n': 'INTEGER', '樹種': 'TEXT'};
    await g.addLayer('pts', GeometryType.point);
    await g.addAttributeColumns('pts', attrs);
    await g.addPointsBatch('pts', [
      (const LatLng(33.91, 135.97), {'name': '杉', 'description': '樹高 "高い", 太い', 'h': 21.5, 'n': 3, '樹種': 'スギ'}),
      (const LatLng(33.92, 135.98), {'name': 'hinoki', 'h': null, 'n': 7, '樹種': 'ヒノキ'}),
      (const LatLng(33.93, 135.99), {'name': null, 'description': 'line\nbreak', 'h': 0.125}),
    ]);
    await g.addLayer('lns', GeometryType.linestring);
    await g.addAttributeColumns('lns', attrs);
    await g.addLinesBatch('lns', [
      (const [LatLng(33.90, 135.90), LatLng(33.91, 135.91), LatLng(33.905, 135.93)], {
        'name': '林道 A',
        'h': 3.0,
      }),
    ]);
    await g.addLayer('pls', GeometryType.polygon);
    await g.addAttributeColumns('pls', attrs);
    await g.addPolygonsBatch('pls', [
      (const [
          [LatLng(33.0, 135.0), LatLng(33.0, 135.1), LatLng(33.1, 135.1), LatLng(33.1, 135.0)],
        ], {
        'name': '小班 1-い',
        'n': 10,
      }),
    ]);
    await g.flushChanges();
    await g.dispose();
  }

  /// [proj] 直下の gpkg のレイヤ（レイヤ名 → ノード）
  Future<Map<String, LayerNode>> openLayers() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    final gpkg = root.children.whereType<GeoPackageNode>().single;
    await gpkg.updateChildren();
    addTearDown(gpkg.geoPackageFile.dispose);
    return {for (final l in gpkg.children.whereType<LayerNode>()) l.layerName: l};
  }

  Future<Map<String, LayerNode>> sourceLayers() async {
    await makeSourceGpkg(p.join(proj, 'src.gpkg'));
    return openLayers();
  }

  Future<String> export(LayerNode layer, FileFormat format, {ExportOptions options = const ExportOptions()}) async {
    final dir = await Directory(p.join(tmp.path, 'out_${format.name}_${layer.layerName}')).create();
    final out = p.join(dir.path, '${layer.layerName}${format.extension}');
    final result = await ImportExportService().exportLayer(layer, out, format: format, options: options);
    expect(result.success, isTrue, reason: result.errorMessage);
    return out;
  }

  Future<Map<String, dynamic>> features(String path) => ExternalGdal.instance.vectorInfo(path, args: const ['-features']);

  test('Shapefile: UTF-8 と .cpg、日本語の値と列名、座標系はレイヤのまま（4326）', () async {
    final layers = await sourceLayers();
    final out = await export(layers['pts']!, FileFormat.shapefile);
    final base = p.withoutExtension(out);
    for (final ext in ['.shp', '.shx', '.dbf', '.prj', '.cpg']) {
      expect(File('$base$ext').existsSync(), isTrue, reason: ext);
    }
    expect(File('$base.cpg').readAsStringSync().trim().toUpperCase(), 'UTF-8');
    final info = await features(out);
    expect(featureValues(info, 'name'), ['杉', 'hinoki', null]);
    expect(featureValues(info, '樹種'), ['スギ', 'ヒノキ', null]);
    expect(featureValues(info, 'n'), [3, 7, null]);
    expect(layerEpsg(info), 4326);
  }, skip: skip);

  test('GeoJSON: 属性を全部書き、RFC 7946（4326・crs なし）', () async {
    final layers = await sourceLayers();
    final out = await export(layers['pts']!, FileFormat.geojson);
    final json = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(json.containsKey('crs'), isFalse);
    final first = (json['features'] as List).first as Map<String, dynamic>;
    expect(first['properties'], containsPair('name', '杉'));
    expect(first['properties'], containsPair('description', '樹高 "高い", 太い'));
    expect(first['properties'], containsPair('h', 21.5));
    expect(first['properties'], containsPair('n', 3));
    expect(first['properties'], containsPair('樹種', 'スギ'));
    expect((first['geometry'] as Map)['type'], 'Point', reason: 'アプリの点レイヤ（MULTIPOINT 宣言）でも Point で書く');
    final coords = (first['geometry'] as Map)['coordinates'] as List;
    expect(coords[0] as num, closeTo(135.97, 1e-9));
    expect(coords[1] as num, closeTo(33.91, 1e-9));
  }, skip: skip);

  test('KML: 名前・説明と、ほかの属性も ExtendedData に書く', () async {
    final layers = await sourceLayers();
    final out = await export(layers['pts']!, FileFormat.kml);
    final info = await features(out);
    expect(firstLayer(info)['featureCount'], 3);
    expect(featureValues(info, 'Name'), ['杉', 'hinoki', null]);
    final text = File(out).readAsStringSync();
    expect(text, contains('<SimpleData name="樹種">スギ</SimpleData>'));
    expect(text, contains('<SimpleData name="h">21.5</SimpleData>'));
  }, skip: skip);

  test('CSV: 点は X・Y 列、線は WKT 列。属性は全部', () async {
    final layers = await sourceLayers();
    final pts = File(await export(layers['pts']!, FileFormat.csv)).readAsLinesSync();
    expect(pts.first.split(',').take(2), ['X', 'Y']);
    expect(pts.first, contains('樹種'));
    expect(pts[1], startsWith('135.97,33.91,'));
    expect(pts[1], contains('杉'));

    final lns = File(await export(layers['lns']!, FileFormat.csv)).readAsLinesSync();
    // WKT の列名は形の列の名前（GDAL・QGIS と同じ）
    expect(lns.first, startsWith('geom,'));
    expect(lns[1], contains('LINESTRING'));
  }, skip: skip);

  test('行番号: ROW_NUM を主キーの順に 1 から', () async {
    final layers = await sourceLayers();
    final out = await export(layers['pts']!, FileFormat.shapefile, options: const ExportOptions(includeRowNumber: true));
    final info = await features(out);
    expect(featureValues(info, 'ROW_NUM'), [1, 2, 3]);
    expect(featureValues(info, 'name'), ['杉', 'hinoki', null]);
    expect(firstLayer(info)['geometryFields'], isNotEmpty);
  }, skip: skip);

  test('GNSS の品質: 測量の記録を列に広げる（線は頂点で最も悪い値、記録なし・壊れた JSON は空）', () async {
    final path = p.join(proj, 'q.gpkg');
    final g = GeoPackageFile([p.basename(path)], absolutePath: path);
    String meta(List<Map<String, dynamic>?> qualities) => jsonEncode({
          'drawing_points': [
            for (final q in qualities) q == null ? {'data_source': 'pen_tool'} : {'quality': q},
          ],
        });
    await g.addLayer('pts', GeometryType.point);
    await g.addAttributeColumns('pts', {'name': 'TEXT', 'kmaps_metadata': 'TEXT'});
    await g.addPointsBatch('pts', [
      (const LatLng(33.91, 135.97), {
        'name': 'rtk',
        'kmaps_metadata': meta([
          {'source': 'GNSS', 'fix': 'rtk_fixed', 'sats': 12, 'hacc': 0.02, 'avg_n': 10},
        ]),
      }),
      (const LatLng(33.92, 135.98), {'name': 'none'}),
      (const LatLng(33.93, 135.99), {'name': 'broken', 'kmaps_metadata': '{not json'}),
    ]);
    await g.addLayer('lns', GeometryType.linestring);
    await g.addAttributeColumns('lns', {'name': 'TEXT', 'kmaps_metadata': 'TEXT'});
    await g.addLinesBatch('lns', [
      (const [LatLng(33.90, 135.90), LatLng(33.91, 135.91), LatLng(33.92, 135.92)], {
        'name': 'mixed',
        'kmaps_metadata': meta([
          {'source': 'GNSS', 'fix': 'rtk_fixed', 'sats': 12, 'hacc': 0.02, 'avg_n': 10},
          {'source': 'GNSS', 'fix': 'rtk_float', 'sats': 9, 'hacc': 0.08, 'avg_n': 5},
          null,
        ]),
      }),
    ]);
    await g.flushChanges();
    await g.dispose();
    final layers = await openLayers();
    const options = ExportOptions(includeGnssQuality: true, includeRowNumber: true);

    final pts = await features(await export(layers['pts']!, FileFormat.shapefile, options: options));
    expect(featureValues(pts, 'name'), ['rtk', 'none', 'broken']);
    expect(featureValues(pts, 'gnss_fix'), ['RTK FIX', null, null]);
    expect(featureValues(pts, 'gnss_sats'), [12, null, null]);
    expect(featureValues(pts, 'gnss_hacc'), [0.02, null, null]);
    expect(featureValues(pts, 'gnss_avg_n'), [10, null, null]);
    expect(featureValues(pts, 'ROW_NUM'), [1, 2, 3]);

    final lns = await features(await export(layers['lns']!, FileFormat.geojson, options: options));
    expect(featureValues(lns, 'gnss_fix'), ['RTK FLOAT']);
    expect(featureValues(lns, 'gnss_sats'), [9]);
    expect(featureValues(lns, 'gnss_hacc'), [0.08]);
    expect(featureValues(lns, 'gnss_avg_n'), [5]);
  }, skip: skip);

  test('平面直角（EPSG:6674）の gpkg → shp は 6674 のまま（.prj）、GeoJSON は 4326', () async {
    // 36N, 136.01E の点 1 つ（x = 901.5 m 東, y = 0.05 m 北）。gpkg_axis_order_test と同じもの
    File('test/fixtures/qgis_6674_point.gpkg').copySync(p.join(proj, 'q.gpkg'));
    final layer = (await openLayers()).values.single;

    final shp = await export(layer, FileFormat.shapefile);
    expect(File(p.setExtension(shp, '.prj')).existsSync(), isTrue);
    final info = await features(shp);
    expect(layerEpsg(info), 6674);
    final xy = dig(firstLayer(info), ['features', 0, 'geometry', 'coordinates'])! as List;
    expect(xy[0] as num, closeTo(901.5, 0.1));
    expect(xy[1] as num, closeTo(0.05, 0.1));

    final geojson = jsonDecode(File(await export(layer, FileFormat.geojson)).readAsStringSync()) as Map<String, dynamic>;
    final coords = dig(geojson, ['features', 0, 'geometry', 'coordinates'])! as List;
    expect(coords[0] as num, closeTo(136.01, 1e-7));
    expect(coords[1] as num, closeTo(36.0, 1e-7));
  }, skip: skip);

  test('座標系を選べば変換する（4326 → 6674）', () async {
    final layers = await sourceLayers();
    final out = await export(
      layers['pts']!,
      FileFormat.geopackage,
      options: ExportOptions(targetCrs: EpsgRegistry.instance.getByCode('EPSG:6674')),
    );
    final info = await features(out);
    expect(layerEpsg(info), 6674);
    final xy = dig(firstLayer(info), ['features', 0, 'geometry', 'coordinates'])! as List;
    expect(xy[1] as num, closeTo(-232000, 5000)); // Northing（33.91N は原点 36N の南）
    expect(featureValues(info, '樹種'), ['スギ', 'ヒノキ', null]);
  }, skip: skip);

  test('GPX（点・線）・FlatGeobuf・DXF・GeoPackage も書ける', () async {
    final layers = await sourceLayers();
    for (final (layer, format) in [
      ('pts', FileFormat.gpx),
      ('lns', FileFormat.gpx),
      ('pls', FileFormat.flatgeobuf),
      ('pls', FileFormat.dxf),
      ('pls', FileFormat.geopackage),
    ]) {
      final out = await export(layers[layer]!, format);
      final info = await ExternalGdal.instance.vectorInfo(out, args: const ['-so']);
      final counts = [for (final l in info['layers'] as List) (l as Map)['featureCount']];
      expect(counts.whereType<int>().fold<int>(0, (a, b) => a + b), greaterThan(0), reason: '$layer → ${format.value}');
    }
  }, skip: skip);

  test('保存待ちの編集も書き出しに入る', () async {
    final layers = await sourceLayers();
    final layer = layers['pts']!;
    final pk = await layer.geoPackageFile.getPrimaryKeyColumn('pts');
    final db = await layer.geoPackageFile.getDatabase();
    final id = (await db.rawQuery('SELECT "$pk" AS id FROM pts ORDER BY "$pk" LIMIT 1')).single['id']! as int;
    layer.geoPackageFile.queueAttributeUpdates('pts', id, {'name': '直した杉'});
    final info = await features(await export(layer, FileFormat.geojson));
    expect(featureValues(info, 'name').first, '直した杉');
  }, skip: skip);

  // 形の列が geom 以外（GeoPandas の geometry・ArcGIS Pro の Shape）の gpkg も書き出せる。
  // 行番号つき（-sql の SELECT *）でも形が形として出て、形の列が属性に混ざらない
  for (final kind in ForeignGeomGpkg.all) {
    test('形の列が ${kind.geomColumn} の gpkg を GeoJSON に（行番号つき・なし）', () async {
      await kind.write(p.join(proj, 'foreign.gpkg'));
      final layer = (await openLayers())[kind.table]!;
      expect(await layer.geoPackageFile.getFeaturesWithGeometry(kind.table), hasLength(2));
      for (final options in const [ExportOptions(), ExportOptions(includeRowNumber: true)]) {
        final out = await export(layer, FileFormat.geojson, options: options);
        final json = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
        final fs = [for (final f in json['features'] as List) f as Map<String, dynamic>];
        expect(fs, hasLength(2));
        expect((fs.first['geometry'] as Map)['coordinates'], [closeTo(135.96, 1e-6), closeTo(33.93, 1e-6)]);
        final props = fs.first['properties'] as Map<String, dynamic>;
        expect(props['name'], 'a');
        expect(props.keys, isNot(contains(kind.geomColumn)));
        if (kind.extraColumns.containsKey('geom')) expect(props['geom'], 'geom-a');
        if (options.includeRowNumber) expect(props['ROW_NUM'], 1);
        await File(out).delete();
      }
    }, skip: skip);
  }

  // 主キーが fid の表・主キーの無い表の id というふつうの列は、直した値のまま書き出す
  // （以前は地物番号が id に入っていて、id の列を直しても書かれなかった）
  for (final kind in CollidingColumnsGpkg.values) {
    test('${kind.label}: id の列を直して GeoJSON に', () async {
      await kind.write(p.join(proj, 'colliding.gpkg'));
      final layer = (await openLayers())[CollidingColumnsGpkg.table]!;
      await layer.updateChildren();
      final f = layer.features.firstWhere((f) => f.rowId == CollidingColumnsGpkg.featureIds.first);
      await f.setAttributeValue('id', 555);
      f.name = 'x';
      final info = await features(await export(layer, FileFormat.geojson));
      expect(featureValues(info, 'id'), [555, CollidingColumnsGpkg.idValues.last]);
      expect(featureValues(info, 'name'), ['x', 'b']);
    }, skip: skip);
  }

  // 形の列が geom の表の geometry というふつうの列は、直した値のまま属性として書き出す
  test('geometry という列を直して GeoJSON に', () async {
    await writeGeometryAttributeGpkg(p.join(proj, 'colliding.gpkg'));
    final layer = (await openLayers())[CollidingColumnsGpkg.table]!;
    await layer.updateChildren();
    await layer.features.firstWhere((f) => f.rowId == 1).setAttributeValue('geometry', 'g-x');
    final out = await export(layer, FileFormat.geojson);
    final json = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    final fs = [for (final f in json['features'] as List) f as Map<String, dynamic>];
    expect([for (final f in fs) (f['properties'] as Map)['geometry']], ['g-x', 'g-b']);
    expect((fs.first['geometry'] as Map)['coordinates'], [closeTo(135.96, 1e-6), closeTo(33.93, 1e-6)]);
  }, skip: skip);
}
