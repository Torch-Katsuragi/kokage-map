// 既定 View は親レイヤと同じ名前で見せる（2026-10-02）。中の名前「既定」は識別用に残す。
//
// QGIS にもレイヤ名で書き、読み戻しではレイヤと同じ名前でフィルタの無いものを既定 View に戻す。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/view_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

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
    tmp = await Directory.systemTemp.createTemp('default_view_name_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    final g = GeoPackageFile(const ['a.gpkg'], absolutePath: p.join(proj, 'a.gpkg'));
    await g.addLayer('area', GeometryType.polygon);
    await g.dispose();
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<(FolderNode, LayerNode)> load() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    final gpkg = root.children.whereType<GeoPackageNode>().single;
    await gpkg.updateChildren();
    return (root, gpkg.children.whereType<LayerNode>().single);
  }

  List<String> qgsLayerNames(String qgs) => [
        for (final l in XmlDocument.parse(File(qgs).readAsStringSync()).findAllElements('layer-tree-layer'))
          l.getAttribute('name')!,
      ];

  test('既定 View はレイヤ名で見せ、QGIS にもレイヤ名で書く', () async {
    final (root, layer) = await load();
    final v = layer.views.single;
    expect(v.name, kDefaultViewName);
    expect(v.displayName, 'area');

    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    expect(qgsLayerNames(qgs), ['area']);
  });

  test('読み戻し: レイヤ名のもの（と旧版の「既定」）は既定 View、ほかは名前どおり', () async {
    final (root, layer) = await load();
    layer.views.add(ViewNode(name: '大きい', parent: layer, filter: 'fid > 1'));
    await layer.persistViews();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    expect(qgsLayerNames(qgs), ['area', '大きい']);

    await const QgsImporter().import(qgs, root);
    KMetaService.instance.clearCache();
    final views = (await KMetaService.instance.getMeta(proj)).views['a.gpkg/area']!;
    expect(views.map((v) => v.name), [kDefaultViewName, '大きい']);
  });

  test('旧版が書いた「既定」も既定 View のまま', () async {
    final (root, _) = await load();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    // 旧版の形: View の名前が「既定」。QGIS で View を 1 つ足した体にする
    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    for (final l in doc.findAllElements('layer-tree-layer')) {
      l.setAttribute('name', kDefaultViewName);
    }
    for (final n in doc.findAllElements('layername')) {
      n.innerText = kDefaultViewName;
    }
    File(qgs).writeAsStringSync(doc.toXmlString());

    await const QgsImporter().import(qgs, root);
    final (_, reloaded) = await load();
    expect(reloaded.views.single.isDefaultView, isTrue);
  });
}
