// どの dir の `.qgs` にも子孫のレイヤを平らに写す（2026-09-30、埋め込みをやめた）。
//
// どの dir も、あるときは根として開かれ、別のときは子になる。QGIS で開いた dir の下が全部直せるように
// 写しを持ち、QGIS で直された写しは持ち主（データソースの置き場所の dir）の設定へ振り分ける。
// 持ち主のほうが新しければ、古い写しで巻き戻さない。
import 'dart:io';

import 'package:flutter/painting.dart' show Color;
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
import 'package:root_maps/services/qgis/qgs_auto_refresh.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_meta_store.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis/qgs_read_back.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

void main() {
  late Directory tmp;
  late String proj;
  late String sub;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    QgsAutoRefresh.instance.enabled = false;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('qgs_flat_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    sub = (await Directory(p.join(proj, 'sub')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    for (final path in [p.join(proj, 'a.gpkg'), p.join(sub, 'b.gpkg')]) {
      final g = GeoPackageFile([p.basename(path)], absolutePath: path);
      await g.addLayer('trees', GeometryType.point);
      await g.dispose();
    }
    // sub にも自分の設定（`.qgs`）を持たせる
    await KMetaService.instance.setLayerStyle(sub, 'b.gpkg/trees', const KMetaLayerStyle(pointColor: Color(0xFF0000FF)));
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

  String qgsOf(String dir) => p.join(dir, '${p.basename(dir)}.qgs');

  List<String> dataSources(String qgs) => XmlDocument.parse(File(qgs).readAsStringSync())
      .findAllElements('datasource')
      .map((e) => e.innerText)
      .toList()
    ..sort();

  /// QGIS で保存した体にする: [edit] で直し、saveDateTime を [at] にする（印の savedAt は残る）
  void qgisSave(String qgs, DateTime at, void Function(XmlDocument doc) edit) {
    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    edit(doc);
    doc.rootElement.setAttribute('saveDateTime', KokageStamp.formatQgisDateTime(at));
    File(qgs).writeAsStringSync(doc.toXmlString());
  }

  /// [gpkg] の下のレイヤグループ trees を消灯
  void Function(XmlDocument) uncheckTrees(String gpkg) => (doc) {
        final g = doc
            .findAllElements('layer-tree-group')
            .firstWhere((g) => g.getAttribute('name') == 'trees' && g.parentElement?.getAttribute('name') == gpkg);
        g.setAttribute('checked', 'Qt::Unchecked');
      };

  test('根にも子にも、子孫のレイヤが平らに入る（埋め込みではない）', () async {
    final root = await loadTree();
    await const QgsProjectBuilder().writeTo(root);

    expect(dataSources(qgsOf(proj)), ['./a.gpkg|layername=trees', './sub/b.gpkg|layername=trees']);
    expect(dataSources(qgsOf(sub)), ['./b.gpkg|layername=trees']);
    final rootXml = File(qgsOf(proj)).readAsStringSync();
    expect(rootXml, isNot(contains('embedded')));
    // 写しのスタイルは持ち主の設定から（sub の青）
    expect(rootXml, contains('0,0,255'));
  });

  test('根の `.qgs` で子のレイヤを直すと、子の設定に振り分けられる', () async {
    final root = await loadTree();
    await const QgsProjectBuilder().writeTo(root);

    qgisSave(qgsOf(proj), DateTime.now().add(const Duration(minutes: 1)), uncheckTrees('b.gpkg'));
    await const QgsReadBack().run(root);

    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(sub)).visibility.layers['b.gpkg/trees'], isFalse);
    expect((await KMetaService.instance.getMeta(proj)).visibility.layers['b.gpkg/trees'], isNull,
        reason: '根の設定には入れない（持ち主は sub）');
    expect(QgsDocument.parse(File(qgsOf(proj)).readAsStringSync()).lastWrittenByKokage, isTrue,
        reason: '取り込んだので印を付け直す');
  });

  test('写しが持ち主より古ければ取り込まない。根自身の分は取り込む', () async {
    final root = await loadTree();
    await const QgsProjectBuilder().writeTo(root);

    final t = DateTime.now().add(const Duration(minutes: 1));
    // QGIS で根を保存（a と b の両方を消灯）
    qgisSave(qgsOf(proj), t, (doc) {
      uncheckTrees('a.gpkg')(doc);
      uncheckTrees('b.gpkg')(doc);
    });
    // その後、別の端末で sub が直されて同期で届いた（こかげマップが書いた sub.qgs、根の保存より新しい）
    final subDoc = QgsDocument.parse(File(qgsOf(sub)).readAsStringSync());
    subDoc.setStamp(KokageStamp(
      schemaVersion: kQgsSchemaVersion,
      app: 'test',
      savedAt: t.add(const Duration(minutes: 1)),
      dirName: 'sub',
    ));
    File(qgsOf(sub)).writeAsStringSync(subDoc.toXmlString());

    await const QgsReadBack().run(root);
    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(sub)).visibility.layers['b.gpkg/trees'] ?? true, isTrue,
        reason: 'sub のほうが新しいので、根の古い写しで巻き戻さない');
    expect((await KMetaService.instance.getMeta(proj)).visibility.layers['a.gpkg/trees'], isFalse);
  });

  test('子と根の両方が QGIS で直されたら、後に保存したほうが勝つ', () async {
    final root = await loadTree();
    await const QgsProjectBuilder().writeTo(root);
    final t = DateTime.now().add(const Duration(minutes: 1));

    // 先に sub.qgs で b を消灯、後で根で b を点灯しなおして保存
    qgisSave(qgsOf(sub), t, (doc) {
      doc.findAllElements('layer-tree-group').firstWhere((g) => g.getAttribute('name') == 'trees')
          .setAttribute('checked', 'Qt::Unchecked');
    });
    qgisSave(qgsOf(proj), t.add(const Duration(minutes: 1)), (_) {});

    await const QgsReadBack().run(root);
    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(sub)).visibility.layers['b.gpkg/trees'] ?? true, isTrue);

    // 逆順（根が先、sub が後）なら sub の消灯が勝つ
    await const QgsProjectBuilder().writeTo(root);
    qgisSave(qgsOf(proj), t.add(const Duration(minutes: 2)), (_) {});
    qgisSave(qgsOf(sub), t.add(const Duration(minutes: 3)), (doc) {
      doc.findAllElements('layer-tree-group').firstWhere((g) => g.getAttribute('name') == 'trees')
          .setAttribute('checked', 'Qt::Unchecked');
    });
    await const QgsReadBack().run(root);
    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(sub)).visibility.layers['b.gpkg/trees'], isFalse);
  });
}
