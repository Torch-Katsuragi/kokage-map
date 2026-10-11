// ペン・GPS 測量の描きかけ（GlobalDrawingState）: 1 点戻す・確定・自動保存と、その続きの追記
//
// 実物の GeoPackage を使う（feature_node_create_update_test.dart と同じ作り）。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/drawing_provider.dart';
import 'package:root_maps/providers/selection_providers.dart';
import 'package:root_maps/utils/global_drawing_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  late GeoPackageNode gpkgNode;
  late ProviderContainer container;
  late GlobalDrawingState state;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('drawing_state_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    gpkgNode = GeoPackageNode(gpkg);
    container = ProviderContainer();
    state = container.read(drawingStateProvider)..clearAll();
  });

  tearDown(() async {
    state.clearAll();
    container.dispose();
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  const a = LatLng(34.0, 135.0);
  const b = LatLng(34.001, 135.001);
  const c = LatLng(34.002, 135.0);
  const d = LatLng(34.003, 135.002);

  List<LatLng> closeRing(List<LatLng> pts) => [...pts, pts.first];

  group('描きかけ', () {
    test('線と面は別々に持ち、1 点戻すは最後の点と付帯情報だけ外す', () {
      state.addPoint(a, {'accuracy': 0.02}, isLine: true);
      state.addPoint(b, null, isLine: true);
      state.addPoint(c, null, isLine: false);
      expect(state.drawingLine, [a, b]);
      expect(state.drawingPolygon, [c]);
      expect(state.isDrawing, isTrue);

      state.undo(isLine: true);
      expect(state.drawingLine, [a]);
      expect(state.lineMetadata, [
        {'accuracy': 0.02},
      ]);
      expect(state.drawingPolygon, [c], reason: '面は触らない');

      state.undo(isLine: true);
      state.undo(isLine: true); // 点が無くても落ちない
      expect(state.isLineDrawing, isFalse);
      expect(state.isPolygonDrawing, isTrue);
    });

    test('外に渡した点列はあとから変わらない', () {
      state.addPoint(a, null, isLine: true);
      final before = state.drawingLine;
      state.addPoint(b, null, isLine: true);
      expect(before, [a]);
      expect(state.drawingLine, [a, b]);
      expect(() => before.add(c), throwsUnsupportedError);
    });

    test('ペンの点は座標だけの記録、GPS の点はその値', () {
      state.addPoint(a, {'latitude': 34.0, 'longitude': 135.0, 'data_source': 'gps', 'accuracy': 0.5}, isLine: true);
      state.addPoint(b, null, isLine: true);
      final pts = state.pointsWithMetadata(isLine: true);
      expect(pts[0]['data_source'], 'gps');
      expect(pts[1]['data_source'], 'pen_tool');
      expect(pts[1]['latitude'], b.latitude);
    });
  });

  group('確定', () {
    test('線: 2 点未満なら作らず、2 点で作って描きかけを捨てる', () async {
      final layer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
      state.addPoint(a, null, isLine: true);
      expect(
        await state.confirmCurrentFeature(layerNode: layer, name: 'l', description: '', closeRing: closeRing),
        isFalse,
      );
      expect(layer.features, isEmpty);
      state.addPoint(b, null, isLine: true);
      expect(
        await state.confirmCurrentFeature(layerNode: layer, name: 'l', description: '', closeRing: closeRing),
        isTrue,
      );
      expect((layer.features.single as LineFeatureNode).line, [a, b]);
      expect(state.isDrawing, isFalse);
    });

    test('面: 閉じて作り、確定後に描きかけを捨てても形は残る', () async {
      final layer = (await PolygonLayerNode.createIn(gpkgNode, 'polys'))!;
      for (final p in [a, b, c]) {
        state.addPoint(p, null, isLine: false);
      }
      expect(
        await state.confirmCurrentFeature(layerNode: layer, name: 'g', description: '', closeRing: closeRing),
        isTrue,
      );
      expect(state.isDrawing, isFalse);
      await layer.updateChildren();
      final ring = (layer.features.single as PolygonFeatureNode).polygon.first;
      expect(ring.length, 4);
      expect(ring.first, ring.last);
    });

    test('線のレイヤに面の描きかけは確定しない', () async {
      final layer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
      for (final p in [a, b, c]) {
        state.addPoint(p, null, isLine: false);
      }
      expect(
        await state.confirmCurrentFeature(layerNode: layer, name: 'g', description: '', closeRing: closeRing),
        isFalse,
      );
      expect(layer.features, isEmpty);
      expect(state.drawingPolygon, [a, b, c], reason: '描きかけは捨てない');
    });
  });

  group('自動保存', () {
    test('描きかけを地物にし、描きかけはそのまま続けて同じ地物に追記する', () async {
      final layer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
      container.read(selectedLayerNodeProvider.notifier).select(layer);
      state.addPoint(a, null, isLine: true);
      state.addPoint(b, null, isLine: true);

      await state.autoSaveNow();
      final saved = layer.features.single as LineFeatureNode;
      expect(saved.line, [a, b]);
      expect(state.drawingLine, [a, b], reason: '描きかけは捨てない');

      state.addPoint(c, null, isLine: true);
      await state.autoSaveNow();
      expect(layer.features, hasLength(1), reason: '2 回目は新しく作らず追記');
      expect((layer.features.single as LineFeatureNode).line, [a, b, c]);
    });

    // 追記中に選んでいるレイヤを替えると、2 回目の自動保存のあと描きかけが替えた先のレイヤの
    // 最後の地物に差し替わり、そのまま続けるとその地物を書き換えていた（2026-10-12）
    test('追記中に別のレイヤを選んでも、続きは追記先の地物に書き、ほかの地物を触らない', () async {
      final lines = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
      final other = (await LineLayerNode.createIn(gpkgNode, 'other'))!;
      final untouched = (await LineFeatureNode.createIn(other, [c, d], 'keep', ''))!;

      container.read(selectedLayerNodeProvider.notifier).select(lines);
      state.addPoint(a, null, isLine: true);
      state.addPoint(b, null, isLine: true);
      await state.autoSaveNow();
      final saved = lines.features.single as LineFeatureNode;

      container.read(selectedLayerNodeProvider.notifier).select(other);
      state.addPoint(c, null, isLine: true);
      await state.autoSaveNow();
      expect(saved.line, [a, b, c]);
      expect(state.drawingLine, [a, b, c], reason: '描きかけは追記先の形のまま');

      state.addPoint(d, null, isLine: true);
      await state.autoSaveNow();
      expect(saved.line, [a, b, c, d]);
      expect(untouched.line, [c, d], reason: 'ほかのレイヤの地物は書き換えない');
      expect(other.features, [untouched]);
    });

    test('選んでいるレイヤが描きかけと違う種類なら保存しない', () async {
      final polys = (await PolygonLayerNode.createIn(gpkgNode, 'polys'))!;
      container.read(selectedLayerNodeProvider.notifier).select(polys);
      state.addPoint(a, null, isLine: true);
      state.addPoint(b, null, isLine: true);
      await state.autoSaveNow();
      expect(polys.features, isEmpty);
      expect(state.drawingLine, [a, b]);
    });
  });
}
