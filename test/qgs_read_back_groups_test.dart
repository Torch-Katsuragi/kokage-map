// 読み戻しで、QGIS でグループ（gpkg・dir）ごと消灯したら、そのグループの可視性に戻す（2026-09-29）。
//
// 以前は祖先の checked を AND で畳んでレイヤの可視性にしていたので、一度往復すると QGIS では
// 「gpkg は点いていて、レイヤが消えている」形に変わっていた。こかげマップが書いた形（dir グループ >
// gpkg グループ > レイヤグループ > View）のときだけグループごとに戻し、それ以外の形は従来どおり畳む。
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
    tmp = await Directory.systemTemp.createTemp('qgs_groups_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    await Directory(p.join(proj, 'sub')).create();
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    for (final path in [p.join(proj, 'a.gpkg'), p.join(proj, 'sub', 'b.gpkg')]) {
      final g = GeoPackageFile([p.basename(path)], absolutePath: path);
      await g.addLayer('trees', GeometryType.point);
      await g.dispose();
    }
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// [pick] に当たる layer-tree-group を Qt::Unchecked にして書き戻す（QGIS で消灯した体）
  void uncheck(String qgs, bool Function(XmlElement g) pick) {
    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    var n = 0;
    for (final g in doc.findAllElements('layer-tree-group').where(pick)) {
      g.setAttribute('checked', 'Qt::Unchecked');
      n++;
    }
    expect(n, greaterThan(0));
    File(qgs).writeAsStringSync(doc.toXmlString());
  }

  Future<FolderNode> loadTree() async {
    final root = FolderNode('Home', children: []);
    Future<void> load(LayerTreeNode n) async {
      await n.updateChildren();
      for (final c in n.children) {
        if (c is FolderNode || c is GeoPackageNode) await load(c);
      }
    }

    await load(root);
    return root;
  }

  test('gpkg と dir のグループを消灯したら、それぞれの可視性に戻る（レイヤは点いたまま）', () async {
    final root = await loadTree();
    final result = await const QgsProjectBuilder().writeTo(root);
    final qgs = result!.path;

    // QGIS で a.gpkg と sub のグループを消灯した体
    uncheck(qgs, (g) => g.getAttribute('name') == 'a.gpkg' || g.getAttribute('name') == 'sub');

    await const QgsImporter().import(qgs, root);
    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(proj);
    expect(meta.visibility.geopackages['a.gpkg'], isFalse, reason: 'gpkg グループの消灯は gpkg の可視性');
    expect(meta.visibility.folders['sub'], isFalse, reason: 'dir グループの消灯は dir の可視性');
    expect(meta.visibility.layers['a.gpkg/trees'] ?? true, isTrue, reason: 'レイヤは点いたまま（畳まない）');
  });

  test('レイヤグループを消灯したら、レイヤの可視性', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    // a.gpkg の中のレイヤグループ trees を消灯
    uncheck(qgs, (g) => g.getAttribute('name') == 'trees' && (g.parentElement?.getAttribute('name') == 'a.gpkg'));

    await const QgsImporter().import(qgs, root);
    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(proj);
    expect(meta.visibility.layers['a.gpkg/trees'], isFalse);
    expect(meta.visibility.geopackages['a.gpkg'] ?? true, isTrue);
  });
}
