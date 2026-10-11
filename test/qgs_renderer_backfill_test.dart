// QGIS の描き分けの中身（KMetaLayerStyle.qgisRendererDef）を、取り込みで持ち、古い取り込みには補う（2026-10-11）
//
// 中身を持つ前の版で取り込んだプロジェクトは、印（qgisRenderer）だけを持つ。自分が書いた `.qgs` は
// 読み戻さないので、QGIS で保存し直すまで代表の 1 色のまま。補完はその穴だけを埋める。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

const _categorized = '''
<renderer-v2 type="categorizedSymbol" attr="樹種" symbollevels="0">
  <categories>
    <category value="スギ" symbol="0" label="スギ" render="true" type="string"/>
    <category value="NULL" symbol="1" label="その他" render="true" type="NULL"/>
  </categories>
  <symbols>
    <symbol name="0" type="fill" alpha="1">
      <layer class="SimpleFill" enabled="1">
        <Option type="Map"><Option name="color" value="51,160,44,255" type="QString"/></Option>
      </layer>
    </symbol>
    <symbol name="1" type="fill" alpha="1">
      <layer class="SimpleFill" enabled="1">
        <Option type="Map"><Option name="color" value="150,150,150,255" type="QString"/></Option>
      </layer>
    </symbol>
  </symbols>
</renderer-v2>''';

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
    tmp = await Directory.systemTemp.createTemp('qgs_renderer_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    final g = GeoPackageFile(const ['a.gpkg'], absolutePath: p.join(proj, 'a.gpkg'));
    await g.addLayer('shoban', GeometryType.polygon);
    await g.dispose();
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

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

  /// `.qgs` のレイヤのレンダラを分類に差し替える（QGIS で分類にした体）
  void setCategorized(String qgs) {
    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    final maplayer = doc.findAllElements('maplayer').single;
    maplayer.findElements('renderer-v2').toList().forEach((e) => e.remove());
    maplayer.children.add(XmlDocument.parse(_categorized).rootElement.copy());
    File(qgs).writeAsStringSync(doc.toXmlString());
  }

  test('取り込むと、印と一緒に中身もレイヤのスタイルに入る', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    setCategorized(qgs);

    await const QgsImporter().import(qgs, root);
    KMetaService.instance.clearCache();
    final style = (await KMetaService.instance.getMeta(proj)).styles.layers['a.gpkg/shoban']!;
    expect(style.qgisRenderer, 'categorizedSymbol');
    expect([for (final c in style.qgisRendererDef!.classes) c.label], ['スギ', 'その他']);
  });

  test('印だけのスタイルに中身を補う。他は触らない', () async {
    await KMetaService.instance.setLayerStyle(
      proj,
      'a.gpkg/shoban',
      const KMetaLayerStyle(qgisRenderer: 'categorizedSymbol', labelEnabled: true, labelProperty: '"樹種"'),
    );
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    setCategorized(qgs);

    final filled = await const QgsImporter().backfillRendererDefs(qgs, root);
    expect(filled, 1);
    KMetaService.instance.clearCache();
    final style = (await KMetaService.instance.getMeta(proj)).styles.layers['a.gpkg/shoban']!;
    expect(style.qgisRendererDef!.classes, hasLength(2));
    expect(style.labelProperty, '"樹種"', reason: 'ラベルの設定は残る');

    // 2 回目は何もしない（もう中身がある）
    expect(await const QgsImporter().backfillRendererDefs(qgs, root), 0);
  });

  test('印の無いスタイル（アプリで単一シンボル）には足さない', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    setCategorized(qgs);
    expect(await const QgsImporter().backfillRendererDefs(qgs, root), 0);
  });
}
