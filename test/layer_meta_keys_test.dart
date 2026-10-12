// gpkg・レイヤの改名と削除で、フォルダ設定のレイヤ単位の鍵（スタイル・View・属性フォーム・結合）が
// ついていく／落ちる（2026-10-11 夜のレビュー。改名で描き分けや結合が外れ、削除後に同名で作ると前の設定を引き継いでいた）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/layer_join.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/qgis_form.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/layer_drawer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late String proj;
  final svc = KMetaService.instance;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    svc.clearCache();
    tmp = await Directory.systemTemp.createTemp('layer_meta_keys_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    final g = GeoPackageFile(const ['b.gpkg'], absolutePath: p.join(proj, 'b.gpkg'));
    await g.addLayer('trees', GeometryType.point);
    await g.addLayer('roads', GeometryType.linestring);
    await g.dispose();
  });

  tearDown(() async {
    svc.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  const join = LayerJoin(table: '森林簿.csv', joinField: 'ID', targetField: 'ID');
  const form = QgisForm(fields: {'NAME': QgisFieldForm(name: 'NAME', alias: '名前')});

  Future<void> giveSettings(String key) async {
    await svc.setLayerStyle(proj, key, const KMetaLayerStyle(pointSize: 7));
    await svc.setViews(proj, key, [const KMetaView(name: '高い', filter: 'H > 10')]);
    await svc.setLayerForm(proj, key, form);
    await svc.setLayerJoins(proj, key, [join]);
  }

  void expectSettings(KMeta meta, String key, {required bool present}) {
    final m = present ? isTrue : isFalse;
    expect(meta.styles.layers.containsKey(key), m, reason: 'style $key');
    expect(meta.views.containsKey(key), m, reason: 'views $key');
    expect(meta.forms.containsKey(key), m, reason: 'forms $key');
    expect(meta.joins.containsKey(key), m, reason: 'joins $key');
  }

  Future<GeoPackageNode> openGpkg() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    final gpkg = root.children.whereType<GeoPackageNode>().singleWhere((g) => g.name == 'b.gpkg');
    await gpkg.updateChildren();
    return gpkg;
  }

  test('gpkg を改名すると、レイヤ単位の設定が新しい名前へ移る', () async {
    await giveSettings('b.gpkg/trees');
    final gpkg = await openGpkg();
    await LayerDrawerService.renameGeoPackage(gpkg, 'c', projectRootDir: proj);

    svc.clearCache();
    final meta = await svc.getMeta(proj);
    expectSettings(meta, 'b.gpkg/trees', present: false);
    expectSettings(meta, 'c.gpkg/trees', present: true);
  });

  test('レイヤを改名すると、そのレイヤの設定だけが新しい名前へ移る', () async {
    await giveSettings('b.gpkg/trees');
    await svc.setLayerStyle(proj, 'b.gpkg/roads', const KMetaLayerStyle(lineWidth: 3));
    final gpkg = await openGpkg();
    final trees = gpkg.children.whereType<LayerNode>().singleWhere((l) => l.layerName == 'trees');
    await LayerDrawerService.renameLayer(trees, 'pines');

    svc.clearCache();
    final meta = await svc.getMeta(proj);
    expectSettings(meta, 'b.gpkg/trees', present: false);
    expectSettings(meta, 'b.gpkg/pines', present: true);
    expect(meta.styles.layers['b.gpkg/roads']?.lineWidth, 3);
    await gpkg.geoPackageFile.dispose();
  });

  test('レイヤを消すと、そのレイヤの設定を落とす（同じ gpkg の別レイヤは残す）', () async {
    await giveSettings('b.gpkg/trees');
    await giveSettings('b.gpkg/roads');
    final gpkg = await openGpkg();
    final trees = gpkg.children.whereType<LayerNode>().singleWhere((l) => l.layerName == 'trees');
    await LayerDrawerService.deleteLayer(trees);

    svc.clearCache();
    final meta = await svc.getMeta(proj);
    expectSettings(meta, 'b.gpkg/trees', present: false);
    expectSettings(meta, 'b.gpkg/roads', present: true);
    await gpkg.geoPackageFile.dispose();
  });

  // 値の関係（ValueRelation）の参照先。gpkg の相対パスはフォームを持つフォルダから
  QgisForm relationForm(String gpkg, String layer) => QgisForm(fields: {
        'kind': QgisFieldForm(name: 'kind', widgetType: 'ValueRelation', config: {
          'Key': 'id',
          'Value': 'name',
          kRelationTargetKey: {'gpkg': gpkg, 'layer': layer},
        }),
      });

  /// 子フォルダ sub/ に d.gpkg を置き、そのフォームが ../b.gpkg の trees を参照する
  Future<String> giveSubFolderRelation() async {
    final sub = (await Directory(p.join(proj, 'sub')).create()).path;
    final d = GeoPackageFile(const ['sub', 'd.gpkg'], absolutePath: p.join(sub, 'd.gpkg'));
    await d.addLayer('plots', GeometryType.polygon);
    await d.dispose();
    await svc.setLayerForm(sub, 'd.gpkg/plots', relationForm('../b.gpkg', 'trees'));
    return sub;
  }

  ({String gpkg, String layer})? targetOf(KMeta meta, String key) => meta.forms[key]?.fields['kind']?.relationTarget;

  test('参照先のレイヤを改名すると、ほかのレイヤ・フォルダの値の関係も新しい名前を指す', () async {
    await svc.setLayerForm(proj, 'b.gpkg/roads', relationForm('b.gpkg', 'trees'));
    await svc.setLayerForm(proj, 'b.gpkg/trees', relationForm('b.gpkg', 'roads'));
    final sub = await giveSubFolderRelation();
    final gpkg = await openGpkg();
    final trees = gpkg.children.whereType<LayerNode>().singleWhere((l) => l.layerName == 'trees');
    await LayerDrawerService.renameLayer(trees, 'pines');

    svc.clearCache();
    final meta = await svc.getMeta(proj);
    expect(targetOf(meta, 'b.gpkg/roads'), (gpkg: 'b.gpkg', layer: 'pines'));
    expect(targetOf(meta, 'b.gpkg/pines'), (gpkg: 'b.gpkg', layer: 'roads'));
    expect(targetOf(await svc.getMeta(sub), 'd.gpkg/plots'), (gpkg: '../b.gpkg', layer: 'pines'));
    await gpkg.geoPackageFile.dispose();
  });

  test('参照先の gpkg を改名すると、ほかのフォルダの値の関係も新しい gpkg を指す', () async {
    await svc.setLayerForm(proj, 'b.gpkg/roads', relationForm('b.gpkg', 'trees'));
    final sub = await giveSubFolderRelation();
    final gpkg = await openGpkg();
    await LayerDrawerService.renameGeoPackage(gpkg, 'c', projectRootDir: proj);

    svc.clearCache();
    expect(targetOf(await svc.getMeta(proj), 'c.gpkg/roads'), (gpkg: 'c.gpkg', layer: 'trees'));
    expect(targetOf(await svc.getMeta(sub), 'd.gpkg/plots'), (gpkg: '../c.gpkg', layer: 'trees'));
  });

  test('gpkg を忘れると、レイヤ単位の設定も落とす', () async {
    await giveSettings('b.gpkg/trees');
    await svc.forgetGeoPackage(proj, 'b.gpkg');
    svc.clearCache();
    expectSettings(await svc.getMeta(proj), 'b.gpkg/trees', present: false);
  });
}
