// gpkg 以外の形式を読み取り専用レイヤとして開く（GDAL で読む・キャッシュ・ノード・変換）
// 設計は docs/technical/external-formats.md
//
// GDAL（QGIS の gdal*.dll / apt の libgdal）が無ければ skip。
// ⚠ GDAL を sqflite より先に読み込む（QGIS の DLL は sqlite3.dll を名前で読む。test/gdal_test.dart の注意）
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/external_layer_node.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/providers/selection_providers.dart';
import 'package:root_maps/services/coordinate/gpkg_crs_resolver.dart';
import 'package:root_maps/services/external/external_layer_cache.dart';
import 'package:root_maps/services/external/external_layer_converter.dart';
import 'package:root_maps/services/external/external_source.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/gdal_host.dart';
import 'support/gdal_scenarios.dart';
import 'support/shp_fixture.dart';

const _fx = 'test/fixtures/gdal';

const _surveyKml = '''<?xml version="1.0" encoding="utf-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
<Folder><name>立木</name>
  <Placemark><name>スギ1</name><Point><coordinates>135.96,33.93</coordinates></Point></Placemark>
  <Placemark><name>ヒノキ2</name><Point><coordinates>135.961,33.931</coordinates></Point></Placemark>
</Folder>
<Folder><name>作業道</name>
  <Placemark><name>道1</name><LineString><coordinates>135.96,33.93 135.97,33.94</coordinates></LineString></Placemark>
</Folder>
</Document></kml>''';

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
    tmp = await Directory.systemTemp.createTemp('ext_layer_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 点 3 つ（属性 NAME, H）の shp 一式
  Future<void> writePoints(String base, {String? prj}) => writePointShp(ExternalGdal.instance, base, [
    (135.97, 33.91, {'NAME': 'sugi', 'H': 21.5}),
    (135.98, 33.92, {'NAME': 'hinoki', 'H': 18.0}),
    (135.99, 33.93, {'NAME': 'matsu', 'H': 9.5}),
  ], epsg: prj);

  Map<String, Object?> feature(Map<String, Object?> geometry, Map<String, Object?> props) => {'type': 'Feature', 'properties': props, 'geometry': geometry};

  void writeGeoJson(String path, List<Map<String, Object?>> features) => File(path).writeAsStringSync(jsonEncode({'type': 'FeatureCollection', 'features': features}));

  /// [proj] 直下を開き、外部形式のノードのキャッシュを作る
  Future<FolderNode> openRoot() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    for (final child in root.children.whereType<GeoPackageNode>()) {
      await child.updateChildren();
    }
    return root;
  }

  /// test/fixtures/gdal の [stem].* を [proj] へ写す
  void copyFixture(String stem, {String? as}) {
    for (final f in Directory(_fx).listSync().whereType<File>()) {
      final name = p.basename(f.path);
      if (p.basenameWithoutExtension(name) != stem) continue;
      f.copySync(p.join(proj, '${as ?? stem}${p.extension(name)}'));
    }
  }

  /// キャッシュの [layer] の [column] 列（fid 順）
  Future<List<Object?>> namesIn(GeoPackageFile gpkg, String layer, {String column = 'name'}) async {
    final db = await gpkg.getDatabase();
    return [for (final r in await db.rawQuery('SELECT "$column" FROM "$layer" ORDER BY fid')) r[column]];
  }

  Future<String> epsgOf(GeoPackageFile gpkg, String layer) async =>
      (await GpkgCrsResolver.instance.resolveLayerCrs(await gpkg.getDatabase(), layer)).epsgCode;

  group('GDAL で読む', () {
    test('候補の拡張子: .gpkg・付属ファイル・隠しフォルダは外す', () {
      expect(ExternalSource.isCandidate(p.join(proj, '林班.SHP')), isTrue);
      for (final ext in ['.geojson', '.json', '.kml', '.kmz', '.csv', '.gpx', '.fgb', '.gml', '.dxf', '.tab', '.mif']) {
        expect(ExternalSource.isCandidate(p.join(proj, 'a$ext')), isTrue, reason: ext);
      }
      expect(ExternalSource.isCandidate(p.join(proj, 'a.gpkg')), isFalse);
      expect(ExternalSource.isCandidate(p.join(proj, 'a.dbf')), isFalse, reason: '付属ファイルは単独でレイヤにしない');
      expect(ExternalSource.isCandidate(p.join(proj, '.kokage', 'cache', 'a.geojson')), isFalse);
      expect(ExternalSource.isCandidate(p.join(proj, '.a.geojson')), isFalse);
    });

    test('shp（Shift_JIS、.cpg も LDID も無い）: CP932 で読み、CRS（EPSG:6674）は元のまま', () async {
      copyFixture('sjis_nocpg', as: '林班');
      expect(await ExternalSource.needsFallbackEncoding(p.join(proj, '林班.shp')), isTrue);
      final root = await openRoot();
      final node = root.children.whereType<ExternalLayerNode>().single;
      expect(node.loadError, isNull);
      expect(node.children.whereType<LayerNode>().single.layerName, '林班');
      expect(await namesIn(node.geoPackageFile, '林班'), gdalScenarioNames);
      expect(await epsgOf(node.geoPackageFile, '林班'), 'EPSG:6674');
      expect(await node.geoPackageFile.getGeometryType('林班'), GeometryType.point);
      expect((await node.sourceFiles()).map(p.basename), unorderedEquals(['林班.shp', '林班.shx', '林班.dbf', '林班.prj']));
    }, skip: skip);

    test('shp（.cpg あり）: .cpg の文字コードで読む', () async {
      copyFixture('sjis_cpg');
      expect(await ExternalSource.needsFallbackEncoding(p.join(proj, 'sjis_cpg.shp')), isFalse);
      final node = (await openRoot()).children.whereType<ExternalLayerNode>().single;
      expect(await namesIn(node.geoPackageFile, 'sjis_cpg'), gdalScenarioNames);
      expect(await epsgOf(node.geoPackageFile, 'sjis_cpg'), 'EPSG:6674');
    }, skip: skip);

    test('GeoJSON: 型が混ざれば <名前>_point / _line / _polygon に分ける（Multi も同じ型）', () async {
      writeGeoJson(p.join(proj, 'mixed.geojson'), [
        feature({'type': 'Point', 'coordinates': [135.0, 33.0]}, {'n': 'a'}),
        feature({
          'type': 'MultiPoint',
          'coordinates': [
            [135.0, 33.0],
            [135.1, 33.1],
          ],
        }, {'n': 'b'}),
        feature({
          'type': 'LineString',
          'coordinates': [
            [135.0, 33.0],
            [135.1, 33.1],
          ],
        }, {'n': 'c'}),
        feature({
          'type': 'MultiPolygon',
          'coordinates': [
            [
              [
                [135.0, 33.0],
                [135.1, 33.0],
                [135.1, 33.1],
                [135.0, 33.0],
              ],
            ],
            [
              [
                [136.0, 33.0],
                [136.1, 33.0],
                [136.1, 33.1],
                [136.0, 33.0],
              ],
            ],
          ],
        }, {'n': 'd'}),
      ]);
      final node = (await openRoot()).children.whereType<ExternalLayerNode>().single;
      final layers = node.children.whereType<LayerNode>().map((l) => l.layerName).toList();
      expect(layers, unorderedEquals(['mixed_point', 'mixed_line', 'mixed_polygon']));
      expect(await namesIn(node.geoPackageFile, 'mixed_point', column: 'n'), ['a', 'b']);
      expect(await node.geoPackageFile.getGeometryType('mixed_polygon'), GeometryType.polygon);
      final plan = node.sourcePlan!;
      expect(plan.sourceLayerCount, 1);
      expect(plan.layers.every((l) => l.split && l.sourceLayer == 'mixed'), isTrue);
    }, skip: skip);

    test('GeoJSON: .json は GDAL が形を見つけたときだけ', () async {
      File(p.join(proj, 'settings.json')).writeAsStringSync('{"a":1}');
      File(p.join(proj, 'broken.json')).writeAsStringSync('{');
      writeGeoJson(p.join(proj, 'pts.json'), [
        feature({'type': 'Point', 'coordinates': [135.0, 33.0]}, {}),
      ]);
      final names = (await openRoot()).children.whereType<ExternalLayerNode>().map((n) => n.name);
      expect(names, ['pts.json']);
    }, skip: skip);

    test('KML: フォルダごとのレイヤ（名前は GDAL のレイヤ名）', () async {
      File(p.join(proj, 'survey.kml')).writeAsStringSync(_surveyKml);
      final node = (await openRoot()).children.whereType<ExternalLayerNode>().single;
      expect(node.loadError, isNull);
      expect(node.children.whereType<LayerNode>().map((l) => l.layerName), unorderedEquals(['立木', '作業道']));
      expect(await namesIn(node.geoPackageFile, '立木', column: 'Name'), ['スギ1', 'ヒノキ2']);
      expect(await node.geoPackageFile.getGeometryType('作業道'), GeometryType.linestring);
      expect(node.sourcePlan!.sourceLayerCount, 2);
    }, skip: skip);

    test('CSV: 経度・緯度の列があれば点のレイヤ、無ければレイヤにしない', () async {
      File(p.join(proj, 'trees.csv')).writeAsStringSync('name,経度,緯度,dbh\nスギ1,135.96,33.93,32\nヒノキ2,135.961,33.931,28\n');
      File(p.join(proj, 'lonlat.csv')).writeAsStringSync('name,lon,lat\na,135.0,33.0\n');
      File(p.join(proj, 'plain.csv')).writeAsStringSync('name,dbh\nスギ1,32\n');
      final root = await openRoot();
      final nodes = root.children.whereType<ExternalLayerNode>().toList();
      expect(nodes.map((n) => n.name), ['lonlat.csv', 'trees.csv']);
      final trees = nodes[1];
      expect(await namesIn(trees.geoPackageFile, 'trees'), ['スギ1', 'ヒノキ2']);
      final columns = await trees.geoPackageFile.getColumnNames('trees', getAll: true, skipPrimaryKey: true);
      expect(columns, isNot(contains('経度')), reason: 'KEEP_GEOM_COLUMNS=NO');
      final db = await trees.geoPackageFile.getDatabase();
      expect((await db.rawQuery('SELECT dbh FROM trees ORDER BY fid')).first['dbh'], 32, reason: 'AUTODETECT_TYPE=YES');
    }, skip: skip);
  });

  group('ノードとキャッシュ', () {

    test('shp・GeoJSON はノードになり、付属ファイルや GeoJSON でない .json はならない', () async {
      await writePoints(p.join(proj, '林班'));
      writeGeoJson(p.join(proj, 'roads.geojson'), [
        feature(
          {
            'type': 'LineString',
            'coordinates': [
              [135.0, 33.0],
              [135.1, 33.1],
            ],
          },
          {'name': 'r'},
        ),
      ]);
      File(p.join(proj, 'settings.json')).writeAsStringSync('{"a":1}');

      final root = await openRoot();
      final nodes = root.children.whereType<ExternalLayerNode>().toList();
      expect(nodes.map((n) => n.name), ['roads.geojson', '林班.shp']);
      final shp = nodes[1];
      expect(shp.getAbsoluteFilePath(), p.join(proj, '林班.shp'));
      expect(shp.isReadOnly, isTrue);
      expect(p.isWithin(p.join(proj, '.kokage', 'cache', 'external'), shp.geoPackageFile.getAbsolutePath()!), isTrue);
      final layer = shp.children.whereType<LayerNode>().single;
      expect(layer.layerName, '林班');
      expect(layer.layerKey, '林班.shp/林班');
      expect(isInReadOnlyLayer(layer), isTrue);
      expect(await shp.geoPackageFile.countFilteredFeatures('林班', '1=1'), 3);
      // .kokage はツリーに出ない
      expect(root.children.whereType<FolderNode>(), isEmpty);
    }, skip: skip);

    test('元が変わらなければ作り直さず、変わったら作り直す', () async {
      final path = p.join(proj, 'pts.geojson');
      writeGeoJson(path, [
        feature(
          {
            'type': 'Point',
            'coordinates': [135.0, 33.0],
          },
          {'n': 1},
        ),
      ]);
      final root = await openRoot();
      final node = root.children.whereType<ExternalLayerNode>().single;
      final cache = node.geoPackageFile;
      expect(await ExternalLayerCache.ensure(cache, path), isFalse, reason: '同じ印なら作り直さない');

      writeGeoJson(path, [
        feature(
          {
            'type': 'Point',
            'coordinates': [135.0, 33.0],
          },
          {'n': 1},
        ),
        feature(
          {
            'type': 'Point',
            'coordinates': [135.1, 33.1],
          },
          {'n': 2},
        ),
      ]);
      File(path).setLastModifiedSync(DateTime(2030));
      await node.updateChildren();
      expect(await cache.countFilteredFeatures('pts', '1=1'), 2);
      expect(await ExternalLayerCache.ensure(cache, path), isFalse);
    }, skip: skip);

    test('ツリーの読み直しで外れても元は消さない。利用者の削除で元・付属・キャッシュを消す', () async {
      final base = p.join(proj, 'trees');
      await writePoints(base);
      final root = await openRoot();
      final node = root.children.whereType<ExternalLayerNode>().single;
      final cachePath = node.geoPackageFile.getAbsolutePath()!;
      expect(File(cachePath).existsSync(), isTrue);

      await root.updateChildren();
      await root.updateChildren();
      expect(File('$base.shp').existsSync(), isTrue);

      await node.dispose();
      for (final ext in ['.shp', '.shx', '.dbf', '.cpg']) {
        expect(File('$base$ext').existsSync(), isFalse, reason: ext);
      }
      expect(File(cachePath).existsSync(), isFalse);
    }, skip: skip);
  });

  group('編集の門番', () {
    test('選んだ地物をまとめて消しても、読み取り専用レイヤの地物は消さず「gpkg に変換して編集」を知らせる', () async {
      await writePoints(p.join(proj, 'trees'));
      final root = FolderNode('Home', children: []);
      await root.updateChildren();
      final node = root.children.whereType<ExternalLayerNode>().single;
      await node.updateChildren();
      final layer = node.children.whereType<LayerNode>().single;
      await layer.updateChildren();
      final features = layer.children.whereType<FeatureNode>().toList();
      expect(features, hasLength(3));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(selectedFeaturesProvider.notifier).set(features);
      await container.read(selectedFeaturesProvider.notifier).disposeSelectedFeatures();

      expect(await node.geoPackageFile.countFilteredFeatures('trees', '1=1'), 3);
      expect(File(p.join(proj, 'trees.shp')).existsSync(), isTrue);
      final notes = container.read(notificationCenterProvider);
      expect(notes.single.actionLabel, isNotNull);
    }, skip: skip);
  });

  group('gpkg への変換', () {
    Future<(FolderNode, ExternalLayerNode)> open(String name) async {
      final root = FolderNode('Home', children: []);
      await root.updateChildren();
      final node = root.children.whereType<ExternalLayerNode>().firstWhere((n) => n.name == name);
      await node.updateChildren();
      return (root, node);
    }

    test('書いて確かめてから元一式を消し、設定の鍵を移す', () async {
      final base = p.join(proj, 'trees');
      await writePoints(base, prj: 'EPSG:4326');
      final (root, node) = await open('trees.shp');
      // 可視性・スタイル・View を旧い鍵で持っておく
      await KMetaService.instance.setGeoPackageVisibility(proj, 'trees.shp', false);
      await KMetaService.instance.setLayerVisibility(proj, 'trees.shp/trees', false);
      await KMetaService.instance.setLayerStyle(proj, 'trees.shp/trees', const KMetaLayerStyle(pointSize: 7));
      await KMetaService.instance.setViews(proj, 'trees.shp/trees', [const KMetaView(name: '高い', filter: 'H > 10')]);

      final result = await ExternalLayerConverter.convert(node);
      expect(result.outcome, ExternalConvertOutcome.converted);
      expect(p.basename(result.gpkgPath!), 'trees.gpkg');
      for (final ext in ['.shp', '.shx', '.dbf', '.prj', '.cpg']) {
        expect(File('$base$ext').existsSync(), isFalse, reason: ext);
      }

      final gpkg = root.children.whereType<GeoPackageNode>().single;
      expect(gpkg, isNot(isA<ExternalLayerNode>()));
      expect(gpkg.name, 'trees.gpkg');
      final db = await gpkg.geoPackageFile.getDatabase();
      expect(await db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = '${ExternalLayerCache.markerTable}'"), isEmpty);
      expect(await gpkg.geoPackageFile.countFilteredFeatures('trees', '1=1'), 3);
      expect(await gpkg.geoPackageFile.getColumnNames('trees', getAll: true, skipPrimaryKey: true), containsAll(['NAME', 'H']));

      KMetaService.instance.clearCache();
      final meta = await KMetaService.instance.getMeta(proj);
      expect(meta.visibility.geopackages['trees.gpkg'], isFalse);
      expect(meta.visibility.geopackages.containsKey('trees.shp'), isFalse);
      expect(meta.visibility.layers['trees.gpkg/trees'], isFalse);
      expect(meta.styles.layers['trees.gpkg/trees']?.pointSize, 7);
      expect(meta.views['trees.gpkg/trees']?.single.filter, 'H > 10');
      await gpkg.geoPackageFile.dispose();
    }, skip: skip);

    test('同名の gpkg があれば _1 を付ける（既存の gpkg に混ぜない）', () async {
      writeGeoJson(p.join(proj, 'a.geojson'), [
        feature({
          'type': 'Point',
          'coordinates': [135.0, 33.0],
        }, {}),
      ]);
      File(p.join(proj, 'a.gpkg')).writeAsBytesSync(const [1]);
      File(p.join(proj, 'a_1.gpkg')).writeAsBytesSync(const [1]);
      expect(p.basename(await ExternalLayerConverter.uniqueGpkgPath(proj, 'a')), 'a_2.gpkg');
    }, skip: skip);

    test('件数が食い違えば書いた gpkg を消し、元は残す', () async {
      final path = p.join(proj, 'pts.geojson');
      writeGeoJson(path, [
        feature(
          {
            'type': 'Point',
            'coordinates': [135.0, 33.0],
          },
          {'n': 1},
        ),
        feature(
          {
            'type': 'Point',
            'coordinates': [135.1, 33.1],
          },
          {'n': 2},
        ),
      ]);
      final (_, node) = await open('pts.geojson');
      // キャッシュから 1 件消して、元（2 件）と食い違わせる
      final db = await node.geoPackageFile.getDatabase();
      await db.rawDelete('DELETE FROM pts WHERE n = 2');

      await expectLater(ExternalLayerConverter.convert(node), throwsA(isA<ExternalConvertVerifyException>()));
      expect(File(path).existsSync(), isTrue);
      expect(File(p.join(proj, 'pts.gpkg')).existsSync(), isFalse);
    }, skip: skip);

    test('変換しても CRS は元のまま（EPSG:6674 の shp → EPSG:6674 の gpkg）、日本語の属性も', () async {
      copyFixture('sjis_nocpg', as: '林班');
      final (root, node) = await open('林班.shp');
      expect(await epsgOf(node.geoPackageFile, '林班'), 'EPSG:6674');
      final result = await ExternalLayerConverter.convert(node);
      expect(result.outcome, ExternalConvertOutcome.converted);
      final gpkg = root.children.whereType<GeoPackageNode>().single;
      expect(gpkg.name, '林班.gpkg');
      expect(await epsgOf(gpkg.geoPackageFile, '林班'), 'EPSG:6674');
      expect(await namesIn(gpkg.geoPackageFile, '林班'), gdalScenarioNames);
      // 書いた gpkg を GDAL で読み直しても同じ（QGIS からも 6674 に見える）
      final info = await ExternalGdal.instance.vectorInfo(result.gpkgPath!, args: const ['-so']);
      expect(layerEpsg(info), 6674);
      await gpkg.geoPackageFile.dispose();
    }, skip: skip);

    test('自分のフォルダへ gpkg として複製（元は残す）', () async {
      await writePoints(p.join(proj, 'trees'));
      final mine = await Directory(p.join(proj, 'mine')).create();
      final (root, node) = await open('trees.shp');
      final target = root.children.whereType<FolderNode>().single;
      final result = await ExternalLayerConverter.copyAsGeoPackage(node, target);
      expect(result.outcome, ExternalConvertOutcome.copied);
      expect(result.gpkgPath, p.join(mine.path, 'trees.gpkg'));
      expect(File(p.join(proj, 'trees.shp')).existsSync(), isTrue);
      expect(target.children.whereType<GeoPackageNode>().single.name, 'trees.gpkg');
    }, skip: skip);
  });
}
