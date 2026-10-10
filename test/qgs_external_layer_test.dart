// 読み取り専用レイヤ（GDAL で読む形式）の `.qgs` との往復（[[external-formats#.qgs との往復]]）
//
// GDAL（QGIS の gdal*.dll / apt の libgdal）が無ければ skip。⚠ GDAL を sqflite より先に読み込む（test/gdal_test.dart の注意）
//
// 書く: provider=ogr で元のファイルを指す（キャッシュのパスは書かない）。1 ファイル 1 レイヤなら `|layername=` なし。
// 読む: ogr の非 gpkg は `|layername=` が無ければファイル名で ExternalLayerNode のレイヤに結びつける。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/nodes/external_layer_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/coordinate/epsg_registry.dart';
import 'package:root_maps/services/external/external_source.dart';
import 'package:root_maps/services/import_export/exporters/shapefile_writer.dart';
import 'package:root_maps/services/import_export/parsers/shapefile_binary_parser.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_auto_refresh.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

import 'support/gdal_host.dart';

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
    QgsAutoRefresh.instance.enabled = false;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('qgs_ext_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);

    // 平面直角 VI 系の点（.cpg なし = Shift_JIS）
    final base = p.join(proj, '林班');
    final r = encodeShpShx(ShapeType.point, [
      [
        [[0.0, 0.0]],
      ],
      [
        [[10.0, 10.0]],
      ],
    ]);
    File('$base.shp').writeAsBytesSync(r.shp);
    File('$base.shx').writeAsBytesSync(r.shx);
    File('$base.dbf').writeAsBytesSync(encodeDbf([
      {'H': 10.0},
      {'H': 20.0},
    ]));
    File('$base.prj').writeAsStringSync(EpsgRegistry.instance.getWktString('EPSG:6674')!);

    // 型の混ざった GeoJSON
    File(p.join(proj, 'mixed.geojson')).writeAsStringSync(jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {'a': 1},
          'geometry': {'type': 'Point', 'coordinates': [135.0, 33.0]},
        },
        {
          'type': 'Feature',
          'properties': {'a': 2},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [135.0, 33.0],
              [135.1, 33.1],
            ],
          },
        },
      ],
    }));
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<FolderNode> loadTree() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    for (final node in root.children.whereType<ExternalLayerNode>()) {
      await node.updateChildren();
    }
    return root;
  }

  test('書く: 元のファイルを ogr で指し、CRS は元のまま（キャッシュ gpkg から）、.cpg の無い shp は CP932', () async {
    final root = await loadTree();
    final project = await const QgsProjectBuilder().build(root);
    final layers = project.layers;
    final shp = layers.singleWhere((l) => l.dataSourcePath == './林班.shp');
    expect(shp.dataSourceUri, './林班.shp', reason: '1 ファイル 1 レイヤなら |layername= を付けない');
    // キャッシュは ogr2ogr が元の CRS のまま書いている（.prj → EPSG:6674）
    expect(shp.crs.authId, 'EPSG:6674');
    expect(shp.crs.isGeographic, isFalse);
    expect(shp.providerEncoding, 'CP932');

    final mixed = layers.where((l) => l.dataSourcePath == './mixed.geojson').map((l) => l.dataSourceUri).toList();
    expect(mixed, unorderedEquals(['./mixed.geojson|geometrytype=Point', './mixed.geojson|geometrytype=LineString']));
    expect(layers.every((l) => !l.dataSourcePath.contains('.kokage')), isTrue, reason: 'キャッシュのパスは書かない');

    final result = await const QgsProjectBuilder().writeTo(root);
    // KOKAGE_KEEP_QGS=<dir> で書いた一式を残す（QGIS で開く確認用: tool/qgis/check_qgs.py）
    final keep = Platform.environment['KOKAGE_KEEP_QGS'];
    if (keep != null) {
      for (final f in Directory(proj).listSync().whereType<File>()) {
        f.copySync(p.join(keep, p.basename(f.path)));
      }
    }
    final xml = File(result!.path).readAsStringSync();
    expect(xml, contains('<datasource>./林班.shp</datasource>'));
    expect(xml, contains('encoding="CP932"'));
  }, skip: skip);

  test('読む: |layername= の無い shp・geometrytype の GeoJSON を読み取り専用レイヤに結びつける', () async {
    final root = await loadTree();
    final written = await const QgsProjectBuilder().writeTo(root);
    final path = written!.path;

    // QGIS 側で View を 1 枚足した形（同じ元を subset 付きで指すレイヤ）
    final doc = XmlDocument.parse(File(path).readAsStringSync());
    final container = doc.findAllElements('projectlayers').single;
    final shpLayer = container.findElements('maplayer').firstWhere(
      (e) => e.getElement('datasource')!.innerText == './林班.shp',
    );
    final copy = shpLayer.copy();
    copy.getElement('id')!.innerText = 'tall_copy';
    copy.getElement('layername')!.innerText = '高い';
    copy.getElement('datasource')!.innerText = './林班.shp|subset="H" > 15';
    container.children.add(copy);
    // 型ごとのサブレイヤ（QGIS が GeoJSON に付ける形）
    final pointCopy = shpLayer.copy();
    pointCopy.getElement('id')!.innerText = 'mixed_point_copy';
    pointCopy.getElement('layername')!.innerText = '点だけ';
    pointCopy.getElement('datasource')!.innerText = './mixed.geojson|geometrytype=Point|subset="a" = 1';
    container.children.add(pointCopy);
    File(path).writeAsStringSync(doc.toXmlString());

    final result = await const QgsImporter().import(path, root);
    expect(result.discarded, isEmpty);
    final shp = root.children.whereType<ExternalLayerNode>().singleWhere((n) => n.name == '林班.shp');
    final layer = shp.children.whereType<LayerNode>().single;
    expect(layer.views.map((v) => v.name), contains('高い'));
    expect(layer.views.firstWhere((v) => v.name == '高い').filter, '"H" > 15');

    final mixed = root.children.whereType<ExternalLayerNode>().singleWhere((n) => n.name == 'mixed.geojson');
    final points = mixed.children.whereType<LayerNode>().singleWhere((l) => l.layerName == 'mixed_point');
    expect(points.views.map((v) => v.name), contains('点だけ'));
  }, skip: skip);

  test('QgsDataSource は geometrytype を読む', () {
    final s = QgsDataSource.parse('./a.geojson|geometrytype=Point|subset=x = 1')!;
    expect(s.path, './a.geojson');
    expect(s.layerName, isNull);
    expect(s.geometryType, 'Point');
    expect(s.subset, 'x = 1');
  });

  test('QgsLayer.dataSourceUri: uriOptions が空ならパスだけ', () {
    const layer = QgsLayer(
      id: 'x',
      name: 'x',
      dataSourcePath: './a.shp',
      tableName: 'a',
      geometryType: GeometryType.point,
      crs: QgsCrs.wgs84,
      uriOptions: [],
      subset: 'H > 1',
    );
    expect(layer.dataSourceUri, './a.shp|subset=H > 1');
  });
}
