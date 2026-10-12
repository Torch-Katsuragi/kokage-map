// QGIS の属性フォームの設定を取り込み・補完し、新しい地物の既定値と値の関係の選択肢に使う。
// `.qgs` の側（fieldConfiguration など）はこかげマップが書き直しても残る
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/models/qgis_form.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis_form_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

/// QGIS がフォームの設定を書く maplayer の子
const _formTags = [
  'fieldConfiguration', 'aliases', 'defaults', 'constraints', 'constraintExpressions',
  'editable', 'editorlayout', 'attributeEditorForm',
];

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
    tmp = await Directory.systemTemp.createTemp('qgs_form_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    final g = GeoPackageFile(const ['a.gpkg'], absolutePath: p.join(proj, 'a.gpkg'));
    await g.addLayer('chosa', GeometryType.point);
    await g.addAttributeColumns('chosa', {
      'jushu': 'TEXT', 'uid': 'TEXT', 'kubun': 'TEXT', 'koshin': 'TEXT', 'kiroku': 'DATETIME', 'shoban': 'TEXT',
    });
    await g.addLayer('shoban', GeometryType.polygon);
    await g.addAttributeColumns('shoban', {'code': 'TEXT', 'name': 'TEXT', 'rinpan': 'INTEGER'});
    const ring = [LatLng(33.9, 135.9), LatLng(33.9, 135.91), LatLng(33.91, 135.91), LatLng(33.9, 135.9)];
    for (final (code, name, rinpan) in [('1-b', '1林班 ろ小班', 1), ('1-a', '1林班 い小班', 1), ('2-a', '2林班 い小班', 2)]) {
      await g.addPolygonWithAttributes('shoban', [ring], {'code': code, 'name': name, 'rinpan': rinpan});
    }
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

  LayerNode layerOf(FolderNode root, String name) =>
      root.children.whereType<GeoPackageNode>().single.children.whereType<LayerNode>().firstWhere((l) => l.layerName == name);

  /// 書いた `.qgs` の chosa に、QGIS 4.2.2 が書いたフォームの設定を移す（QGIS で設定した体）。
  /// 値の関係の参照先は、書いた `.qgs` の shoban の id に直す
  void transplantForm(String qgs) {
    final fixture = XmlDocument.parse(File('test/fixtures/qgis_4_2_forms.qgs').readAsStringSync());
    final source = fixture.findAllElements('maplayer').firstWhere((m) => m.getElement('layername')?.innerText == 'chosa');
    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    XmlElement byLayer(String table) => doc
        .findAllElements('maplayer')
        .firstWhere((m) => (m.getElement('datasource')?.innerText ?? '').contains('layername=$table'));
    final chosa = byLayer('chosa');
    final shobanId = byLayer('shoban').getElement('id')!.innerText;
    for (final tag in _formTags) {
      chosa.findElements(tag).toList().forEach((e) => e.remove());
      final copied = source.getElement(tag)!.copy();
      chosa.children.add(copied);
    }
    chosa
        .findAllElements('Option')
        .firstWhere((o) => o.getAttribute('name') == 'Layer')
        .setAttribute('value', shobanId);
    File(qgs).writeAsStringSync(doc.toXmlString());
  }

  test('取り込むと、フォームの設定がフォルダ設定に入り、値の関係の参照先がツリーのレイヤに解ける', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    transplantForm(qgs);

    final result = await const QgsImporter().import(qgs, root);
    expect(result.discarded, isEmpty);
    KMetaService.instance.clearCache();
    final form = (await KMetaService.instance.getMeta(proj)).forms['a.gpkg/chosa']!;
    expect(form['jushu']!.label, '樹種');
    expect(form['shoban']!.relationTarget, (gpkg: 'a.gpkg', layer: 'shoban'));
    expect((await KMetaService.instance.getMeta(proj)).forms.containsKey('a.gpkg/shoban'), isFalse);

    // 値の関係の選択肢: rinpan = 1 に絞り、表示名で並べる
    final opts = await QgisFormOptions.load(layerOf(root, 'chosa'), form);
    expect([for (final o in opts['shoban']!) (o.value, o.label)], [('1-a', '1林班 い小班'), ('1-b', '1林班 ろ小班')]);

    // こかげマップが書き直しても、.qgs の側のフォームの設定は残る
    await const QgsProjectBuilder().writeTo(root);
    final after = XmlDocument.parse(File(qgs).readAsStringSync());
    final chosa = after
        .findAllElements('maplayer')
        .firstWhere((m) => (m.getElement('datasource')?.innerText ?? '').contains('layername=chosa'));
    for (final tag in _formTags) {
      expect(chosa.getElement(tag), isNotNull, reason: '$tag が消えた');
    }
    expect(chosa.findAllElements('editWidget').where((w) => w.getAttribute('type') == 'ValueMap'), hasLength(1));
  });

  test('新しい地物に既定値が入る（名前は道具が渡した値のまま）', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    transplantForm(qgs);
    await const QgsImporter().import(qgs, root);
    KMetaService.instance.clearCache();

    final chosa = layerOf(root, 'chosa');
    final f = (await PointFeatureNode.createIn(chosa, const LatLng(33.7, 135.9), '', ''))!;
    final props = f.turfFeature.properties!;
    expect(props['kubun'], 'A');
    expect(props['uid'], matches(RegExp(r'^\{.{36}\}$')));
    expect(props['kiroku'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')));
    expect(props['koshin'], isNotNull);
    final rows = await chosa.geoPackageFile.getAllFeatureAttributes('chosa', columns: ['kubun', 'uid']);
    expect(rows.single['kubun'], 'A', reason: 'DB にも書いてある');
  });

  test('フォームの設定を持たないレイヤに補う。持っていれば触らない', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    transplantForm(qgs);

    expect(await const QgsImporter().backfillForms(qgs, root), 1);
    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(proj)).forms['a.gpkg/chosa']!['dbh']!.label, '胸高直径(cm)');

    // 2 回目は何もしない（もう持っている）
    expect(await const QgsImporter().backfillForms(qgs, root), 0);
    // アプリで持っている設定は巻き戻さない
    await KMetaService.instance.setLayerForm(proj, 'a.gpkg/chosa', const QgisForm(fields: {'x': QgisFieldForm(name: 'x', alias: 'X')}));
    expect(await const QgsImporter().backfillForms(qgs, root), 0);
    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(proj)).forms['a.gpkg/chosa']!.fields.keys, ['x']);
  });

  test('QGIS で設定を外して保存したら、取り込みで外す', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    transplantForm(qgs);
    await const QgsImporter().import(qgs, root);

    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    for (final tag in _formTags) {
      doc.findAllElements(tag).toList().forEach((e) => e.remove());
    }
    File(qgs).writeAsStringSync(doc.toXmlString());
    await const QgsImporter().import(qgs, root);
    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(proj)).forms, isEmpty);
  });
}
