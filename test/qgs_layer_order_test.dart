// レイヤの並び = 描く順（2026-10-13）。
//
// QGIS と同じく、レイヤ一覧の上にあるものほど地図の手前に描く。並びは QGIS で保存された `.qgs` の
// レイヤツリーから読み戻し（フォルダ設定の `layout.sortOrder`）、開き直しても一覧が同じ並びになり、
// アプリが書く `.qgs` のツリーと `<layerorder>` も同じ並びになる。
// テクスチャでは面の塗りとオーバーレイ画像をこの並びで混ぜて重ねる（[composeTextureDraws]）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/layer_order.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/models/nodes/overlay_image_node.dart';
import 'package:root_maps/screens/map_page/widgets/terrain_texture_paint.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/services/qgis/qgs_xml.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

import 'support/legacy_geotiff.dart';

void main() {
  group('並びの当てはめ（applyLayerOrder）', () {
    String id(String s) => s;

    test('並びにある子の席だけを並びの順で埋め直す。無い子は既定の席のまま', () {
      expect(
        applyLayerOrder(['a.gpkg', 'b.gpkg', 'ortho.tif'], ['ortho.tif', 'a.gpkg'], id),
        ['ortho.tif', 'b.gpkg', 'a.gpkg'],
      );
      // 写真（.qgs に出ない）は最後の席のまま
      expect(
        applyLayerOrder(['sub', 'a.gpkg', 'ortho.tif', 'photo.jpg'], ['ortho.tif', 'a.gpkg', 'sub'], id),
        ['ortho.tif', 'a.gpkg', 'sub', 'photo.jpg'],
      );
    });

    test('あとから足したファイルは既定の席（種類順）に入る。オルソの下に潜らない', () {
      // 並び [ortho.tif, a.gpkg] のあとに new.gpkg を足した（名前順で a の後ろ）
      expect(
        applyLayerOrder(['a.gpkg', 'new.gpkg', 'ortho.tif'], ['ortho.tif', 'a.gpkg'], id),
        ['ortho.tif', 'new.gpkg', 'a.gpkg'],
      );
    });

    test('並びが無い・1 つしか当たらないなら既定のまま（同じリストを返す）', () {
      final defaults = ['a', 'b'];
      expect(identical(applyLayerOrder(defaults, null, id), defaults), isTrue);
      expect(identical(applyLayerOrder(defaults, ['b'], id), defaults), isTrue);
    });

    test('sortByPosition は位置の小さい順、位置の無いものは外す', () {
      final pos = {'a': 3, 'b': 1, 'c': null};
      expect(sortByPosition(['a', 'b', 'c'], (s) => pos[s]), ['b', 'a']);
    });
  });

  group('テクスチャに重ねる順（composeTextureDraws）', () {
    test('ラスタが面より上（段が大きい）なら面の後に描く', () {
      // 面 2 件（段 0）、オルソ（段 1）
      expect(composeTextureDraws(fillRanks: [0, 0], overlayRanks: [1]), [const FillRun(0, 2), const OverlayDraw(0)]);
    });

    test('ラスタが面より下なら先に描く（オルソはいつも一番下）', () {
      expect(composeTextureDraws(fillRanks: [1, 1], overlayRanks: [0]), [const OverlayDraw(0), const FillRun(0, 2)]);
    });

    test('面のレイヤの間にラスタを挟む。ラスタどうしも段の順', () {
      // 面: 段 0 が 1 件・段 2 が 2 件・段 4 が 1 件。ラスタ: 段 3・段 1（渡した順と段の順が逆）・段 5
      expect(
        composeTextureDraws(fillRanks: [0, 2, 2, 4], overlayRanks: [3, 1, 5]),
        [
          const FillRun(0, 1),
          const OverlayDraw(1),
          const FillRun(1, 3),
          const OverlayDraw(0),
          const FillRun(3, 4),
          const OverlayDraw(2),
        ],
      );
    });

    test('面もラスタも無ければ空、ラスタだけなら段の順', () {
      expect(composeTextureDraws(fillRanks: const [], overlayRanks: const []), isEmpty);
      expect(composeTextureDraws(fillRanks: const [], overlayRanks: [2, 0]), [const OverlayDraw(1), const OverlayDraw(0)]);
    });
  });

  group('.qgs のレイヤツリーとの往復', () {
    late Directory tmp;
    late String proj;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      KMetaService.instance.clearCache();
      tmp = await Directory.systemTemp.createTemp('qgs_order_');
      proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
      ProjectPathResolver.instance.setRootPathGetter(() => proj);
      final g = GeoPackageFile(['a.gpkg'], absolutePath: p.join(proj, 'a.gpkg'));
      await g.addLayer('big', GeometryType.polygon);
      await g.addLayer('small', GeometryType.polygon);
      await g.dispose();
      writeLegacyGeoTiff(
        p.join(proj, 'ortho.tif'),
        img.Image(width: 4, height: 3),
        const KMetaImageOverlay(centerLng: 135.97, centerLat: 33.94, scale: 2, imageWidth: 4, imageHeight: 3),
      );
    });

    tearDown(() async {
      KMetaService.instance.clearCache();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<FolderNode> loadTree() async {
      KMetaService.instance.clearCache();
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

    List<String> names(LayerTreeNode n) => [for (final c in n.children) c.name];

    /// QGIS でレイヤツリーを並べ替えた体: root 直下の要素を [order]（`name` 属性）の順に
    void reorderRoot(String qgs, List<String> order) {
      final doc = XmlDocument.parse(File(qgs).readAsStringSync());
      final tree = doc.rootElement.getElement('layer-tree-group')!;
      final items = tree.childElements.where((e) => e.name.local.startsWith('layer-tree-')).toList();
      for (final e in items) {
        tree.children.remove(e);
      }
      final sorted = [for (final n in order) items.firstWhere((e) => e.getAttribute('name') == n)];
      final at = tree.children.indexWhere((c) => c is XmlElement && c.name.local == 'custom-order');
      tree.children.insertAll(at < 0 ? tree.children.length : at, sorted);
      File(qgs).writeAsStringSync(doc.toXmlString());
    }

    /// gpkg グループの中のレイヤグループを [order] の順に
    void reorderLayers(String qgs, String gpkg, List<String> order) {
      final doc = XmlDocument.parse(File(qgs).readAsStringSync());
      final group = doc.findAllElements('layer-tree-group').firstWhere((g) => g.getAttribute('name') == gpkg);
      final items = group.childElements.where((e) => e.name.local == 'layer-tree-group').toList();
      for (final e in items) {
        group.children.remove(e);
      }
      group.children.addAll([for (final n in order) items.firstWhere((e) => e.getAttribute('name') == n)]);
      File(qgs).writeAsStringSync(doc.toXmlString());
    }

    test('既定は種類順（gpkg → 画像）で、書く .qgs のツリーも同じ順', () async {
      final root = await loadTree();
      expect(names(root), ['a.gpkg', 'ortho.tif']);
      final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
      final doc = XmlDocument.parse(File(qgs).readAsStringSync());
      final tree = doc.rootElement.getElement('layer-tree-group')!;
      expect(
        [for (final e in tree.childElements.where((e) => e.name.local.startsWith('layer-tree-'))) e.getAttribute('name')],
        ['a.gpkg', 'ortho'],
      );
    });

    test('QGIS でラスタを面の上に動かしたら、一覧も描く順もラスタが上。開き直しても・書き戻しても同じ', () async {
      final root = await loadTree();
      final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
      reorderRoot(qgs, ['ortho', 'a.gpkg']);

      await const QgsImporter().import(qgs, root);
      expect(names(root), ['ortho.tif', 'a.gpkg'], reason: '一覧の並びは QGIS のツリーの並び');
      KMetaService.instance.clearCache();
      expect((await KMetaService.instance.getMeta(proj)).layout.sortOrder, containsAllInOrder(['ortho.tif', 'a.gpkg']));

      // 描く順: ラスタの段が面のレイヤより大きい（手前）
      final ranks = drawRanksOf(drawOrderOf(root));
      final ortho = root.children.whereType<OverlayImageNode>().single;
      final layers = root.children.whereType<GeoPackageNode>().single.children.whereType<LayerNode>();
      for (final l in layers) {
        expect(ranks[ortho], greaterThan(ranks[l]!), reason: '${l.layerName} よりラスタが手前');
      }

      // 開き直しても同じ並び
      final reopened = await loadTree();
      expect(names(reopened), ['ortho.tif', 'a.gpkg']);

      // アプリが書き戻す .qgs も同じ並び（ツリーと <layerorder>）
      await const QgsProjectBuilder().writeTo(reopened);
      final doc = XmlDocument.parse(File(qgs).readAsStringSync());
      final tree = doc.rootElement.getElement('layer-tree-group')!;
      expect(
        [for (final e in tree.childElements.where((e) => e.name.local.startsWith('layer-tree-'))) e.getAttribute('name')],
        ['ortho', 'a.gpkg'],
      );
      final order = doc.rootElement.getElement('layerorder')!.findElements('layer').map((e) => e.getAttribute('id')).toList();
      expect(order.first, startsWith('raster_'), reason: '<layerorder> の先頭（最前面）もラスタ');
      expect(qgsTreeLayerIds(doc), order, reason: 'ツリーと <layerorder> が同じ並び');
    });

    test('QGIS でラスタが面の下（既定と同じ並び）なら何も書かない', () async {
      final root = await loadTree();
      final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
      reorderRoot(qgs, ['a.gpkg', 'ortho']);

      await const QgsImporter().import(qgs, root);
      expect(names(root), ['a.gpkg', 'ortho.tif']);
      KMetaService.instance.clearCache();
      expect((await KMetaService.instance.getMeta(proj)).layout.sortOrder, isNull, reason: '並びの設定を増やさない');
      final ranks = drawRanksOf(drawOrderOf(root));
      final ortho = root.children.whereType<OverlayImageNode>().single;
      final layers = root.children.whereType<GeoPackageNode>().single.children.whereType<LayerNode>();
      for (final l in layers) {
        expect(ranks[ortho], lessThan(ranks[l]!), reason: 'ラスタは ${l.layerName} の下');
      }
    });

    test('gpkg の中のレイヤの並びも読み戻す（`gpkg名/レイヤ名`）', () async {
      final root = await loadTree();
      final gpkg = root.children.whereType<GeoPackageNode>().single;
      final before = [for (final l in gpkg.children.whereType<LayerNode>()) l.layerName];
      final qgs = (await const QgsProjectBuilder().writeTo(root))!.path;
      final swapped = before.reversed.toList();
      reorderLayers(qgs, 'a.gpkg', swapped);

      await const QgsImporter().import(qgs, root);
      expect([for (final l in gpkg.children.whereType<LayerNode>()) l.layerName], swapped);
      KMetaService.instance.clearCache();
      expect(
        (await KMetaService.instance.getMeta(proj)).layout.sortOrder,
        containsAllInOrder([for (final n in swapped) 'a.gpkg/$n']),
      );

      final reopened = await loadTree();
      final g2 = reopened.children.whereType<GeoPackageNode>().single;
      expect([for (final l in g2.children.whereType<LayerNode>()) l.layerName], swapped);
    });

    test('gpkg を改名しても並びのレイヤのキーが付いてくる', () async {
      await KMetaService.instance.setSortOrder(proj, ['ortho.tif', 'a.gpkg', 'a.gpkg/small', 'a.gpkg/big']);
      await KMetaService.instance.renameGeoPackageKeys(proj, oldName: 'a.gpkg', newName: 'b.gpkg', layerNames: const {'big': 'large'});
      KMetaService.instance.clearCache();
      expect(
        (await KMetaService.instance.getMeta(proj)).layout.sortOrder,
        ['ortho.tif', 'b.gpkg', 'b.gpkg/small', 'b.gpkg/large'],
      );
    });
  });
}
