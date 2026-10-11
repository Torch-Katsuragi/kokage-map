// View / レイヤのスタイルが「どのフィーチャに効くか」のテスト
//
// 地図に出るかどうかは目で見るしかないが、**どのフィーチャがどのスタイルに
// 割り当てられるか**はここで固定できる。段4b の要はここ。
//
// 実物の GeoPackage を使う（メモリDBだと `getFeatureIds` の主キー解決を通せない）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_scene.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/view_node.dart';
import 'package:root_maps/models/qgis_renderer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:turf/turf.dart' as turf;

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  late PointLayerNode layer;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('view_style_');
    final path = '${tmp.path}/t.gpkg';
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: path);
    await gpkg.addLayer('chiten', GeometryType.point);
    await gpkg.addAttributeColumns('chiten', {'area': 'REAL'});

    final db = await gpkg.getDatabase();
    // fid 1..12、area は 100..111（>105 は 6件）。
    // geom は NOT NULL なので、GeoPackage のヘッダ + WKB Point を入れる。
    for (var i = 0; i < 12; i++) {
      await db.insert('chiten', {
        'geom': _gpkgPoint(139.76 + i * 0.001, 35.68),
        'area': 100.0 + i,
      });
    }

    // `layerKey` は GeoPackageNode の親を辿るので、ツリーを最小限だけ組む
    final gpkgNode = GeoPackageNode(gpkg);
    layer = PointLayerNode(gpkg, 'chiten', parent: gpkgNode);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 描画のスタイルキー（gpkg のパス | viewKey）
  String key(String view) => '${gpkg.getAbsolutePath()}|t.gpkg/chiten/$view';

  /// `_featureMap` に rowId を流し込む（DB読み込みの代わり）
  void seedFeatures() {
    for (var fid = 1; fid <= 12; fid++) {
      layer.addFeatureToMap(
        fid,
        turf.Feature<turf.Point>(
          geometry: turf.Point(coordinates: turf.Position(139.76, 35.68)),
        ),
      );
    }
  }

  test('フィルタ付きViewは、当てはまるフィーチャだけを受け持つ', () async {
    seedFeatures();
    layer.views.addAll([
      ViewNode(
        name: '大きい',
        parent: layer,
        filter: 'area > 105',
        style: const KMetaLayerStyle(pointSize: 25),
      ),
    ]);

    await layer.refreshStyleGroups();

    expect(layer.styleGroups.keys, [key('大きい')]);
    // area 106..111 = fid 7..12
    final assigned =
        layer.styleKeyByRowId.keys.toList()..sort();
    expect(assigned, [7, 8, 9, 10, 11, 12]);
    expect(layer.styleKeyOf(7), key('大きい'));
    expect(layer.styleKeyOf(1), '', reason: '当てはまらないフィーチャは既定スタイル');
  });

  test('フィルタ無しのViewは残り全部を受け持つ', () async {
    seedFeatures();
    layer.views.addAll([
      ViewNode(
        name: '大きい',
        parent: layer,
        filter: 'area > 105',
        style: const KMetaLayerStyle(pointSize: 25),
      ),
      ViewNode(
        name: 'その他',
        parent: layer,
        style: const KMetaLayerStyle(pointSize: 5),
      ),
    ]);

    await layer.refreshStyleGroups();

    expect(layer.styleGroups.length, 2);
    expect(layer.styleKeyByRowId.length, 12, reason: '全フィーチャがどれかに属する');
    // 上にある View が勝つ
    expect(layer.styleKeyOf(12), key('大きい'));
    expect(layer.styleKeyOf(1), key('その他'));
  });

  // 別の dir にある同名の gpkg・レイヤ（dir を複製したとき等）は、地図全体で別のスタイルとして描く。
  // 以前はキーに dir が入らず1つに畳まれ、片方の色で両方描いていた（2026-09-30）
  test('別の dir の同名 gpkg・レイヤはスタイルのキーが別になる', () async {
    await Directory('${tmp.path}/sub').create();
    final other = GeoPackageFile(const ['sub', 't.gpkg'], absolutePath: '${tmp.path}/sub/t.gpkg');
    await other.addLayer('chiten', GeometryType.point);
    final otherLayer = PointLayerNode(other, 'chiten', parent: GeoPackageNode(other));
    try {
      for (final l in [layer, otherLayer]) {
        l.addFeatureToMap(1, turf.Feature<turf.Point>(geometry: turf.Point(coordinates: turf.Position(139.76, 35.68))));
        l.views.add(ViewNode(name: '既定', parent: l, style: const KMetaLayerStyle(pointSize: 9)));
        await l.refreshStyleGroups();
      }
      expect(layer.styleKeyOf(1), isNot(otherLayer.styleKeyOf(1)));
    } finally {
      await other.dispose();
    }
  });

  test('取り直しの後に足した地物は、フィルタ無しの View のスタイル', () async {
    seedFeatures();
    layer.views.add(ViewNode(name: 'その他', parent: layer, style: const KMetaLayerStyle(pointSize: 5)));
    await layer.refreshStyleGroups();
    // 描いて足した地物（まだ取り直していない）
    expect(layer.styleKeyOf(99), key('その他'));
  });

  test('Viewにスタイルが無ければレイヤのスタイルに落ちる', () async {
    seedFeatures();
    // レイヤのスタイルをキャッシュに直接入れる（.kmeta.json 経由の代用）
    layer.views.add(ViewNode(name: '既定', parent: layer));

    await layer.refreshStyleGroups();
    expect(layer.styleGroups, isEmpty,
        reason: 'レイヤにもスタイルが無ければグループを作らない＝View導入前と同じ描画');
  });

  test('消灯したViewは受け持たない', () async {
    seedFeatures();
    layer.views.addAll([
      ViewNode(
        name: '大きい',
        parent: layer,
        filter: 'area > 105',
        style: const KMetaLayerStyle(pointSize: 25),
        visible: false,
      ),
    ]);

    await layer.refreshStyleGroups();
    expect(layer.styleGroups, isEmpty);
    expect(layer.styleKeyByRowId, isEmpty);
  });

  test('スタイル指定が1つも無ければ何も割り当てない', () async {
    seedFeatures();
    layer.views.add(ViewNode(name: '既定', parent: layer));
    await layer.refreshStyleGroups();
    expect(layer.styleGroups, isEmpty);
    expect(layer.styleKeyByRowId, isEmpty,
        reason: 'グループが無いのにキーだけ残ると、フィーチャに無駄な属性が載る');
  });


  // QGIS の分類のレンダラを持つ View は、地物の属性で色を分ける（.qgs の描き分けの再現。2026-10-11）
  group('QGIS の描き分け', () {
    const sugi = Color(0xFF33A02C);
    const hinoki = Color(0xFF1F78B4);
    const other = Color(0xFF969696);
    final categorized = QgisRenderer(
      kind: QgisRendererKind.categorized,
      attr: '樹種',
      classes: const [
        QgisRendererClass(label: 'スギ', values: ['スギ'], style: KMetaLayerStyle(pointColor: sugi)),
        QgisRendererClass(label: 'ヒノキ', values: ['ヒノキ'], style: KMetaLayerStyle(pointColor: hinoki, pointSize: 9)),
        QgisRendererClass(label: 'マツ', values: ['マツ'], render: false, style: KMetaLayerStyle(pointColor: Color(0xFFFF0000))),
        QgisRendererClass(label: 'その他', style: KMetaLayerStyle(pointColor: other)),
      ],
    );
    const species = ['スギ', 'ヒノキ', 'マツ', '広葉樹'];

    void seedSpecies() {
      for (var fid = 1; fid <= 12; fid++) {
        layer.addFeatureToMap(
          fid,
          turf.Feature<turf.Point>(
            geometry: turf.Point(coordinates: turf.Position(135.965 + fid * 0.0003, 33.927)),
            properties: {'樹種': species[(fid - 1) % 4]},
          ),
        );
      }
    }

    test('分類ごとに別のスタイルグループに振り分け、描かない分類は隠す', () async {
      seedSpecies();
      layer.views.add(ViewNode(
        name: '既定',
        parent: layer,
        style: KMetaLayerStyle(pointColor: sugi, qgisRenderer: 'categorizedSymbol', qgisRendererDef: categorized),
      ));
      await layer.refreshStyleGroups();

      final base = key('既定');
      expect(layer.styleKeyOf(1), '$base#0');
      expect(layer.styleKeyOf(2), '$base#1');
      expect(layer.styleKeyOf(4), '$base#3', reason: '広葉樹は「その他」');
      expect(layer.rendererHiddenRowIds, {3, 7, 11}, reason: 'マツはチェックを外してある');
      expect(layer.styleGroups['$base#1']!.pointColor, hinoki);
      expect(layer.styleGroups['$base#1']!.pointSize, 9);
      expect(layer.styleGroupRank('$base#1'), layer.styleGroupRank(base), reason: '同じ View の中は並べ替えない');

      // 属性を直したら、その地物だけ選び直す
      layer.updateFeatureAttribute(3, '樹種', 'ヒノキ');
      expect(layer.styleKeyOf(3), '$base#1');
      expect(layer.rendererHiddenRowIds, isNot(contains(3)));
      layer.updateFeatureAttribute(1, '樹種', 'マツ');
      expect(layer.rendererHiddenRowIds, contains(1));

      // 3D の地図面（TerrainSceneBuilder）に流すと、分類ごとに別の色の点になる
      const lon0 = 135.965;
      const lat0 = 33.925;
      final originX = WebMercator.xFromLon(lon0);
      final originY = WebMercator.yFromLat(lat0);
      final dem = DemGrid(
        cols: 101,
        rows: 101,
        originX: originX,
        originY: originY,
        cellSize: 10,
        heights: Float32List(101 * 101),
      );
      final mesh = TerrainMesh.build(
        dem,
        TerrainCamera(centerX: originX + 500, centerY: originY + 500, scale: 1),
        textureWidth: 4,
        textureHeight: 4,
        chunkSize: 25,
      );
      final builder = TerrainSceneBuilder(
        mesh: mesh,
        stylesByKey: {
          for (final MapEntry(:key, :value) in layer.styleGroups.entries)
            key: TerrainFeatureStyle(
              lineColor: TerrainFeatureStyle.fallback.lineColor,
              lineWidth: 1,
              fillColor: TerrainFeatureStyle.fallback.fillColor,
              outlineColor: TerrainFeatureStyle.fallback.outlineColor,
              outlineWidth: 1,
              pointColor: value.pointColor!,
              pointSize: value.pointSize ?? 6,
            ),
        },
      );
      final scene = builder.build(points: [
        for (var fid = 2; fid <= 12; fid++)
          if (!layer.rendererHiddenRowIds.contains(fid))
            geo.Feature<geo.Point>(
              geometry: geo.Point(geo.Geographic(lon: lon0 + fid * 0.0003, lat: lat0 + 0.002)),
              properties: {'k-style': layer.styleKeyOf(fid)},
            ),
      ]);
      expect(scene.points.map((p) => p.color).toSet(), {sugi, hinoki, other});
      expect(scene.points, hasLength(9), reason: 'マツの 2 件（7, 11）は描かない。3 は直してヒノキ');
    });

    test('1 万件の振り分け（地物の読み込み・スタイル変更のたびに 1 回）', () async {
      for (var fid = 1; fid <= 10000; fid++) {
        layer.addFeatureToMap(
          fid,
          turf.Feature<turf.Point>(
            geometry: turf.Point(coordinates: turf.Position(135.965, 33.927)),
            properties: {'樹種': species[fid % 4], '林齢': fid % 90},
          ),
        );
      }
      layer.views.add(ViewNode(
        name: '既定',
        parent: layer,
        style: KMetaLayerStyle(qgisRenderer: 'categorizedSymbol', qgisRendererDef: categorized),
      ));
      final sw = Stopwatch()..start();
      await layer.refreshStyleGroups();
      // ignore: avoid_print
      print('refreshStyleGroups 1 万件: ${sw.elapsedMilliseconds}ms');
      expect(layer.styleKeyByRowId.length + layer.rendererHiddenRowIds.length, 10000);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('式が読めない描き分けは代表の色（View のスタイル）で全部描く', () async {
      seedSpecies();
      final broken = QgisRenderer(
        kind: QgisRendererKind.rule,
        classes: const [QgisRendererClass(label: 'x', style: KMetaLayerStyle(pointColor: hinoki))],
        rules: const [QgisRule(filter: r'$area > 1', classIndex: 0)],
      );
      layer.views.add(ViewNode(
        name: '既定',
        parent: layer,
        style: KMetaLayerStyle(pointColor: sugi, qgisRenderer: 'RuleRenderer', qgisRendererDef: broken),
      ));
      await layer.refreshStyleGroups();
      expect(layer.styleKeyByRowId.values.toSet(), {key('既定')});
      expect(layer.rendererHiddenRowIds, isEmpty);
    });
  });
}

/// GeoPackage のジオメトリBLOB（ヘッダ + WKB Point）
Uint8List _gpkgPoint(double lon, double lat) {
  final header = BytesBuilder()
    ..add(const [0x47, 0x50, 0x00, 0x01]) // 'GP', version 0, flags: little-endian
    ..add(Uint8List(4)..buffer.asByteData().setInt32(0, 4326, Endian.little));
  final wkb = ByteData(21)
    ..setUint8(0, 1) // little-endian
    ..setUint32(1, 1, Endian.little) // Point
    ..setFloat64(5, lon, Endian.little)
    ..setFloat64(13, lat, Endian.little);
  return Uint8List.fromList([...header.toBytes(), ...wkb.buffer.asUint8List()]);
}

