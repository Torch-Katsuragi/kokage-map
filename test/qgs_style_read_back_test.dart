// QGIS で変えた色を読み戻す（View を作っていない既定のレイヤ）と、.qgz（QGIS の既定の保存形式）の読み込み。
//
// こかげマップが書いた .qgs を QGIS で開いて色を変えた体で、`<renderer-v2>` を書き足して取り込む
// （qgs_read_back_groups_test.dart と同じ作り）。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart' show Color;
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
    tmp = await Directory.systemTemp.createTemp('qgs_style_back_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    final g = GeoPackageFile(const ['a.gpkg'], absolutePath: p.join(proj, 'a.gpkg'));
    await g.addLayer('trees', GeometryType.point);
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

  String renderer(String type, String rgba) => '''
<renderer-v2 type="$type" attr="species">
  <symbols>
    <symbol name="0" type="marker">
      <layer class="SimpleMarker">
        <Option type="Map">
          <Option name="color" type="QString" value="$rgba"/>
          <Option name="size" type="QString" value="4"/>
        </Option>
      </layer>
    </symbol>
  </symbols>
</renderer-v2>''';

  /// QGIS で trees の描き方を変えて保存した体
  void restyle(String qgs, String rendererXml) {
    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    final layer = doc.findAllElements('maplayer').single;
    layer.findElements('renderer-v2').toList().forEach((e) => e.remove());
    layer.children.add(XmlDocument.parse(rendererXml).rootElement.copy());
    File(qgs).writeAsStringSync(doc.toXmlString());
  }

  Future<KMetaLayerStyle?> layerStyle() async {
    KMetaService.instance.clearCache();
    return (await KMetaService.instance.getMeta(proj)).styles.layers['a.gpkg/trees'];
  }

  test('QGIS で変えた色を、View の無いレイヤのスタイルに読み戻し、アプリだけの設定は残す', () async {
    final root = await loadTree();
    await KMetaService.instance.setLayerStyle(proj, 'a.gpkg/trees', const KMetaLayerStyle(labelOpacity: 0.5));
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    restyle(qgs, renderer('singleSymbol', '30,144,255,255'));

    final result = await const QgsImporter().import(qgs, root);
    expect(result.discarded, isEmpty);
    final style = (await layerStyle())!;
    expect(style.pointColor, const Color(0xFF1E90FF));
    expect(style.labelOpacity, 0.5, reason: 'QGIS が持たない設定（ラベルの濃さ）は消さない');
    expect(style.qgisRenderer, isNull);
  });

  test('QGIS で分類に変えたら印を付け、単一シンボルに戻したら外す', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;

    restyle(qgs, renderer('categorizedSymbol', '46,125,50,255'));
    await const QgsImporter().import(qgs, root);
    expect((await layerStyle())!.qgisRenderer, 'categorizedSymbol');

    restyle(qgs, renderer('singleSymbol', '255,0,0,255'));
    await const QgsImporter().import(qgs, root);
    final style = (await layerStyle())!;
    expect(style.qgisRenderer, isNull);
    expect(style.pointColor, const Color(0xFFFF0000));
  });

  test('View を足したレイヤでも、既定の描き方を単一シンボルに戻したら印を外す', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;

    /// QGIS で絞り込みのレイヤ（View）を 1 つ足した体
    void addFilteredCopy() {
      final doc = XmlDocument.parse(File(qgs).readAsStringSync());
      final layer = doc.findAllElements('maplayer').first;
      final copy = layer.copy();
      copy.findElements('id').single.innerText = 'filtered_copy';
      copy.findElements('layername').single.innerText = 'スギだけ';
      final ds = copy.findElements('datasource').single;
      ds.innerText = "${ds.innerText}|subset=\"species\" = 'sugi'";
      layer.parentElement!.children.add(copy);
      File(qgs).writeAsStringSync(doc.toXmlString());
    }

    restyle(qgs, renderer('categorizedSymbol', '46,125,50,255'));
    addFilteredCopy();
    final r1 = await const QgsImporter().import(qgs, root);
    expect(r1.viewsByLayer['a.gpkg/trees'], hasLength(2));
    expect((await layerStyle())!.qgisRenderer, 'categorizedSymbol');

    final doc = XmlDocument.parse(File(qgs).readAsStringSync());
    final def = doc.findAllElements('maplayer').firstWhere((m) => m.findElements('layername').single.innerText == 'trees');
    def.findElements('renderer-v2').toList().forEach((e) => e.remove());
    def.children.add(XmlDocument.parse(renderer('singleSymbol', '255,0,0,255')).rootElement.copy());
    File(qgs).writeAsStringSync(doc.toXmlString());
    await const QgsImporter().import(qgs, root);
    expect((await layerStyle())!.qgisRenderer, isNull);
  });

  test('.qgz（zip の中の .qgs）も同じように読む', () async {
    final root = await loadTree();
    final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
    restyle(qgs, renderer('singleSymbol', '30,144,255,255'));
    final bytes = File(qgs).readAsBytesSync();
    final zip = Archive()
      ..addFile(ArchiveFile('proj_data.qgd', 1, [0]))
      ..addFile(ArchiveFile('proj.qgs', bytes.length, bytes));
    final qgz = p.join(proj, 'proj.qgz');
    File(qgz).writeAsBytesSync(ZipEncoder().encode(zip));
    File(qgs).deleteSync();

    expect(await QgsImporter.readQgsText(qgz), contains('<projectlayers>'));
    final result = await const QgsImporter().import(qgz, root);
    expect(result.discarded, isEmpty);
    expect((await layerStyle())!.pointColor, const Color(0xFF1E90FF));
  });

  test('.qgs の入っていない .qgz・XML でないファイルは取り込まずに理由を返す', () async {
    final root = await loadTree();
    final empty = p.join(proj, 'empty.qgz');
    File(empty).writeAsBytesSync(ZipEncoder().encode(Archive()..addFile(ArchiveFile('x.txt', 1, [65]))));
    final r1 = await const QgsImporter().import(empty, root);
    expect(r1.isEmpty, isTrue);
    expect(r1.discarded, hasLength(1));

    final broken = p.join(proj, 'broken.qgs');
    File(broken).writeAsStringSync('<qgis><projectlayers>');
    final r2 = await const QgsImporter().import(broken, root);
    expect(r2.isEmpty, isTrue);
    expect(r2.discarded.single, contains('XML'));
  });
}
