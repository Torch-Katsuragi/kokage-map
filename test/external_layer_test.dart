// gpkg 以外の形式を読み取り専用レイヤとして開く（読み手・キャッシュ・ノード・変換）
// 設計は docs/technical/external-formats.md
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart' as charset;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/external_layer_node.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/providers/selection_providers.dart';
import 'package:root_maps/services/coordinate/epsg_registry.dart';
import 'package:root_maps/services/external/external_layer_cache.dart';
import 'package:root_maps/services/external/external_layer_converter.dart';
import 'package:root_maps/services/external/external_readers.dart';
import 'package:root_maps/services/external/readers/geojson_reader.dart';
import 'package:root_maps/services/external/readers/shapefile_reader.dart';
import 'package:root_maps/services/import_export/exporters/shapefile_writer.dart';
import 'package:root_maps/services/import_export/parsers/shapefile_binary_parser.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late String proj;

  setUpAll(() {
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
  void writePoints(String base, {String? prj, bool cpg = true, String ext = '.dbf'}) {
    final r = encodeShpShx(ShapeType.point, [
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
          [135.99, 33.93],
        ],
      ],
    ]);
    File('$base.shp').writeAsBytesSync(r.shp);
    File('$base.shx').writeAsBytesSync(r.shx);
    File('$base$ext').writeAsBytesSync(
      encodeDbf([
        {'NAME': 'sugi', 'H': 21.5},
        {'NAME': 'hinoki', 'H': 18.0},
        {'NAME': 'matsu', 'H': 9.5},
      ], now: DateTime(2026, 10, 9)),
    );
    if (prj != null) File('$base.prj').writeAsStringSync(EpsgRegistry.instance.getWktString(prj)!);
    if (cpg) File('$base.cpg').writeAsStringSync('CP932');
  }

  Map<String, Object?> feature(Map<String, Object?> geometry, Map<String, Object?> props) => {'type': 'Feature', 'properties': props, 'geometry': geometry};

  void writeGeoJson(String path, List<Map<String, Object?>> features) => File(path).writeAsStringSync(jsonEncode({'type': 'FeatureCollection', 'features': features}));

  group('読み手', () {
    test('拡張子で読み手を引く（大文字も）。付属ファイルは大文字小文字を問わず拾う', () async {
      expect(externalReaderFor('a/林班.SHP'), isA<ShapefileReader>());
      expect(externalReaderFor('a.geojson'), isA<GeoJsonReader>());
      expect(externalReaderFor('a.json'), isA<GeoJsonReader>());
      expect(externalReaderFor('a.gpkg'), isNull);
      expect(externalReaderFor('a.dbf'), isNull, reason: '付属ファイルは単独でレイヤにしない');

      final base = p.join(proj, 'rinpan');
      writePoints(base, ext: '.DBF');
      File('$base.shp.xml').writeAsStringSync('<x/>');
      File(p.join(proj, 'rinpan2.dbf')).writeAsStringSync('');
      final sidecars = (await existingSidecars('$base.shp', ShapefileReader())).map(p.basename).toList();
      expect(sidecars, unorderedEquals(['rinpan.shx', 'rinpan.DBF', 'rinpan.cpg', 'rinpan.shp.xml']));
    });

    test('shp: 点と属性・列の型・レイヤ名はファイル名', () async {
      final base = p.join(proj, 'trees');
      writePoints(base, prj: 'EPSG:4326');
      final ds = (await ShapefileReader().read('$base.shp')).single;
      expect(ds.layerName, 'trees');
      expect(ds.geometryType, GeometryType.point);
      expect(ds.columns, {'NAME': 'TEXT', 'H': 'REAL'});
      expect(ds.features.map((f) => f['NAME']), ['sugi', 'hinoki', 'matsu']);
      expect(ds.features.first['point'], const LatLng(33.91, 135.97));
    });

    test('shp: .cpg が無ければ Shift_JIS で読む（日本語の属性）', () async {
      final base = p.join(proj, 'jp');
      final r = encodeShpShx(ShapeType.point, [
        [
          [
            [135.0, 33.0],
          ],
        ],
      ]);
      File('$base.shp').writeAsBytesSync(r.shp);
      File('$base.dbf').writeAsBytesSync(
        encodeDbf([
          {'NAME': '杉'},
        ]),
      );
      final ds = (await ShapefileReader().read('$base.shp')).single;
      expect(ds.features.single['NAME'], '杉');
      expect(charset.shiftJis.decode(charset.shiftJis.encode('杉')), '杉');
    });

    test('shp: 平面直角座標系（.prj）は WGS84 に直す', () async {
      final base = p.join(proj, 'plane');
      final r = encodeShpShx(ShapeType.point, [
        [
          [
            [0.0, 0.0],
          ],
        ],
      ]);
      File('$base.shp').writeAsBytesSync(r.shp);
      File('$base.prj').writeAsStringSync(EpsgRegistry.instance.getWktString('EPSG:6674')!);
      final ds = (await ShapefileReader().read('$base.shp')).single;
      final pt = ds.features.single['point'] as LatLng;
      // VI 系の原点は北緯 36 度・東経 136 度
      expect(pt.latitude, closeTo(36.0, 1e-6));
      expect(pt.longitude, closeTo(136.0, 1e-6));
    });

    test('shp: Z 付きの線（PolyLineZ）は XY だけ読み、次のレコードもずれない', () async {
      // レコード: 型 13・範囲・部分 1・点 2・XY・Z 範囲と Z・M 範囲と M
      Uint8List polyLineZ(List<List<double>> pts) {
        final n = pts.length;
        final d = ByteData(4 + 32 + 8 + 4 + 16 * n + 16 + 8 * n + 16 + 8 * n);
        var o = 0;
        d.setInt32(o, 13, Endian.little);
        o += 4 + 32;
        d.setInt32(o, 1, Endian.little);
        d.setInt32(o + 4, n, Endian.little);
        o += 8;
        d.setInt32(o, 0, Endian.little);
        o += 4;
        for (final pt in pts) {
          d.setFloat64(o, pt[0], Endian.little);
          d.setFloat64(o + 8, pt[1], Endian.little);
          o += 16;
        }
        // Z・M は 99 で埋める（XY と間違えて読むと範囲外になる）
        while (o < d.lengthInBytes) {
          d.setFloat64(o, 99999.0, Endian.little);
          o += 8;
        }
        return d.buffer.asUint8List();
      }

      final records = [
        polyLineZ([
          [135.0, 33.0],
          [135.1, 33.1],
        ]),
        polyLineZ([
          [136.0, 34.0],
          [136.1, 34.1],
          [136.2, 34.2],
        ]),
      ];
      final out = BytesBuilder();
      final header = ByteData(100)
        ..setInt32(0, 9994, Endian.big)
        ..setInt32(28, 1000, Endian.little)
        ..setInt32(32, 13, Endian.little);
      final total = 100 + records.fold<int>(0, (s, r) => s + 8 + r.length);
      header.setInt32(24, total ~/ 2, Endian.big);
      out.add(header.buffer.asUint8List());
      for (var i = 0; i < records.length; i++) {
        final rh = ByteData(8)
          ..setInt32(0, i + 1, Endian.big)
          ..setInt32(4, records[i].length ~/ 2, Endian.big);
        out
          ..add(rh.buffer.asUint8List())
          ..add(records[i]);
      }
      final base = p.join(proj, 'z');
      File('$base.shp').writeAsBytesSync(out.takeBytes());
      final ds = (await ShapefileReader().read('$base.shp')).single;
      expect(ds.geometryType, GeometryType.linestring);
      expect(ds.features.length, 2);
      expect((ds.features[1]['line'] as List<LatLng>).length, 3);
      expect((ds.features[1]['line'] as List<LatLng>).last, const LatLng(34.2, 136.2));
    });

    test('GeoJSON: 型が混ざれば <名前>_point / _line / _polygon に分ける', () async {
      final path = p.join(proj, 'mixed.geojson');
      writeGeoJson(path, [
        feature(
          {
            'type': 'Point',
            'coordinates': [135.0, 33.0],
          },
          {'name': 'a', 'n': 1, 'ok': true},
        ),
        feature(
          {
            'type': 'LineString',
            'coordinates': [
              [135.0, 33.0],
              [135.1, 33.1],
            ],
          },
          {'name': 'l'},
        ),
        feature(
          {
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
          {
            'name': 'p',
            'nested': {'k': 1},
          },
        ),
        feature(
          {
            'type': 'Point',
            'coordinates': [135.2, 33.2],
          },
          {'name': null, 'n': 2},
        ),
      ]);
      final datasets = await GeoJsonReader().read(path);
      expect(datasets.map((d) => d.layerName), ['mixed_point', 'mixed_line', 'mixed_polygon']);
      final points = datasets.first;
      expect(points.features.length, 2);
      expect(points.columns, {'name': 'TEXT', 'n': 'REAL', 'ok': 'INTEGER'});
      expect(datasets[2].features.single['nested'], '{"k":1}');
    });

    test('GeoJSON: .json は中身が FeatureCollection / Feature のときだけ', () async {
      final fc = p.join(proj, 'fc.json');
      writeGeoJson(fc, [
        feature({
          'type': 'Point',
          'coordinates': [135.0, 33.0],
        }, {}),
      ]);
      final single = p.join(proj, 'single.json');
      File(single).writeAsStringSync(
        jsonEncode(
          feature(
            {
              'type': 'Point',
              'coordinates': [135.0, 33.0],
            },
            {'a': 'b'},
          ),
        ),
      );
      final config = p.join(proj, 'settings.json');
      File(config).writeAsStringSync(jsonEncode({'type': 'config', 'value': 1}));
      final broken = p.join(proj, 'broken.json');
      File(broken).writeAsStringSync('{');
      expect(await acceptingExternalReader(fc), isA<GeoJsonReader>());
      expect(await acceptingExternalReader(single), isA<GeoJsonReader>());
      expect(await acceptingExternalReader(config), isNull);
      expect(await acceptingExternalReader(broken), isNull);
      expect((await GeoJsonReader().read(single)).single.layerName, 'single');
    });
  });

  group('ノードとキャッシュ', () {
    Future<FolderNode> openRoot() async {
      final root = FolderNode('Home', children: []);
      await root.updateChildren();
      for (final child in root.children.whereType<GeoPackageNode>()) {
        await child.updateChildren();
      }
      return root;
    }

    test('shp・GeoJSON はノードになり、付属ファイルや GeoJSON でない .json はならない', () async {
      writePoints(p.join(proj, '林班'));
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
    });

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
      expect(await ExternalLayerCache.ensure(cache, path, node.reader), isFalse, reason: '同じ印なら作り直さない');

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
      expect(await ExternalLayerCache.ensure(cache, path, node.reader), isFalse);
    });

    test('ツリーの読み直しで外れても元は消さない。利用者の削除で元・付属・キャッシュを消す', () async {
      final base = p.join(proj, 'trees');
      writePoints(base);
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
    });
  });

  group('編集の門番', () {
    test('選んだ地物をまとめて消しても、読み取り専用レイヤの地物は消さず「gpkg に変換して編集」を知らせる', () async {
      writePoints(p.join(proj, 'trees'));
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
    });
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
      writePoints(base, prj: 'EPSG:4326');
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
    });

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
    });

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
    });

    test('自分のフォルダへ gpkg として複製（元は残す）', () async {
      writePoints(p.join(proj, 'trees'));
      final mine = await Directory(p.join(proj, 'mine')).create();
      final (root, node) = await open('trees.shp');
      final target = root.children.whereType<FolderNode>().single;
      final result = await ExternalLayerConverter.copyAsGeoPackage(node, target);
      expect(result.outcome, ExternalConvertOutcome.copied);
      expect(result.gpkgPath, p.join(mine.path, 'trees.gpkg'));
      expect(File(p.join(proj, 'trees.shp')).existsSync(), isTrue);
      expect(target.children.whereType<GeoPackageNode>().single.name, 'trees.gpkg');
    });
  });
}
