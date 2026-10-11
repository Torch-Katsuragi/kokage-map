// 地図の検索: 表記ゆれの正規化・LIKE の形・実物の GeoPackage（1 万件）での横断検索
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/feature_search.dart';
import 'package:root_maps/widgets/feature_search_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('SearchText.normalize', () {
    test('全角英数は半角・小文字に', () {
      expect(SearchText.normalize('１２'), '12');
      expect(SearchText.normalize('ＡＢｃ　１'), 'abc 1');
      expect(SearchText.normalize(' Sugi '), 'sugi');
    });
    test('半角カナは全角（濁点・半濁点をまとめる）、ひらがなはカタカナ', () {
      expect(SearchText.normalize('ｽｷﾞ'), 'スギ');
      expect(SearchText.normalize('ﾋﾟﾝ'), 'ピン');
      expect(SearchText.normalize('ｳﾞ'), 'ヴ');
      expect(SearchText.normalize('ｯｰ'), 'ッー');
      expect(SearchText.normalize('ひのき'), 'ヒノキ');
      expect(SearchText.normalize('林班'), '林班');
    });
    test('半角カナと全角カナの表が揃っている', () {
      expect(SearchText.toHalfKana('スギ・ヒノキ・パルプ・ヴ'), 'ｽｷﾞ･ﾋﾉｷ･ﾊﾟﾙﾌﾟ･ｳﾞ');
      expect(SearchText.normalize(SearchText.toHalfKana('アイウエオカガサザタダナハバパマヤラワン')), 'アイウエオカガサザタダナハバパマヤラワン');
    });
  });

  group('SearchText.variants', () {
    test('数字は半角と全角', () {
      expect(SearchText.variants('12').toSet(), {'12', '１２'});
      expect(SearchText.variants('１２').toSet(), {'１２', '12'});
    });
    test('かなはひらがな・カタカナ・半角カナ', () {
      expect(SearchText.variants('すぎ').toSet(), containsAll(['すぎ', 'スギ', 'ｽｷﾞ']));
    });
    test('英字は大文字・小文字の全角も', () {
      expect(SearchText.variants('ab').toSet(), containsAll(['ab', 'AB', 'ａｂ', 'ＡＢ']));
    });
    test('空白だけなら探さない', () {
      expect(SearchText.variants('  '), isEmpty);
    });
  });

  test('rankOf: 一致 → 前方一致 → 部分一致', () {
    expect(FeatureSearch.rankOf('１２', '12'), 0);
    expect(FeatureSearch.rankOf(12, '12'), 0);
    expect(FeatureSearch.rankOf('12-3', '12'), 1);
    expect(FeatureSearch.rankOf('112', '12'), 2);
    expect(FeatureSearch.rankOf('13', '12'), isNull);
    expect(FeatureSearch.rankOf(null, '12'), isNull);
  });

  group('GeoPackage で横断検索', () {
    late Directory tmp;
    late GeoPackageFile gpkg;
    late PolygonLayerNode layer;
    const n = 10000;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tmp = await Directory.systemTemp.createTemp('feature_search_');
      gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
      await gpkg.addLayer('rinpan', GeometryType.polygon);
      await gpkg.addAttributeColumns('rinpan', {'name': 'TEXT', 'rinpan': 'TEXT', 'jushu': 'TEXT', 'no': 'INTEGER'});
      const ring = [LatLng(33.93, 135.96), LatLng(33.93, 135.97), LatLng(33.94, 135.97), LatLng(33.93, 135.96)];
      // 1 件ずつ足すと遅いので、1 件足してから行を複製する
      await gpkg.addPolygonWithAttributes('rinpan', [ring], {'name': 'r0', 'rinpan': '0', 'jushu': 'スギ', 'no': 0});
      final db = await gpkg.getDatabase();
      final geom = (await db.rawQuery('SELECT geom FROM rinpan LIMIT 1')).first['geom'];
      final batch = db.batch();
      for (var i = 1; i < n; i++) {
        batch.insert('rinpan', {
          'geom': geom,
          'name': 'r$i',
          // 林班番号は全角で書かれていることがある
          'rinpan': i.isEven ? '$i' : SearchText.toFullWidthAscii('$i'),
          'jushu': i % 3 == 0 ? 'ﾋﾉｷ' : 'スギ',
          'no': i,
        });
      }
      await batch.commit(noResult: true);
      layer = PolygonLayerNode(gpkg, 'rinpan', parent: GeoPackageNode(gpkg));
      await layer.updateChildren();
    });

    tearDownAll(() async {
      await gpkg.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('半角で打っても全角の林班番号に当たり、一致が先頭に来る', () async {
      final r = await FeatureSearch.search([layer], '13');
      expect(r.hits, isNotEmpty);
      final first = r.hits.first;
      expect(first.rank, 0);
      expect(first.feature.rowId, isNotNull);
      expect(first.value, anyOf('１３', '13'));
      // 13 は奇数なので全角で入っている
      expect(r.hits.where((h) => h.rank == 0).map((h) => h.value), contains('１３'));
      // 113・1300 なども部分一致・前方一致で並ぶ
      expect(r.hits.map((h) => h.rank), orderedEquals([...r.hits.map((h) => h.rank)]..sort()));
    });

    test('ひらがなで半角カナの樹種に当たる・件数の上限', () async {
      final sw = Stopwatch()..start();
      final r = await FeatureSearch.search([layer], 'ひのき', limit: 50);
      sw.stop();
      expect(r.hits, hasLength(50));
      expect(r.truncated, isTrue);
      expect(r.hits.first.column, 'jushu');
      // 1 万件でも全行を読まない（上限で打ち切る）。ホストでは数十 ms
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });

    test('一致は上限の外に落ちない（部分一致がたくさん先にあっても）', () async {
      // 「9999」より前に「99」を含む行は 100 件以上ある
      final r = await FeatureSearch.search([layer], '9999', perLayer: 5);
      expect(r.hits.first.rank, 0);
      expect(r.hits.first.feature.rowId, isNotNull);
      expect(SearchText.normalize(r.hits.first.value), '9999');
    });

    test('% や _ は文字として探す', () async {
      expect((await FeatureSearch.search([layer], '%')).hits, isEmpty);
      expect((await FeatureSearch.search([layer], '_')).hits, isEmpty);
    });

    testWidgets('検索の窓: 打つと一覧が出て、押すとその地物を返す', (tester) async {
      FeatureNode? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showDialog<FeatureNode>(
              context: context,
              builder: (_) => FeatureSearchDialog(layers: [layer]),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '９９９９');
      // 手が止まってから探す（250 ms）
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        // 問い合わせ（sqflite の ffi）が返るまで待つ
        for (var i = 0; i < 50 && find.byType(ListTile).evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      await tester.pump();
      expect(find.byType(ListTile), findsWidgets);
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(picked!.parent, same(layer));
    });

    // メタデータの列の除外が完全一致で、旧名・大文字の列では JSON が検索に当たっていた（2026-10-11）
    test('メタデータの列は旧名・大文字でも見ない', () async {
      final g = GeoPackageFile(const ['m.gpkg'], absolutePath: '${tmp.path}/m.gpkg');
      addTearDown(g.dispose);
      await g.addLayer('pts', GeometryType.point);
      await g.addAttributeColumns('pts', {'name': 'TEXT', 'RMAPS_METADATA': 'TEXT', 'KMAPS_METADATA': 'TEXT'});
      await g.addPointWithAttributes(
          'pts', const LatLng(33.9, 135.9), {'name': 'a', 'RMAPS_METADATA': '{"gnss":"rtk"}', 'KMAPS_METADATA': '{"gnss":"rtk"}'});
      expect(await g.searchAttributeRows('pts', ['gnss']), isEmpty);
      expect(await g.searchAttributeRows('pts', ['a']), hasLength(1));
    });

    test('当たらなければ空', () async {
      final r = await FeatureSearch.search([layer], '存在しない値');
      expect(r.hits, isEmpty);
      expect(r.truncated, isFalse);
    });
  });
}
