// 地物の編集（FeatureEditor）: 1 手ごとの元に戻す・やり直す、頂点の足し引き、簡略化・切り落とし、
// 保存・取消で GeoPackage に何が書かれるか
//
// 実物の GeoPackage を使う（attribute_form_number_test.dart と同じ作り）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/editing/edit_session.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const a = LatLng(34.0, 135.0);
  const b = LatLng(34.001, 135.001);
  const c = LatLng(34.002, 135.0);
  const d = LatLng(34.003, 135.001);
  const e = LatLng(34.004, 135.0);

  group('形の計算', () {
    test('重心は頂点の平均', () {
      final g = centroidOf([
        [a, c],
        [b],
      ]);
      expect(g.latitude, closeTo(34.001, 1e-12));
      expect(g.longitude, closeTo(135 + 0.001 / 3, 1e-12));
    });

    test('回転 0・倍率 1 は動かさず、2 倍は重心からの距離が 2 倍', () {
      final shape = [
        [a, b, c],
      ];
      final center = centroidOf(shape);
      final same = transformShape(shape, center);
      for (var i = 0; i < 3; i++) {
        expect(same[0][i].latitude, closeTo(shape[0][i].latitude, 1e-12));
        expect(same[0][i].longitude, closeTo(shape[0][i].longitude, 1e-12));
      }
      final twice = transformShape(shape, center, scale: 2);
      const dist = Distance(roundResult: false);
      for (var i = 0; i < 3; i++) {
        expect(dist(center, twice[0][i]), closeTo(2 * dist(center, shape[0][i]), 2));
      }
    });

    test('画面で時計回りに 90° 回すと北の点は東へ行く', () {
      const center = LatLng(34, 135);
      const north = LatLng(34.001, 135);
      final r = transformShape([
        [north],
      ], center, angle: math.pi / 2)[0][0];
      expect(r.latitude, closeTo(34, 1e-9));
      expect(r.longitude, greaterThan(135));
      // 経度は緯度で縮めた平面で回すので、距離は保たれる
      expect(const Distance(roundResult: false)(center, r), closeTo(const Distance(roundResult: false)(center, north), 2)); // 楕円体との差で 1% まで
    });

    test('平行移動', () {
      final t = translateShape([
        [a, b],
      ], 0.01, -0.02);
      expect(t[0][1].latitude, closeTo(b.latitude + 0.01, 1e-12));
      expect(t[0][1].longitude, closeTo(b.longitude - 0.02, 1e-12));
    });

    test('地物の種類ごとの道具と最少頂点数', () {
      expect(modesFor(EditKind.point), [EditMode.move]);
      expect(modesFor(EditKind.polygon), isNot(contains(EditMode.trim)));
      expect(modesFor(EditKind.line), containsAll([EditMode.extend, EditMode.trim]));
      expect(FeatureEditor.minVertices(EditKind.line), 2);
      expect(FeatureEditor.minVertices(EditKind.polygon), 3);
    });
  });

  group('編集', () {
    late Directory tmp;
    late GeoPackageFile gpkg;
    late GeoPackageNode node;
    late ProviderContainer container;
    late FeatureEditor editor;

    EditState st() => container.read(featureEditorProvider)!;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('edit_session_');
      gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
      node = GeoPackageNode(gpkg);
      container = ProviderContainer();
      editor = container.read(featureEditorProvider.notifier);
    });

    tearDown(() async {
      container.dispose();
      await gpkg.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<LineFeatureNode> line(List<LatLng> pts) async {
      final layer = (await LineLayerNode.createIn(node, 'lines'))!;
      return (await LineFeatureNode.createIn(layer, pts, 'l1', null))!;
    }

    Future<List<LatLng>> reloadLine(LineFeatureNode f) async {
      await f.parent.updateChildren();
      return (f.parent.features.single as LineFeatureNode).line;
    }

    test('始めると元の形の写しと頂点の番号を持ち、まだ変わっていない', () async {
      final f = await line([a, b, c]);
      await editor.start(f);
      expect(st().kind, EditKind.line);
      expect(st().geom, [
        [a, b, c],
      ]);
      expect(st().ids, [
        [0, 1, 2],
      ]);
      expect(st().mode, EditMode.vertex);
      expect(st().dirty, isFalse);
    });

    test('頂点を足す・消すは 1 手ずつ戻せてやり直せ、元に戻すと変わっていない扱い', () async {
      final f = await line([a, b, c]);
      await editor.start(f);

      editor.insertVertex(0, 0, d); // a の次
      expect(st().geom[0], [a, d, b, c]);
      expect(st().ids[0], [0, null, 1, 2]);

      editor.select((0, 2));
      expect(editor.canDeleteSelected, isTrue);
      editor.deleteSelected();
      expect(st().geom[0], [a, d, c]);
      expect(st().ids[0], [0, null, 2]);
      expect(st().selected, isNull);
      expect(st().undo, hasLength(2));

      editor.undo();
      expect(st().geom[0], [a, d, b, c]);
      editor.undo();
      expect(st().geom[0], [a, b, c]);
      expect(st().dirty, isFalse);
      editor.undo(); // もう戻せない
      expect(st().geom[0], [a, b, c]);

      editor.redo();
      editor.redo();
      expect(st().geom[0], [a, d, c]);
      expect(st().ids[0], [0, null, 2]);
      expect(st().redo, isEmpty);
    });

    test('新しい手を打つとやり直しは捨てる', () async {
      final f = await line([a, b, c]);
      await editor.start(f);
      editor.insertVertex(0, 1, d);
      editor.undo();
      expect(st().redo, hasLength(1));
      editor.insertVertex(0, 0, e);
      expect(st().redo, isEmpty);
    });

    test('同じ形の手は積まない（ドラッグして元の場所に戻した等）', () async {
      final f = await line([a, b, c]);
      await editor.start(f);
      final before = st().snap;
      editor.preview([
        [a, d, c],
      ]);
      editor.preview([
        [a, b, c],
      ]);
      editor.commit(before);
      expect(st().undo, isEmpty);
    });

    test('線は 2 点より減らせない', () async {
      final f = await line([a, b]);
      await editor.start(f);
      editor.select((0, 1));
      expect(editor.canDeleteSelected, isFalse);
      editor.deleteSelected();
      expect(st().geom[0], [a, b]);
    });

    test('線を延ばす: 始点を選んでいれば前、そうでなければ後ろ', () async {
      final f = await line([a, b]);
      await editor.start(f);
      editor.extendLine(c);
      expect(st().geom[0], [a, b, c]);
      expect(st().selected, (0, 2));
      editor.select((0, 0));
      editor.extendLine(d);
      expect(st().geom[0], [d, a, b, c]);
      expect(st().ids[0], [null, 0, 1, null]);
      expect(st().selected, (0, 0));
    });

    test('切り落とし: つまみの範囲を残し、離すと 1 手になり、戻せる', () async {
      final f = await line([a, b, c, d, e]);
      await editor.start(f);
      editor.setMode(EditMode.trim);
      expect(st().trimRange, (0, 4));
      expect(editor.trimMax, 4);

      editor.sliderStart();
      editor.setTrim(1, 3);
      editor.setTrim(1, 2); // つまみは道具に入ったときの形から測る
      editor.sliderEnd();
      expect(st().geom[0], [b, c]);
      expect(st().ids[0], [1, 2]);
      expect(st().undo, hasLength(1));

      editor.setTrim(2, 2); // 1 点にはしない
      expect(st().geom[0], [b, c]);

      editor.undo();
      expect(st().geom[0], [a, b, c, d, e]);
      expect(st().trimRange, (0, 4));
    });

    test('簡略化: 段ごとに 1 点ずつ消え、端の 2 点は残り、残った頂点は元の番号を持つ', () async {
      // ほぼまっすぐな線（真ん中の 3 点はわずかにずれる）
      const p0 = LatLng(34.0, 135.0);
      const p1 = LatLng(34.00001, 135.001);
      const p2 = LatLng(34.0, 135.002);
      const p3 = LatLng(34.00003, 135.003);
      const p4 = LatLng(34.0, 135.004);
      final f = await line([p0, p1, p2, p3, p4]);
      await editor.start(f);
      editor.setMode(EditMode.simplify);
      final steps = editor.simplifySteps;
      expect(steps, hasLength(3), reason: '5 点から端の 2 点まで');
      expect(steps, orderedEquals([...steps]..sort()));

      editor.sliderStart();
      editor.setTolerance(steps[0]);
      expect(st().geom[0], hasLength(4));
      editor.setTolerance(steps[2]);
      expect(st().geom[0], [p0, p4]);
      expect(st().ids[0], [0, 4]);
      editor.sliderEnd();
      expect(st().undo, hasLength(1));

      editor.setTolerance(0);
      expect(st().geom[0], hasLength(5), reason: '0 なら元に戻る');
    });

    test('面の簡略化は 3 点より減らさない', () async {
      final layer = (await PolygonLayerNode.createIn(node, 'polys'))!;
      final g = (await PolygonFeatureNode.createIn(layer, [
        [a, b, c, d, a],
      ], 'g', null))!;
      await editor.start(g);
      expect(st().geom[0], hasLength(4), reason: '閉じたリングは開いて持つ');
      editor.setMode(EditMode.simplify);
      final steps = editor.simplifySteps;
      expect(steps.length, lessThanOrEqualTo(1));
      editor.setTolerance(1e6);
      expect(st().geom[0].length, greaterThanOrEqualTo(3));
    });

    test('保存すると形を書き、読み直しても同じ。編集は終わる', () async {
      final f = await line([a, b, c]);
      await editor.start(f);
      editor.insertVertex(0, 2, d);
      expect(await editor.save(), isTrue);
      expect(container.read(featureEditorProvider), isNull);
      expect(await reloadLine(f), [a, b, c, d]);
    });

    test('取消は何も書かない', () async {
      final f = await line([a, b, c]);
      await editor.start(f);
      editor.insertVertex(0, 2, d);
      editor.cancel();
      expect(container.read(featureEditorProvider), isNull);
      expect(await reloadLine(f), [a, b, c]);
    });

    test('面の保存は閉じたリングで書き、穴も保つ', () async {
      const h1 = LatLng(34.0005, 135.0003);
      const h2 = LatLng(34.0008, 135.0003);
      const h3 = LatLng(34.0008, 135.0006);
      final layer = (await PolygonLayerNode.createIn(node, 'polys'))!;
      final g = (await PolygonFeatureNode.createIn(layer, [
        [a, b, c, a],
        [h1, h2, h3, h1],
      ], 'g', null))!;
      await editor.start(g);
      expect(st().geom, hasLength(2));
      editor.insertVertex(0, 2, d);
      expect(await editor.save(), isTrue);

      await layer.updateChildren();
      final rings = (layer.features.single as PolygonFeatureNode).polygon;
      expect(rings, hasLength(2));
      expect(rings[0], [a, b, c, d, a]);
      expect(rings[1].first, rings[1].last);
      expect(rings[1], hasLength(4));
    });

    test('点は動かすだけ', () async {
      final layer = (await PointLayerNode.createIn(node, 'pts'))!;
      final p = (await PointFeatureNode.createIn(layer, a, 'p', null))!;
      await editor.start(p);
      expect(st().kind, EditKind.point);
      expect(st().mode, EditMode.move);
      editor.apply([
        [b],
      ]);
      expect(await editor.save(), isTrue);
      await layer.updateChildren();
      expect((layer.features.single as PointFeatureNode).point, b);
    });

    test('保存で頂点ごとの記録（sub_table）を新しい頂点の並びに合わせる', () async {
      final f = await line([a, b, c]);
      await gpkg.addAttributeColumns('lines', {'sub_table': 'TEXT'});
      final rec = jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          for (final (i, p) in [a, b, c].indexed)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [p.longitude, p.latitude],
              },
              'properties': {'n': i},
            },
        ],
      });
      await f.setAttributeValue('sub_table', rec);
      await gpkg.flushChanges();

      await editor.start(f);
      editor.select((0, 1));
      editor.deleteSelected(); // b を消す
      editor.insertVertex(0, 1, d); // 末尾に d
      expect(await editor.save(), isTrue);
      await gpkg.flushChanges();

      final out = jsonDecode(await gpkg.getFeatureAttribute('lines', f.rowId, 'sub_table') as String) as Map;
      final props = [for (final x in out['features'] as List) ((x as Map)['properties'] as Map)['n']];
      expect(props, [0, 2, null]);
    });

    test('属性だけ変えても形は書かず、元の値に戻せば変わっていない扱い', () async {
      final f = await line([a, b]);
      await gpkg.addAttributeColumns('lines', {'memo': 'TEXT'});
      await editor.start(f);
      expect(st().columns, contains('memo'));
      editor.setAttr('memo', 'x');
      expect(st().attrsChanged, isTrue);
      expect(st().shapeChanged, isFalse);
      editor.setAttr('memo', '');
      expect(st().dirty, isFalse, reason: 'null と空は同じ');
    });
  });
}
