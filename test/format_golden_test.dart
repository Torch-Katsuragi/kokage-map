// 形式まわりの出力を、決まった結果（test/fixtures/golden/）と突き合わせる。
//
// 書き出し（Shapefile・GeoJSON・KML・CSV）のバイト、取り込み（Shapefile・GeoJSON）で
// GeoPackage に入る中身、`.qgs` の XML（新規・DOM 保持の更新・QGIS からの読み取り）を固める。
// リファクタリングで結果が変わらないことを確かめるためのもの。
//
// 出力を意図して変えたときは `KOKAGE_UPDATE_GOLDEN=1 flutter test test/format_golden_test.dart`
// で作り直し、git の差分で変わった所を確かめてからコミットする。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/services/coordinate/epsg_registry.dart';
import 'package:root_maps/services/import_export/exporters/shapefile_writer.dart';
import 'package:root_maps/services/import_export/import_export_service.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_auto_refresh.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis/qgs_writer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

final _update = Platform.environment['KOKAGE_UPDATE_GOLDEN'] == '1';
const _goldenDir = 'test/fixtures/golden';

/// バイナリの形式（改行を正規化しない）
const _binaryExts = {'.shp', '.shx', '.dbf'};

/// [bytes] を `test/fixtures/golden/[rel]` と比べる（更新モードなら書く）。
/// 文字の形式は改行を揃えてから比べる（Windows の checkout は CRLF になる）
void _expectGolden(String rel, List<int> bytes) {
  final file = File(p.join(_goldenDir, rel));
  final binary = _binaryExts.contains(p.extension(rel).toLowerCase());
  if (_update) {
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return;
  }
  expect(file.existsSync(), isTrue, reason: '$rel が無い（KOKAGE_UPDATE_GOLDEN=1 で作る）');
  List<int> norm(List<int> b) => binary ? b : utf8.encode(utf8.decode(b, allowMalformed: true).replaceAll('\r\n', '\n'));
  final actual = norm(bytes);
  final expected = norm(file.readAsBytesSync());
  var firstDiff = -1;
  for (var i = 0; i < actual.length && i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      firstDiff = i;
      break;
    }
  }
  if (firstDiff < 0 && actual.length != expected.length) firstDiff = actual.length < expected.length ? actual.length : expected.length;
  expect(firstDiff, -1, reason: '$rel: $firstDiff バイト目から違う（長さ ${actual.length} / 期待 ${expected.length}）');
}

void _expectGoldenText(String rel, String text) => _expectGolden(rel, utf8.encode(text));

String _prettyJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

/// 行の値を JSON にできる形へ（blob は16進）
Object? _jsonable(Object? v) => switch (v) {
  Uint8List() => v.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  Map() => {for (final e in v.entries) '${e.key}': _jsonable(e.value)},
  List() => [for (final x in v) _jsonable(x)],
  _ => v,
};

