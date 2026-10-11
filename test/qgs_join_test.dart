// 表の結合と `.qgs` の往復。QGIS 4.2.2 が書いた `<vectorjoins>`（test/fixtures/qgis_4_2_joins.qgs、
// tool/qgis/write_join_fixture.py）を読み、アプリが書いた結合と表のレイヤを読み直す。QGIS で足した別の結合は残す
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/layer_join.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/table/table_join.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

import 'support/join_fixture.dart';

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
    TableCache.clear();
    tmp = await Directory.systemTemp.createTemp('qgs_join_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    await makeJoinProject(proj);
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
    for (final g in root.children.whereType<GeoPackageNode>()) {
      addTearDown(g.geoPackageFile.dispose);
    }
    return root;
  }

  LayerNode shoban(FolderNode root) =>
      root.children.whereType<GeoPackageNode>().single.children.whereType<LayerNode>().single;

  Future<List<LayerJoin>> storedJoins() async {
    KMetaService.instance.clearCache();
    return (await KMetaService.instance.getMeta(proj)).joins['計画図.gpkg/shoban'] ?? const [];
  }

  test('QGIS 4.2.2 の結合を読む: 表（delimitedtext・ogr の CP932）に結びつけ、列の選択・接頭辞・記憶を写す', () async {
    final qgs = p.join(proj, 'qgis_joins.qgs');
    File('test/fixtures/qgis_4_2_joins.qgs').copySync(qgs);
    final root = await loadTree();

    final result = await const QgsImporter().import(qgs, root);
    expect(result.discarded, isEmpty);
    expect(await storedJoins(), fixtureJoins);

    // 読み込み済みのレイヤは結合の値がすぐ出る
    final layer = shoban(root);
    await layer.updateChildren();
    expect(layer.joinedFieldNames, ['森林簿_樹種', '森林簿_林齢', '林班_所有者', '林班_地番']);
  });

  test('結合先が表でない（ベクタのレイヤ）なら報告して外す', () async {
    final qgs = p.join(proj, 'qgis_joins.qgs');
    final doc = XmlDocument.parse(File('test/fixtures/qgis_4_2_joins.qgs').readAsStringSync());
    final shobanLayer = doc.findAllElements('maplayer').firstWhere((m) => m.getElement('layername')!.innerText == 'shoban');
    final selfId = shobanLayer.getElement('id')!.innerText;
    shobanLayer.getElement('vectorjoins')!.children.add(XmlElement(const XmlName.parts('join'), [
      XmlAttribute(const XmlName.parts('joinLayerId'), selfId),
      XmlAttribute(const XmlName.parts('joinFieldName'), 'key'),
      XmlAttribute(const XmlName.parts('targetFieldName'), 'key'),
    ]));
    File(qgs).writeAsStringSync(doc.toXmlString());
    final root = await loadTree();

    final result = await const QgsImporter().import(qgs, root);
    expect(result.discarded, [contains('shoban の結合（結合先 shoban は表ではないので未対応）')]);
    expect(await storedJoins(), fixtureJoins);
  });

  test('書く: 表は delimitedtext（文字コードつき）、結合は <vectorjoins>。読み直すと同じ結合', () async {
    await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', fixtureJoins);
    final root = await loadTree();
    final written = (await const QgsProjectBuilder().writeTo(root))!;
    final doc = XmlDocument.parse(File(written.path).readAsStringSync());
    if (Platform.environment['KOKAGE_KEEP_QGS'] case final keep?) {
      // QGIS で開いて確かめる用（tool/qgis/check_qgs.py）
      final out = Directory(keep)..createSync(recursive: true);
      for (final f in Directory(proj).listSync().whereType<File>()) {
        f.copySync(p.join(out.path, p.basename(f.path)));
      }
    }

    final maplayers = doc.findAllElements('maplayer').toList();
    XmlElement byName(String name) => maplayers.firstWhere((m) => m.getElement('layername')!.innerText == name);
    final boki = byName('森林簿');
    final rinpan = byName('林班表');
    expect(boki.getAttribute('wkbType'), 'NoGeometry');
    expect(boki.getElement('provider')!.innerText, 'delimitedtext');
    expect(boki.getElement('datasource')!.innerText,
        startsWith('file:./%E6%A3%AE%E6%9E%97%E7%B0%BF.csv?type=csv&encoding=UTF-8&'));
    expect(rinpan.getElement('datasource')!.innerText, contains('encoding=CP932'));
    expect(boki.getElement('id')!.innerText, QgsProjectBuilder.tableLayerIdForPath('./森林簿.csv'));
    // ツリーにも載る（QGIS のレイヤパネルに出る）
    expect(doc.findAllElements('layer-tree-layer').where((t) => t.getAttribute('providerKey') == 'delimitedtext'), hasLength(2));

    final joins = byName('shoban').getElement('vectorjoins')!.findElements('join').toList();
    expect(joins, hasLength(2));
    expect(joins[0].getAttribute('joinLayerId'), boki.getElement('id')!.innerText);
    expect(joins[0].getAttribute('targetFieldName'), 'key');
    expect(joins[0].getAttribute('hasCustomPrefix'), isNull);
    expect([for (final f in joins[0].findAllElements('field')) f.getAttribute('name')], ['樹種', '林齢']);
    expect(joins[1].getAttribute('joinLayerId'), rinpan.getElement('id')!.innerText);
    expect(joins[1].getAttribute('customPrefix'), '林班_');
    expect(joins[1].getAttribute('hasCustomPrefix'), '1');
    expect(joins[1].findElements('joinFieldsSubset'), isEmpty);

    // 読み直す（設定を消してから、書いた .qgs だけで戻るか）
    await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', const []);
    final result = await const QgsImporter().import(written.path, root);
    expect(result.discarded, isEmpty);
    expect(await storedJoins(), fixtureJoins);
  });

  test('更新: QGIS で足した表は id を付け替えて結合ごと引き継ぎ、ほかのレイヤへの結合は残す', () async {
    await KMetaService.instance.setLayerJoins(proj, '計画図.gpkg/shoban', [fixtureJoins.first]);
    final root = await loadTree();
    final project = await const QgsProjectBuilder().build(root);

    // QGIS で作った文書に、アプリの shoban（id を合わせる）と、表ではない結合（QGIS の持ち物）を足した体
    final fixture = File('test/fixtures/qgis_4_2_joins.qgs').readAsStringSync();
    final doc = QgsDocument.parse(fixture);
    final ourShobanId = project.layers.single.id;
    final qgisShoban = doc.mapLayers.firstWhere((m) => m.getElement('layername')!.innerText == 'shoban');
    final oldShobanId = qgisShoban.getElement('id')!.innerText;
    qgisShoban.getElement('id')!.innerText = ourShobanId;
    final foreign = XmlElement(const XmlName.parts('join'), [
      XmlAttribute(const XmlName.parts('joinLayerId'), 'some_vector_layer'),
      XmlAttribute(const XmlName.parts('joinFieldName'), 'a'),
      XmlAttribute(const XmlName.parts('targetFieldName'), 'b'),
    ]);
    qgisShoban.getElement('vectorjoins')!.children.add(foreign);
    for (final t in doc.root.findAllElements('layer-tree-layer').where((t) => t.getAttribute('id') == oldShobanId)) {
      t.setAttribute('id', ourShobanId);
    }

    final report = doc.apply(project);
    expect(report.removedLayers, isEmpty, reason: 'QGIS の表は id を付け替えて残す');
    final out = XmlDocument.parse(doc.toXmlString());
    final tableIds = {
      for (final m in out.findAllElements('maplayer'))
        if (m.getAttribute('wkbType') == 'NoGeometry') m.getElement('layername')!.innerText: m.getElement('id')!.innerText,
    };
    expect(tableIds, {
      '森林簿': QgsProjectBuilder.tableLayerIdForPath('./森林簿.csv'),
      '林班表': QgsProjectBuilder.tableLayerIdForPath('./林班表.csv'),
    });
    // QGIS が ogr・CP932 で読んでいた林班表は、その形のまま
    final rinpan = out.findAllElements('maplayer').firstWhere((m) => m.getElement('layername')!.innerText == '林班表');
    expect(rinpan.getElement('provider')!.innerText, 'ogr');
    expect(rinpan.getElement('provider')!.getAttribute('encoding'), 'CP932');

    final joins = out
        .findAllElements('maplayer')
        .firstWhere((m) => m.getElement('id')!.innerText == ourShobanId)
        .getElement('vectorjoins')!
        .findElements('join')
        .toList();
    // 表への結合はアプリの設定（森林簿の 1 本）に差し替え、表ではない結合は残る
    expect([for (final j in joins) j.getAttribute('joinLayerId')], [
      'some_vector_layer',
      tableIds['森林簿'],
    ]);
  });
}
