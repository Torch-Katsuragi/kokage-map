// MapSceneStore（SceneSink / MapScene の実装）の契約テスト（2026-10-11）
//
// 地図ページは SceneSink として書き、3D 地図面は MapScene として読む。
// 描画系は差分を受けず、revision が増えたら読み直すので、「書いたら必ず revision が進む」が約束の芯
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/interfaces/scene_sink.dart';
import 'package:root_maps/models/map_style_group.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/overlay_image_node.dart';
import 'package:root_maps/screens/map_page/feature_geojson_cache.dart';
import 'package:root_maps/screens/map_page/map_scene_store.dart';

const _empty = FeatureGeoJsonInput(
  lines: [],
  polygons: [],
  points: [],
  photos: [],
  selected: {},
  lineVertices: false,
  polygonVertices: false,
);

MapStyleGroup _group(String key, {String fill = '#00ff00'}) => MapStyleGroup(
      key: key,
      fillHex: fill,
      fillOpacity: 0.5,
      outlineHex: '#000000',
      outlineOpacity: 1,
      borderWidth: 1,
      lineHex: '#ff0000',
      lineWidth: 2,
      pointHex: '#0000ff',
      pointSize: 6,
    );

void main() {
  late List<OverlayImageNode> overlays;
  late MapSceneStore store;
  setUp(() {
    overlays = [];
    store = MapSceneStore(overlayImagesOf: () => overlays);
  });

  test('書く側（SceneSink）と読む側（MapScene）を同じものが満たす', () {
    expect(store, isA<SceneSink>());
    expect(store, isA<MapScene>());
  });

  test('pushFeatures は全件でも選択だけでも revision を 1 つ進める', () {
    final ticks = <int>[];
    store.revision.addListener(() => ticks.add(store.revision.value));
    store.pushFeatures(_empty, selectionOnly: false);
    store.pushFeatures(_empty, selectionOnly: true);
    expect(ticks, [1, 2]);
  });

  test('選択だけの pushFeatures は通常リストの中身の世代を進めない', () {
    store.pushFeatures(_empty, selectionOnly: false);
    final rev = store.features.contentRevision;
    final polygons = store.features.polygons;
    store.pushFeatures(_empty, selectionOnly: true);
    expect(store.features.contentRevision, rev);
    expect(identical(store.features.polygons, polygons), isTrue);
  });

  test('invalidate は中身を変えずに revision だけ進める', () {
    store.pushFeatures(_empty, selectionOnly: false);
    final features = store.features;
    final before = store.revision.value;
    store.invalidate();
    expect(store.revision.value, before + 1);
    expect(identical(store.features, features), isTrue);
  });

  test('setStyleGroups は変わったときだけ true。読む側には変更できないリストで見える', () {
    expect(store.styleGroups, isEmpty);
    expect(store.setStyleGroups([_group('a')]), isTrue);
    expect(store.setStyleGroups([_group('a')]), isFalse);
    expect(store.setStyleGroups([_group('a', fill: '#123456')]), isTrue);
    expect(store.styleGroups.single.fillHex, '#123456');
    expect(() => store.styleGroups.add(_group('b')), throwsUnsupportedError);
  });

  test('setStyleGroups だけでは revision は進まない（フィーチャと一緒に流す）', () {
    store.setStyleGroups([_group('a')]);
    expect(store.revision.value, 0);
  });

  test('overlayImages は地図ページの今のリストを覗く（差し替えにも追従）', () {
    expect(store.overlayImages, isEmpty);
    final next = <OverlayImageNode>[];
    overlays = next;
    expect(identical(store.overlayImages, next), isTrue);
  });

  test('描く順は段を引け、変わったときだけ世代が進む（焼き直しは 1 回）', () {
    final a = FolderNode('a');
    final b = FolderNode('b');
    expect(store.drawRankOf(a), -1, reason: '知らないものはいちばん下');
    expect(store.setDrawOrder({a: 1, b: 0}), isTrue);
    final rev = store.drawOrderRevision;
    expect(store.drawRankOf(a), 1);
    expect(store.setDrawOrder({a: 1, b: 0}), isFalse, reason: '同じ並びなら進まない');
    expect(store.drawOrderRevision, rev);
    expect(store.setDrawOrder({a: 0, b: 1}), isTrue);
    expect(store.drawOrderRevision, rev + 1);
    expect(store.drawRankOf(b), 1);
  });
}