void main() {
  late Directory tmp;
  late String proj;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    QgsAutoRefresh.instance.enabled = false;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('format_golden_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<FolderNode> loadTree() async {
    final root = FolderNode('Home', children: []);
    Future<void> load(LayerTreeNode n) async {
      await n.updateChildren();
      for (final c in n.children) {
        if (c is FolderNode || c is GeoPackageNode) await load(c);
      }
    }

    await load(root);
    return root;
  }

  /// 点・線・面と属性（日本語・カンマと引用符・null・数値）を持つ gpkg
  Future<void> makeSourceGpkg(String path) async {
    final g = GeoPackageFile([p.basename(path)], absolutePath: path);
    const attrs = {'name': 'TEXT', 'description': 'TEXT', 'h': 'REAL', 'n': 'INTEGER'};
    await g.addLayer('pts', GeometryType.point);
    await g.addAttributeColumns('pts', attrs);
    await g.addPointsBatch('pts', [
      {'point': const LatLng(33.91, 135.97), 'name': '杉', 'description': '樹高 "高い", 太い', 'h': 21.5, 'n': 3},
      {'point': const LatLng(33.92, 135.98), 'name': 'hinoki', 'h': null, 'n': 7},
      {'point': const LatLng(33.93, 135.99), 'name': null, 'description': 'line\nbreak', 'h': 0.125},
    ]);
    await g.addLayer('lns', GeometryType.linestring);
    await g.addAttributeColumns('lns', attrs);
    await g.addLinesBatch('lns', [
      {
        'line': const [LatLng(33.90, 135.90), LatLng(33.91, 135.91), LatLng(33.905, 135.93)],
        'name': '林道 A',
        'h': 3.0,
      },
      {
        'line': const [LatLng(33.80, 135.80), LatLng(33.81, 135.82)],
        'name': 'path',
        'n': 1,
      },
    ]);
    await g.addLayer('pls', GeometryType.polygon);
    await g.addAttributeColumns('pls', attrs);
    await g.addPolygonsBatch('pls', [
      {
        'rings': const [
          [LatLng(33.0, 135.0), LatLng(33.0, 135.1), LatLng(33.1, 135.1), LatLng(33.1, 135.0)],
          [LatLng(33.02, 135.02), LatLng(33.08, 135.02), LatLng(33.08, 135.08), LatLng(33.02, 135.08), LatLng(33.02, 135.02)],
        ],
        'name': '小班 1-い',
        'h': 12.25,
        'n': 10,
      },
      {
        'rings': const [
          [LatLng(34.0, 136.0), LatLng(34.1, 136.0), LatLng(34.1, 136.1), LatLng(34.0, 136.0)],
        ],
        'name': 'b',
      },
    ]);
    await g.flushChanges();
    await g.dispose();
  }

  group('書き出し', () {
    final cases = <(String, FileFormat, ExportOptions)>[
      ('shp_wgs84', FileFormat.shapefile, const ExportOptions()),
      (
        'shp_6674_rownum',
        FileFormat.shapefile,
        ExportOptions(targetCrs: EpsgRegistry.instance.getByCode('EPSG:6674'), includeRowNumber: true),
      ),
      ('geojson', FileFormat.geojson, const ExportOptions()),
      ('kml', FileFormat.kml, const ExportOptions()),
      ('csv', FileFormat.csv, const ExportOptions()),
    ];

    test('点・線・面を各形式に書き出す', () async {
      await makeSourceGpkg(p.join(proj, 'src.gpkg'));
      final root = await loadTree();
      final gpkg = root.children.whereType<GeoPackageNode>().single;
      final layers = gpkg.children.whereType<LayerNode>().toList()..sort((a, b) => a.layerName.compareTo(b.layerName));
      expect(layers.map((l) => l.layerName), ['lns', 'pls', 'pts']);

      for (final (name, format, options) in cases) {
        for (final layer in layers) {
          final outDir = await Directory(p.join(tmp.path, 'out', name, layer.layerName)).create(recursive: true);
          final outPath = p.join(outDir.path, '${layer.layerName}${format.extension}');
          final result = await ImportExportService().exportLayer(layer, outPath, format: format, options: options);
          final summary = {
            'success': result.success,
            'error': result.errorMessage,
            'metadata': _jsonable(result.metadata?.map((k, v) => MapEntry(k, k == 'outputPath' ? p.basename('$v') : v))),
          };
          _expectGoldenText('export/$name/${layer.layerName}/result.json', _prettyJson(summary));
          final files = outDir.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
          for (final f in files) {
            final bytes = f.readAsBytesSync();
            // DBF のヘッダの 1〜3 バイト目は書いた日付
            if (p.extension(f.path) == '.dbf' && bytes.length > 4) bytes.setRange(1, 4, const [0, 0, 0]);
            _expectGolden('export/$name/${layer.layerName}/${p.basename(f.path)}', bytes);
          }
        }
      }
      await gpkg.geoPackageFile.dispose();
    });
  });

  group('取り込み', () {
    Future<Map<String, Object?>> dumpImport(ImportExportResult result, GeoPackageNode target) async {
      final db = await target.geoPackageFile.getDatabase();
      final tables = <String, Object?>{};
      for (final layer in result.createdLayers ?? const <LayerNode>[]) {
        final columns = await db.rawQuery('PRAGMA table_info("${layer.layerName}")');
        final rows = await db.rawQuery('SELECT * FROM "${layer.layerName}" ORDER BY rowid');
        tables[layer.layerName] = {
          'columns': [for (final c in columns) '${c['name']} ${c['type']}'],
          'rows': _jsonable(rows),
        };
      }
      return {
        'success': result.success,
        'error': result.errorMessage,
        'layers': [for (final l in result.createdLayers ?? const <LayerNode>[]) l.layerName],
        'metadata': _jsonable(result.metadata?.map((k, v) => MapEntry(k, k == 'sourceFile' ? p.basename('$v') : v))),
        'tables': tables,
      };
    }

    Future<GeoPackageNode> targetGpkg() async {
      final g = GeoPackageFile(const ['dst.gpkg'], absolutePath: p.join(proj, 'dst.gpkg'));
      await g.addLayer('existing', GeometryType.point);
      await g.dispose();
      final root = await loadTree();
      return root.children.whereType<GeoPackageNode>().single;
    }

    void writeShapefile(String base, int type, List<ShpShape> shapes, List<Map<String, dynamic>> attrs, {String? prjCode}) {
      final r = encodeShpShx(type, shapes);
      File('$base.shp').writeAsBytesSync(r.shp);
      File('$base.shx').writeAsBytesSync(r.shx);
      File('$base.dbf').writeAsBytesSync(encodeDbf(attrs, now: DateTime(2026, 10, 7)));
      if (prjCode != null) File('$base.prj').writeAsStringSync(EpsgRegistry.instance.getWktString(prjCode)!);
      File('$base.cpg').writeAsStringSync('CP932');
    }

    test('Shapefile（WGS84 の点・平面直角の面・名前の重なり）', () async {
      final target = await targetGpkg();
      final src = await Directory(p.join(tmp.path, 'src')).create();
      writeShapefile(
        p.join(src.path, 'existing'),
        1,
        [
          [
            [
              [135.97, 33.91],
            ],
          ],
          [
            [
              [135.98, 33.92],
            ],
          ],
          [
            [
              [200.0, 33.92], // WGS84 の範囲外。形が捨てられる
            ],
          ],
          [
            [
              [135.99, 33.93],
            ],
          ],
        ],
        [
          {'NAME': 'sugi', 'H': 21.5, 'N': 3, 'OK': true},
          {'NAME': '', 'H': 1.0, 'N': 4, 'OK': false},
          {'NAME': 'out', 'H': 2.0, 'N': 5, 'OK': true},
          {'NAME': 'last', 'H': 3.0, 'N': 6, 'OK': true},
        ],
        prjCode: 'EPSG:4326',
      );
      final pts = await ImportExportService().importFile(p.join(src.path, 'existing.shp'), target);
      _expectGoldenText('import/shp_points.json', _prettyJson(await dumpImport(pts, target)));

      // 平面直角座標系 VI 系（EPSG:6674）の面。原点付近
      writeShapefile(
        p.join(src.path, 'stands'),
        5,
        [
          [
            [
              [0.0, 0.0],
              [100.0, 0.0],
              [100.0, 100.0],
              [0.0, 100.0],
              [0.0, 0.0],
            ],
            [
              [20.0, 20.0],
              [20.0, 40.0],
              [40.0, 40.0],
              [20.0, 20.0],
            ],
          ],
        ],
        [
          {'KOHAN': 'い', 'AREA': 0.99},
        ],
        prjCode: 'EPSG:6674',
      );
      final pls = await ImportExportService().importFile(p.join(src.path, 'stands.shp'), target, layerName: 'stands');
      _expectGoldenText('import/shp_polygons_6674.json', _prettyJson(await dumpImport(pls, target)));

      writeShapefile(
        p.join(src.path, 'roads'),
        3,
        [
          [
            [
              [135.90, 33.90],
              [135.91, 33.91],
            ],
            [
              [135.92, 33.92],
              [135.93, 33.93],
            ],
          ],
        ],
        [
          {'NAME': 'r1'},
        ],
      );
      final lns = await ImportExportService().importFile(p.join(src.path, 'roads.shp'), target);
      _expectGoldenText('import/shp_lines.json', _prettyJson(await dumpImport(lns, target)));
      await target.geoPackageFile.dispose();
    });

    test('GeoJSON（形の種類ごとにレイヤを分ける）', () async {
      final target = await targetGpkg();
      final src = await Directory(p.join(tmp.path, 'src')).create();
      final path = p.join(src.path, 'mixed.geojson');
      File(path).writeAsStringSync(jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'name': '杉', 'h': 21.5, 'n': 3, 'ok': true},
            'geometry': {'type': 'Point', 'coordinates': [135.97, 33.91]},
          },
          {
            'type': 'Feature',
            'properties': {'name': 'multi', 'extra': 'x'},
            'geometry': {
              'type': 'MultiPoint',
              'coordinates': [
                [135.98, 33.92],
                [135.99, 33.93],
              ],
            },
          },
          {
            'type': 'Feature',
            'properties': {'name': 'line'},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [135.9, 33.9],
                [135.91, 33.91],
              ],
            },
          },
          {
            'type': 'Feature',
            'properties': {'name': 'short'},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [135.9, 33.9],
              ],
            },
          },
          {
            'type': 'Feature',
            'properties': {'name': 'mline'},
            'geometry': {
              'type': 'MultiLineString',
              'coordinates': [
                [
                  [135.8, 33.8],
                  [135.81, 33.81],
                ],
                [
                  [135.82, 33.82],
                  [135.83, 33.83],
                ],
              ],
            },
          },
          {
            'type': 'Feature',
            'properties': {'name': 'poly', 'h': 1},
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [135.0, 33.0],
                  [135.1, 33.0],
                  [135.1, 33.1],
                  [135.0, 33.0],
                ],
              ],
            },
          },
          {
            'type': 'Feature',
            'properties': {'name': 'mpoly'},
            'geometry': {
              'type': 'MultiPolygon',
              'coordinates': [
                [
                  [
                    [136.0, 34.0],
                    [136.1, 34.0],
                    [136.1, 34.1],
                    [136.0, 34.0],
                  ],
                ],
              ],
            },
          },
          {'type': 'Feature', 'properties': {'name': 'nogeom'}, 'geometry': null},
        ],
      }));
      final result = await ImportExportService().importFile(path, target);
      _expectGoldenText('import/geojson_mixed.json', _prettyJson(await dumpImport(result, target)));

      // 1 種類だけならレイヤ名に種類を付けない
      final single = p.join(src.path, 'single.json');
      File(single).writeAsStringSync(jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'a': 'b'},
            'geometry': {'type': 'Point', 'coordinates': [135.0, 33.0]},
          },
        ],
      }));
      final one = await ImportExportService().importFile(single, target, layerName: 'existing');
      _expectGoldenText('import/geojson_single.json', _prettyJson(await dumpImport(one, target)));

      // 読めないもの
      final errors = <String, Object?>{};
      File(p.join(src.path, 'feature.geojson')).writeAsStringSync(jsonEncode({
        'type': 'Feature',
        'properties': {},
        'geometry': {'type': 'Point', 'coordinates': [135.0, 33.0]},
      }));
      File(p.join(src.path, 'empty.geojson')).writeAsStringSync(jsonEncode({'type': 'FeatureCollection', 'features': []}));
      for (final name in ['feature.geojson', 'empty.geojson', 'missing.geojson', 'missing.shp', 'x.kml']) {
        final r = await ImportExportService().importFile(p.join(src.path, name), target);
        errors[name] = {'success': r.success, 'error': r.errorMessage?.replaceAll(src.path, '<src>')};
      }
      _expectGoldenText('import/errors.json', _prettyJson(errors));
      await target.geoPackageFile.dispose();
    });
  });

  group('.qgs', () {
    QgsLayer layer(
      String id,
      String name, {
      GeometryType geometry = GeometryType.point,
      String table = 't',
      String path = './a.gpkg',
      String? subset,
      QgsStyle? style,
      bool visible = true,
      QgsCrs crs = QgsCrs.wgs84,
    }) =>
        QgsLayer(
          id: id,
          name: name,
          dataSourcePath: path,
          tableName: table,
          geometryType: geometry,
          crs: crs,
          subset: subset,
          style: style,
          visible: visible,
        );

    const plane = QgsCrs(
      authId: 'EPSG:6674',
      srid: 6674,
      description: 'JGD2011 / Japan Plane Rectangular CS VI',
      wkt: 'PROJCS["JGD2011 / Japan Plane Rectangular CS VI"]',
      proj4: '+proj=tmerc +lat_0=36 +lon_0=136 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      isGeographic: false,
    );

    final richProject = QgsProject(
      name: '北山 & <テスト>',
      root: [
        QgsGroup(
          name: 'sub',
          expanded: false,
          visible: false,
          children: [
            QgsGroup(
              name: 'a.gpkg',
              children: [
                QgsGroup(
                  name: 'pts',
                  children: [
                    layer(
                      'v_pts',
                      'pts',
                      table: 'pts',
                      path: './sub/a.gpkg',
                      style: const QgsStyle(
                        pointColor: Color(0xFF112233),
                        pointSizePx: 5,
                        labelEnabled: true,
                        labelField: '"name"',
                        labelFontSizePt: 9,
                        labelColor: Color(0xFF445566),
                        labelHaloColor: Color(0xFFFFFFEE),
                      ),
                    ),
                    layer('v_pts2', 'スギ', table: 'pts', path: './sub/a.gpkg', subset: "樹種 = 'スギ' | x", visible: false),
                  ],
                ),
              ],
            ),
          ],
        ),
        QgsGroup(
          name: 'b.gpkg',
          children: [
            QgsGroup(
              name: 'roads',
              children: [
                layer(
                  'v_roads',
                  'roads',
                  geometry: GeometryType.linestring,
                  table: 'roads',
                  path: './b.gpkg',
                  crs: plane,
                  style: const QgsStyle(lineColor: Color(0x80FF0000), lineWidthPx: 3),
                ),
              ],
            ),
            QgsGroup(
              name: 'stands',
              children: [
                layer(
                  'v_stands',
                  'stands',
                  geometry: GeometryType.polygon,
                  table: 'stands',
                  path: './b.gpkg',
                  style: const QgsStyle(
                    fillColor: Color(0xFF00FF00),
                    fillOpacity: 0.4,
                    strokeColor: Color(0xFF000080),
                    strokeWidthPx: 1.5,
                    strokeOpacity: 0.9,
                    labelEnabled: false,
                    labelField: 'x',
                  ),
                ),
              ],
            ),
          ],
        ),
        const QgsRasterLayer(id: 'raster_1', name: 'ortho', dataSourcePath: './ortho.tif', visible: false),
      ],
      projectCrs: plane,
    );

    test('新規に書く', () {
      _expectGoldenText('qgs/build.qgs', const QgsWriter().build(richProject));
      final created = QgsDocument.create(projectName: 'empty', projectCrs: plane);
      _expectGoldenText('qgs/create.qgs', created.toXmlString());
    });

    test('QGIS が書いた .qgs に反映する（DOM 保持）', () {
      // QGIS 3.44 の出力。片方の View は id を合わせて直し、もう片方は外す
      final doc344 = QgsDocument.parse(File('test/fixtures/qgis_3_44_written.qgs').readAsStringSync());
      final r344 = doc344.apply(
        QgsProject(
          name: 'p344',
          root: [
            QgsGroup(
              name: '林小班.gpkg',
              children: [
                QgsGroup(
                  name: 'rinshoban',
                  children: [
                    layer(
                      '___56902204_7d58_4032_ab25_8588e0e0aa73',
                      '大きい',
                      geometry: GeometryType.polygon,
                      table: 'rinshoban',
                      path: './林小班.gpkg',
                      subset: 'area > 200',
                      style: const QgsStyle(fillColor: Color(0xFF123456), strokeWidthPx: 2, labelEnabled: true, labelField: 'name'),
                    ),
                    layer('new_one', '新しい', table: 'rinshoban', path: './林小班.gpkg'),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      doc344.setStamp(KokageStamp(schemaVersion: 2, app: 'kokage-map test', savedAt: DateTime(2026, 10, 7, 12), dirName: 'p344', savedBy: 'dev'));
      doc344.kokageMeta = '{"version":2}';
      _expectGoldenText('qgs/apply_3_44.qgs', doc344.toXmlString());

      // QGIS 4.2 の出力（properties の書き方が違う）。2 回反映してラベルの差し替えも通す
      final doc42 = QgsDocument.parse(File('test/fixtures/qgis_4_2_saved.qgs').readAsStringSync());
      QgsProject project42(QgsStyle pointStyle) => QgsProject(
        name: 'p42',
        root: [
          QgsGroup(
            name: 'survey_points.gpkg',
            children: [
              QgsGroup(
                name: 'survey_points',
                children: [
                  layer(
                    'survey_points_gpkg_survey_points____17ee55305316',
                    'survey_points',
                    table: 'survey_points',
                    path: './survey_points.gpkg',
                    style: pointStyle,
                  ),
                ],
              ),
            ],
          ),
          QgsGroup(
            name: 'forest_roads.gpkg',
            children: [
              QgsGroup(
                name: 'forest_roads',
                children: [
                  layer(
                    'forest_roads_gpkg_forest_roads____c153b039d508',
                    'forest_roads',
                    geometry: GeometryType.linestring,
                    table: 'forest_roads',
                    path: './forest_roads.gpkg',
                    style: const QgsStyle(lineWidthPx: 4),
                  ),
                ],
              ),
            ],
          ),
          const QgsRasterLayer(id: 'raster_37a2b2888379', name: 'overlay', dataSourcePath: './test_overlay.tif'),
        ],
      );
      final r42a = doc42.apply(
        project42(const QgsStyle(pointColor: Color(0xFFABCDEF), labelEnabled: true, labelField: '"id"', labelHaloColor: Color(0xFF000000))),
      );
      final r42b = doc42.apply(
        project42(const QgsStyle(pointSizePx: 8, labelEnabled: true, labelField: '"code"', labelFontSizePt: 12, labelHaloColor: Color(0xFF222222))),
      );
      doc42.setStamp(KokageStamp(schemaVersion: 2, app: 'kokage-map test', savedAt: DateTime(2026, 10, 7, 12), dirName: 'p42'));
      doc42.kokageMeta = '{"version":2,"views":{}}';
      _expectGoldenText('qgs/apply_4_2.qgs', doc42.toXmlString());

      // 単一シンボル以外は触らない・ラベルを消す
      final docCat = QgsDocument.parse(
        File('test/fixtures/qgis_4_2_saved.qgs').readAsStringSync().replaceAll('type="singleSymbol"', 'type="categorizedSymbol"'),
      );
      final rCat = docCat.apply(project42(const QgsStyle(pointColor: Color(0xFF00FF00), labelEnabled: false)));
      _expectGoldenText('qgs/apply_categorized.qgs', docCat.toXmlString());

      _expectGoldenText(
        'qgs/apply_reports.json',
        _prettyJson({
          for (final (name, r) in [('344', r344), ('42a', r42a), ('42b', r42b), ('cat', rCat)])
            name: {'removed': r.removedLayers, 'untouched': r.untouchedRenderers},
        }),
      );
      _expectGoldenText(
        'qgs/stamps.json',
        _prettyJson({
          for (final (name, d) in [('344', doc344), ('42', doc42)])
            name: {
              'stamp': d.stamp == null ? null : [d.stamp!.schemaVersion, d.stamp!.app, d.stamp!.savedAtText, d.stamp!.savedBy, d.stamp!.dirName],
              'mine': d.lastWrittenByKokage,
              'meta': d.kokageMeta,
            },
        }),
      );
    });

    test('QGIS の .qgs からスタイルを読む', () {
      final out = <String, Object?>{};
      for (final fixture in ['qgis_3_44_written.qgs', 'qgis_4_2_saved.qgs']) {
        for (final source in [
          File('test/fixtures/$fixture').readAsStringSync(),
          const QgsWriter().build(richProject),
        ]) {
          final doc = XmlDocument.parse(source);
          for (final maplayer in doc.findAllElements('maplayer')) {
            final id = maplayer.getElement('id')?.innerText ?? '?';
            out['$fixture/$id'] = const QgsImporter().readStyleWithLabel(maplayer)?.toJson();
          }
        }
      }
      // データソース文字列の分解
      for (final raw in ['./a.gpkg|layername=t|subset=a | b = 1', 'x.gpkg|LayerName = y |layerid=0', '', '|layername=z']) {
        final s = QgsDataSource.parse(raw);
        out['ds:$raw'] = s == null ? null : [s.path, s.layerName, s.subset];
      }
      _expectGoldenText('qgs/read_styles.json', _prettyJson(out));
    });

    test('レイヤツリーから書いて QGIS の保存を読み戻す', () async {
      await makeSourceGpkg(p.join(proj, 'src.gpkg'));
      final sub = await Directory(p.join(proj, 'sub')).create();
      await makeSourceGpkg(p.join(sub.path, 'b.gpkg'));
      await KMetaService.instance.setLayerStyle(sub.path, 'b.gpkg/pls', const KMetaLayerStyle(polygonFillColor: Color(0xFF0000FF), polygonFillOpacity: 0.5));
      await KMetaService.instance.setLayerStyle(proj, 'src.gpkg/pts', const KMetaLayerStyle(pointColor: Color(0xFFFF0000), labelEnabled: true, labelProperty: 'name'));
      var root = await loadTree();
      final pts = root.children.whereType<GeoPackageNode>().single.children.whereType<LayerNode>().firstWhere((l) => l.layerName == 'pts');
      await pts.loadViews();
      final written = await const QgsProjectBuilder().writeTo(root);
      // 書いた時刻とアプリの版は伏せる
      String masked(String path) => File(path)
          .readAsStringSync()
          .replaceAll(RegExp('(saveDateTime|saveUserFull)="[^"]*"'), '')
          .replaceAllMapped(RegExp(r'(<(savedAt|app)[^>]*>)[^<]*(</(savedAt|app)>)'), (m) => '${m[1]}${m[3]}');
      _expectGoldenText('qgs/tree_root.qgs', masked(written!.path));
      _expectGoldenText('qgs/tree_sub.qgs', masked(p.join(sub.path, 'sub.qgs')));

      // QGIS で保存した体にして取り込む: 色を変え、View を足し、外部参照を足す
      final doc = XmlDocument.parse(File(written.path).readAsStringSync());
      final projectLayers = doc.findAllElements('projectlayers').single;
      final ptsLayer = projectLayers.findElements('maplayer').firstWhere((e) => e.getElement('datasource')!.innerText.contains('layername=pts'));
      for (final o in ptsLayer.findAllElements('Option').where((o) => o.getAttribute('name') == 'color')) {
        o.setAttribute('value', '1,2,3,255');
      }
      final copy = ptsLayer.copy();
      copy.getElement('id')!.innerText = 'extra_view';
      copy.getElement('layername')!.innerText = '絞り込み';
      copy.getElement('datasource')!.innerText = './src.gpkg|layername=pts|subset="n" > 2';
      projectLayers.children.add(copy);
      final outside = ptsLayer.copy();
      outside.getElement('id')!.innerText = 'outside';
      outside.getElement('datasource')!.innerText = '../../elsewhere.gpkg|layername=pts';
      projectLayers.children.add(outside);
      doc.rootElement.setAttribute('saveDateTime', '2099-01-01T00:00:00');
      File(written.path).writeAsStringSync(doc.toXmlString());

      root = await loadTree();
      final imported = await const QgsImporter().import(written.path, root);
      final views = <String, Object?>{};
      for (final g in root.children.whereType<GeoPackageNode>()) {
        for (final l in g.children.whereType<LayerNode>()) {
          views[l.layerKey] = {
            'visible': l.visible,
            'views': [for (final v in l.views) [v.name, v.filter, v.visible, v.style?.toJson()]],
          };
        }
      }
      _expectGoldenText(
        'qgs/tree_import.json',
        _prettyJson({
          'viewsByLayer': imported.viewsByLayer,
          'discarded': imported.discarded.map((d) => d.replaceAll(tmp.path, '<tmp>')).toList(),
          'views': views,
          'meta': (await KMetaService.instance.getRawMeta(proj))?.toJson()?..remove('sync'),
        }),
      );
      for (final g in root.children.whereType<GeoPackageNode>()) {
        await g.geoPackageFile.dispose();
      }
      for (final g in root.children.whereType<FolderNode>().expand((f) => f.children).whereType<GeoPackageNode>()) {
        await g.geoPackageFile.dispose();
      }
    });
  });
}
