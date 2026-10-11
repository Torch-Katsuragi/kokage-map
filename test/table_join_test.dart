// 表（座標の列が無い CSV）のノードと、レイヤへの結合（森林簿 CSV と計画図）。
// 結合の値は QGIS 4.2.2 が付けた値（test/fixtures/qgis_4_2_joins_expected.json、tool/qgis/write_join_fixture.py）と突き合わせる。
// 書き出しはホストの GDAL（無ければその分だけ skip）
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/layer_join.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/table_node.dart';
import 'package:root_maps/services/external/external_source.dart';
import 'package:root_maps/services/feature_search.dart';
import 'package:root_maps/services/import_export/import_export_service.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/table/csv_table.dart';
import 'package:root_maps/services/table/table_join.dart';
import 'package:root_maps/widgets/attribute_table/attribute_table_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/gdal_host.dart';
import 'support/join_fixture.dart';

void main() {
  final gdalConfig = findHostGdal();
  final skipGdal = gdalConfig == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null;

  group('CSV の表', () {
    test('UTF-8: 型の判定（整数・小数・文字）と引用符の中のカンマ', () {
      final table = CsvTable.parse(File('test/fixtures/joins/森林簿.csv').readAsBytesSync());
      expect(table.encoding, 'UTF-8');
      expect(table.fieldNames, ['林小班', '樹種', '林齢', '面積']);
      expect([for (final f in table.fields) f.type],
          [TableFieldType.text, TableFieldType.text, TableFieldType.integer, TableFieldType.real]);
      expect(table.rows[1], ['12-2', 'ヒノキ, 一部スギ', 30, 0.8]);
    });

    test('Shift_JIS（CP932）: UTF-8 として読めなければ CP932。NEC 特殊文字（①・Ⅱ）も', () {
      final table = CsvTable.parse(File('test/fixtures/joins/林班表.csv').readAsBytesSync());
      expect(table.encoding, 'CP932');
      expect(table.fieldNames, ['林班', '所有者', '地番']);
      expect(table.rows, [
        [12, '北山村', '①'],
        [13, '私有林', 'Ⅱ'],
      ]);
    });

    test('CP932 の IBM 拡張文字（髙・﨑）と半角カナ', () {
      // 0xFB 0xFC = 髙、0xFA 0xB1 = 﨑、0xB6 = ｶ
      expect(decodeCp932([0xFB, 0xFC, 0xFA, 0xB1, 0xB6, 0x41]), '髙﨑ｶA');
    });

    test('BOM つき UTF-8・改行の入った欄・空の欄は NULL・空行は飛ばす', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('a,b\r\n1,"x\ny"\r\n\r\n2,\r\n')]);
      final table = CsvTable.parse(bytes);
      expect(table.fieldNames, ['a', 'b']);
      expect(table.rows, [
        [1, 'x\ny'],
        [2, null],
      ]);
    });
  });

  group('結合の鍵', () {
    test('QGIS と同じく文字の形で比べる（整数 12 と "12"、12.0 と "12"）。NULL は当たらない', () {
      expect(joinKey(12), '12');
      expect(joinKey(12.0), '12');
      expect(joinKey(1.25), '1.25');
      expect(joinKey('12'), '12');
      expect(joinKey(null), isNull);
      expect(joinKey('１２ ', normalize: false), '１２ ');
      expect(joinKey('１２ ', normalize: true), '12');
      expect(joinKey('　Ａ-１', normalize: true), 'A-1');
    });

    test('1 万件 × 1 万行でも一瞬（表は 1 回だけ Map にする）', () {
      final rows = [for (var i = 0; i < 10000; i++) ['$i', 'スギ$i', i]];
      final csv = ['k,樹種,林齢', for (final r in rows) r.join(',')].join('\n');
      final table = CsvTable.parse(Uint8List.fromList(utf8.encode(csv)));
      final sw = Stopwatch()..start();
      final join = ResolvedJoin.build(const LayerJoin(table: 't.csv', joinField: 'k', targetField: 'k'), table)!;
      var hits = 0;
      for (var i = 0; i < 10000; i++) {
        if (join.valuesFor(i) != null) hits++;
      }
      sw.stop();
      expect(hits, 10000);
      expect(join.fieldNames, ['t_樹種', 't_林齢']);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('ツリーと結合', () {
    late Directory tmp;
    late String proj;

    setUpAll(() async {
      if (gdalConfig != null) {
        final gdal = GdalFfi(gdalConfig);
        await gdal.version();
        ExternalGdal.instance = gdal;
      }
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      KMetaService.instance.clearCache();
      TableCache.clear();
      tmp = await Directory.systemTemp.createTemp('table_join_');
      proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
      ProjectPathResolver.instance.setRootPathGetter(() => proj);
      await makeJoinProject(proj);
    });

    tearDown(() async {
      KMetaService.instance.clearCache();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<(FolderNode, LayerNode)> open() async {
      final root = FolderNode('Home', children: []);
      await root.updateChildren();
      final gpkg = root.children.whereType<GeoPackageNode>().single;
      await gpkg.updateChildren();
      addTearDown(gpkg.geoPackageFile.dispose);
      final layer = gpkg.children.whereType<LayerNode>().single;
      await layer.updateChildren();
      return (root, layer);
    }

    test('座標の列が無い CSV は表のノード（UTF-8 も CP932 も）', () async {
      final (root, _) = await open();
      final tables = root.children.whereType<TableNode>().toList();
      expect([for (final t in tables) t.name]..sort(), ['林班表.csv', '森林簿.csv']..sort());
      final rinpan = await tables.firstWhere((t) => t.name == '林班表.csv').load();
      expect(rinpan!.rows.first, [12, '北山村', '①']);
    });

    test('結合の値が QGIS 4.2.2 と同じ（接頭辞・列の選択・整数と文字の照合・当たらない行・NULL）', () async {
      await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', fixtureJoins);
      final (_, layer) = await open();
      final expected = jsonDecode(File('test/fixtures/qgis_4_2_joins_expected.json').readAsStringSync()) as Map;
      final joinedNames = [
        for (final f in expected['fields'] as List)
          if (!['fid', 'rinpan', 'shoban', 'key'].contains(f)) f as String,
      ];
      expect(layer.joinedFieldNames, joinedNames);
      final byKey = {for (final f in layer.features) f.turfFeature.properties!['shoban'] as String: f};
      for (final row in (expected['features'] as List).cast<Map>()) {
        final f = layer.features.firstWhere((f) =>
            f.turfFeature.properties!['shoban'] == row['shoban'] && f.turfFeature.properties!['rinpan'] == row['rinpan']);
        final props = layer.effectiveProperties(f.turfFeature.properties)!;
        for (final name in joinedNames) {
          expect(props[name], row[name], reason: '${row['key']} の $name');
        }
      }
      expect(byKey, isNotEmpty);
    });

    test('検索: 結合した列の値でも見つかる', () async {
      await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', fixtureJoins);
      final (_, layer) = await open();
      final r = await FeatureSearch.search([layer], '広葉樹');
      expect(r.hits, hasLength(1));
      expect(r.hits.single.column, '森林簿_樹種');
      expect(r.hits.single.feature.turfFeature.properties!['key'], '14-1');
    });

    // 列の表示メニューに結合した列の改名・削除が出て、押すと ALTER TABLE が「列が無い」で失敗していた（2026-10-11）
    testWidgets('属性表: 結合した列は改名・削除の対象にしない', (tester) async {
      late LayerNode layer;
      await tester.runAsync(() async {
        await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', fixtureJoins);
        (_, layer) = await open();
      });
      AttributeTableController? ctrl;
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            ctrl ??= AttributeTableController(layer, ref);
            return const SizedBox();
          }),
        ),
      ));
      await tester.runAsync(ctrl!.initialize);
      expect(ctrl!.isJoinedColumn('森林簿_樹種'), isTrue);
      expect(ctrl!.canAlterColumn('森林簿_樹種'), isFalse);
      expect(ctrl!.canAlterColumn('shoban'), isTrue);
    });

    test('表が無い・列が無い結合は黙って外す（設定は残す）', () async {
      await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', const [
        LayerJoin(table: '無い.csv', joinField: 'a', targetField: 'key'),
        LayerJoin(table: '森林簿.csv', joinField: '無い列', targetField: 'key'),
      ]);
      final (_, layer) = await open();
      expect(layer.joins, isEmpty);
      expect(layer.joinDefs, hasLength(2));
      expect(layer.effectiveProperties({'a': 1}), {'a': 1});
    });

    test('書き出し: 結合した列も書く（既定）。外せば書かない', () async {
      await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', fixtureJoins);
      final (_, layer) = await open();
      final dir = await Directory(p.join(tmp.path, 'out')).create();
      final out = p.join(dir.path, 'shoban.geojson');
      final result = await ImportExportService().exportLayer(layer, out, format: FileFormat.geojson);
      expect(result.success, isTrue, reason: result.errorMessage);
      final json = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
      final props = [for (final f in json['features'] as List) (f as Map)['properties'] as Map];
      expect(props, hasLength(5));
      final first = props.firstWhere((p) => p['key'] == '12-1');
      expect(first['森林簿_樹種'], 'スギ');
      expect(first['森林簿_林齢'], 45);
      expect(first['林班_所有者'], '北山村');
      expect(first['林班_地番'], '①');
      final none = props.firstWhere((p) => p['key'] == '13-1');
      expect(none['森林簿_樹種'], isNull);
      expect(none['林班_所有者'], '私有林');

      final out2 = p.join(dir.path, 'shoban2.geojson');
      final r2 = await ImportExportService().exportLayer(layer, out2,
          format: FileFormat.geojson, options: const ExportOptions(includeJoinedFields: false));
      expect(r2.success, isTrue, reason: r2.errorMessage);
      final p2 = ((jsonDecode(File(out2).readAsStringSync()) as Map)['features'] as List).first as Map;
      expect((p2['properties'] as Map).keys.where((k) => '$k'.contains('_')), isEmpty);
    }, skip: skipGdal);

    test('書き出し（GeoPackage）: 結合の数の列は数のまま、行番号とも並ぶ', () async {
      await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', fixtureJoins);
      final (_, layer) = await open();
      final dir = await Directory(p.join(tmp.path, 'out_shp')).create();
      final out = p.join(dir.path, 'shoban.gpkg');
      final result = await ImportExportService().exportLayer(layer, out,
          format: FileFormat.geopackage, options: const ExportOptions(includeRowNumber: true));
      expect(result.success, isTrue, reason: result.errorMessage);
      final info = await ExternalGdal.instance.vectorInfo(out, args: const ['-features']);
      final layerInfo = (info['layers'] as List).first as Map;
      final fields = {for (final f in layerInfo['fields'] as List) (f as Map)['name']: f['type']};
      expect(fields['ROW_NUM'], isNotNull);
      expect(fields['森林簿_樹種'], 'String');
      final feats = (layerInfo['features'] as List).cast<Map>();
      final ages = [for (final f in feats) (f['properties'] as Map)['森林簿_林齢']];
      expect(ages, [45, 30, null, 60, null]);
    }, skip: skipGdal);
  });
}
