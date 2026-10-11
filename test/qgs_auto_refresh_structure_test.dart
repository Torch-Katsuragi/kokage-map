// ツリーの顔ぶれが変わったら `.qgs` を追従させる（[[qgis-interop]]、2026-10-11）
//
// フォルダ設定の保存だけを合図にしていた頃は、設定を書かない操作（鍵を持たない gpkg の削除・
// ファイルの追加・改名・移動で空になった gpkg の削除）で `.qgs` が古いファイルを指したまま残った。
// `LayerTreeNode.onStructureChanged` → `QgsAutoRefresh.scheduleFor` で拾う。
//
// gpkg への変換（GDAL が要る）は test/qgs_external_layer_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_auto_refresh.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

void main() {
  late Directory tmp;
  late String proj;
  late FolderNode root;
  final auto = QgsAutoRefresh.instance;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> writeGpkg(String path) async {
    final g = GeoPackageFile([p.basename(path)], absolutePath: path);
    await g.addLayer('trees', GeometryType.point);
    await g.dispose();
  }

  /// 読み直し（gpkg の中のレイヤまで）
  Future<void> reload() async {
    await root.updateChildren();
    for (final g in root.children.whereType<GeoPackageNode>()) {
      await g.updateChildren();
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('qgs_struct_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    await writeGpkg(p.join(proj, 'a.gpkg'));
    await writeGpkg(p.join(proj, 'b.gpkg'));

    // アプリと同じ配線（main.dart）
    root = FolderNode('Home', children: []);
    auto.enabled = true;
    auto.rootGetter = () => root;
    LayerTreeNode.onStructureChanged = auto.scheduleFor;

    await reload();
    await const QgsProjectBuilder().writeTo(root);
    await auto.flushNow(); // 読み込みで立った待ちを消化しておく
  });

  tearDown(() async {
    await auto.flushNow();
    LayerTreeNode.onStructureChanged = null;
    auto.rootGetter = null;
    auto.enabled = false;
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  List<String> dataSources() =>
      XmlDocument.parse(File(p.join(proj, 'proj.qgs')).readAsStringSync())
          .findAllElements('datasource')
          .map((e) => e.innerText)
          .toList()
        ..sort();

  GeoPackageNode gpkg(String name) => root.children.whereType<GeoPackageNode>().singleWhere((n) => n.name == name);

  test('前提: 書いた直後の .qgs と、顔ぶれが変わらない読み直しでは待ちが立たない', () async {
    expect(dataSources(), ['./a.gpkg|layername=trees', './b.gpkg|layername=trees']);
    await reload();
    expect(auto.hasPending, isFalse);
  });

  test('鍵を持たない gpkg を消すと、設定を書かなくても .qgs から外れる', () async {
    await gpkg('b.gpkg').dispose();
    expect(auto.hasPending, isTrue);
    await auto.flushNow();
    expect(dataSources(), ['./a.gpkg|layername=trees']);
  });

  test('ファイルを足して読み直すと .qgs に入る', () async {
    await writeGpkg(p.join(proj, 'c.gpkg'));
    await reload();
    expect(auto.hasPending, isTrue);
    await auto.flushNow();
    expect(dataSources(), ['./a.gpkg|layername=trees', './b.gpkg|layername=trees', './c.gpkg|layername=trees']);
  });

  test('改名して読み直すと .qgs が新しい名前を指す', () async {
    await gpkg('b.gpkg').rename('renamed', projectRootDir: proj);
    await reload();
    expect(auto.hasPending, isTrue);
    await auto.flushNow();
    expect(dataSources(), ['./a.gpkg|layername=trees', './renamed.gpkg|layername=trees']);
  });

  test('レイヤを移して空になった gpkg を消すと .qgs から外れる', () async {
    final b = gpkg('b.gpkg');
    await b.geoPackageFile.removeLayer('trees');
    expect(await b.deleteIfEmptiedByMove(), isTrue);
    expect(auto.hasPending, isTrue);
    await auto.flushNow();
    expect(dataSources(), ['./a.gpkg|layername=trees']);
  });
}
