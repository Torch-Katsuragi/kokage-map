// フォルダを開いて見るだけなら、どの gpkg も書き換えない（ツリー・地物・読み戻し・検索を通して）。
//
// test/gpkg_open_no_write_test.dart は GeoPackageFile を直に呼ぶ。こちらは同じ夜に入った機能
// （結合・写真の欄・描き分けとフォームの補完・検索）が、開いたときの経路で gpkg に書かないかを見る。
// `.qgs` は開いたときに書き直すことがある（前からの挙動）。ただし 2 回目以降に開いても変わらないこと
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/services/feature_search.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_auto_refresh.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis/qgs_read_back.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/foreign_geom_gpkg.dart';
import 'support/join_fixture.dart';

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
    tmp = await Directory.systemTemp.createTemp('open_folder_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    // 計画図（結合つき）・ArcGIS Pro 製（形の列 Shape・rtree つき）・主キーの無い表
    await makeJoinProject(proj);
    await ForeignGeomGpkg.arcgis.write(p.join(proj, 'arc.gpkg'));
    await ForeignGeomGpkg.geopandas.write(p.join(proj, 'nopk.gpkg'));
    final db = await openDatabase(p.join(proj, 'nopk.gpkg'), singleInstance: false);
    await db.execute('CREATE TABLE tmp AS SELECT geometry, name, geom FROM parcels');
    await db.execute('DROP TABLE parcels');
    await db.execute('ALTER TABLE tmp RENAME TO parcels');
    await db.close();
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<FolderNode> openTree() async {
    final root = FolderNode('Home', children: []);
    Future<void> load(LayerTreeNode n) async {
      await n.updateChildren();
      for (final c in n.children) {
        if (c is FolderNode || c is GeoPackageNode || c is LayerNode) await load(c);
      }
    }

    await load(root);
    return root;
  }

  List<LayerNode> layersOf(LayerTreeNode n) => [
        if (n is LayerNode) n,
        for (final c in n.children) ...layersOf(c),
      ];

  /// 閉じる（⚠ ノードの dispose はファイルを消すので使わない）
  Future<void> close(LayerTreeNode n) async {
    if (n is GeoPackageNode) await n.geoPackageFile.dispose();
    for (final c in n.children) {
      await close(c);
    }
  }

  Map<String, String> digests(String ext) => {
        for (final f in Directory(proj).listSync().whereType<File>().where((f) => f.path.endsWith(ext)))
          p.basename(f.path): sha256.convert(f.readAsBytesSync()).toString(),
      };

  test('開いて地物・結合・読み戻し・検索を通しても gpkg を変えず、2 回目は .qgs も変えない', () async {
    // 1 回目: 結合と写真の欄を設定して .qgs を書く（前の作業の体）
    var root = await openTree();
    final shoban = layersOf(root).firstWhere((l) => l.layerName == 'shoban');
    await KMetaService.instance.setLayerJoins(proj, shoban.layerKey, fixtureJoins);
    await KMetaService.instance.addPhotoField(proj, shoban.layerKey, 'photo');
    root.invalidateMetaCache();
    await const QgsProjectBuilder().writeTo(root);
    await close(root);

    final gpkgBefore = digests('.gpkg');
    expect(gpkgBefore.keys, containsAll(['計画図.gpkg', 'arc.gpkg', 'nopk.gpkg']));

    for (var round = 0; round < 2; round++) {
      KMetaService.instance.clearCache();
      root = await openTree();
      final layers = layersOf(root);
      expect(layers.map((l) => l.layerName), containsAll(['shoban', 'Stands', 'parcels']));
      for (final l in layers) {
        expect(l.children, isNotEmpty, reason: '${l.layerName} の地物が読めている');
        await l.loadJoins();
      }
      await const QgsReadBack().run(root);
      final qgsAfterReadBack = digests('.qgs');
      await FeatureSearch.search(layers, 'a');
      await close(root);

      expect(digests('.gpkg'), gpkgBefore, reason: '$round 回目に開いたあと');
      if (round == 1) expect(digests('.qgs'), qgsAfterReadBack);
    }
  });
}
