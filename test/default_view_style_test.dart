// 既定 View 1 枚だけのレイヤで View に付けたスタイルは、レイヤのスタイルとして残す（2026-10-02）。
//
// 既定 View 1 枚は「View 未定義」と同じ扱いでフォルダ設定に書かない。以前は View ごと捨てていたので、
// そこに付けた色・濃さも消え、開き直すと元に戻っていた（チュートリアルの「見え方を変える」で踏んだ）。
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/view_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    tmp = await Directory.systemTemp.createTemp('default_view_style_');
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

  Future<LayerNode> loadLayer() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    final gpkg = root.children.whereType<GeoPackageNode>().single;
    await gpkg.updateChildren();
    return gpkg.children.whereType<LayerNode>().single;
  }

  test('既定 View に付けたスタイルはレイヤのスタイルとして残り、開き直しても効く', () async {
    final layer = await loadLayer();
    expect(layer.views.single.isDefaultView, isTrue);

    layer.views.single.style = const KMetaLayerStyle(polygonFillColor: Color(0xFFFF0000), polygonFillOpacity: 0.6);
    await layer.persistViews();

    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(proj);
    final style = meta.styles.layers['a.gpkg/area'];
    expect(style?.polygonFillOpacity, 0.6);
    expect(style?.polygonFillColor, const Color(0xFFFF0000));
    expect(meta.views['a.gpkg/area'], isNull, reason: '既定 View 1 枚は書かない');

    final reopened = await loadLayer();
    expect((await reopened.getKmetaStyle())?.polygonFillOpacity, 0.6);
  });

  test('View がほかにあっても、既定 View のスタイルはレイヤのスタイルになる', () async {
    final layer = await loadLayer();
    layer.views.single.style = const KMetaLayerStyle(polygonFillOpacity: 0.4);
    layer.views.add(ViewNode(name: '大きい', parent: layer, filter: 'fid > 1', style: const KMetaLayerStyle(polygonFillOpacity: 0.9)));
    await layer.persistViews();

    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(proj);
    expect(meta.styles.layers['a.gpkg/area']?.polygonFillOpacity, 0.4);
    final saved = meta.views['a.gpkg/area']!;
    expect(saved.map((v) => v.name), ['既定', '大きい']);
    expect(saved.first.style, isNull, reason: '既定 View はスタイルを持たない');
    expect(saved.last.style?.polygonFillOpacity, 0.9);
  });

  test('既定 View の変更は、レイヤのほかの設定を消さずに重ねる', () async {
    await KMetaService.instance.setLayerStyle(proj, 'a.gpkg/area', const KMetaLayerStyle(polygonBorderWidth: 3));
    final layer = await loadLayer();
    layer.views.single.style = const KMetaLayerStyle(polygonFillOpacity: 0.5);
    await layer.persistViews();

    KMetaService.instance.clearCache();
    final style = (await KMetaService.instance.getMeta(proj)).styles.layers['a.gpkg/area'];
    expect(style?.polygonBorderWidth, 3);
    expect(style?.polygonFillOpacity, 0.5);
  });
}
