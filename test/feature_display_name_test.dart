// 地物の表示名: QGIS で作った name 列の無いレイヤで「名前なし」を出さない（ホスト VM）。
//
// 2026-10-12 に Pixel 9 で、小班のレイヤ（列は fid・林班・小班・林小班・樹種…）の情報パネルに
// 「name: 名前なし」、検索の結果に「小班 › 名前なし」が出ていた。
// 表示名は QGIS の表示名の式（`<previewExpression>`）→ ラベルの式 → name 列の順に探す
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/qgis_form.dart';
import 'package:root_maps/presentation/feature_display_name.dart';
import 'package:root_maps/services/qgis/qgs_form_reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('display_name_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
  });

  tearDown(() async {
    await gpkg.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<PolygonLayerNode> shohan({Map<String, String>? extra, Map<String, Object?>? extraAttrs}) async {
    await gpkg.addLayer('小班', GeometryType.polygon);
    await gpkg.addAttributeColumns('小班', {'林班': 'INTEGER', '小班': 'TEXT', '林小班': 'TEXT', '樹種': 'TEXT', ...?extra});
    const ring = [LatLng(33.0, 135.0), LatLng(33.0, 135.1), LatLng(33.1, 135.1), LatLng(33.0, 135.0)];
    await gpkg.addPolygonWithAttributes('小班', [ring], {'林班': 12, '小班': 'い', '林小班': '12-い', '樹種': 'スギ', ...?extraAttrs});
    final layer = PolygonLayerNode(gpkg, '小班', parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
    return layer;
  }

  test('name 列の無いレイヤ: 情報パネルに name の行を出さず、表示名も無い。見分けは列から', () async {
    final layer = await shohan();
    final f = layer.features.single;
    expect(f.infoMap.containsKey('name'), isFalse);
    expect(f.infoMap['林小班'], '12-い');
    expect(featureDisplayName(f), isNull);
    expect(featureQgisDisplayName(f), isNull);
    // 当たった列（林班）は除き、文字の列を先に 2 つ
    expect(featureIdentifier(f, excludeColumn: '林班'), '小班: い / 林小班: 12-い');
  });

  test('name 列があれば先頭に出し、表示名にも使う', () async {
    final layer = await shohan(extra: {'name': 'TEXT'}, extraAttrs: {'name': '北の山'});
    final f = layer.features.single;
    expect(f.infoMap.keys.first, 'name');
    expect(featureDisplayName(f), '北の山');
    expect(featureIdentifier(f, excludeColumn: '林班'), '北の山');
    // 当たった値そのものなら列から作る（同じ文字を 2 度見せない）
    expect(featureIdentifier(f, excludeColumn: 'name', exclude: '北の山'), '小班: い / 林小班: 12-い');
  });

  test('QGIS の表示名の式があれば使う。列 1 つだけの式は情報パネルに別の行として出さない', () async {
    final layer = await shohan();
    final f = layer.features.single;
    layer.debugDisplayExpression = "concat(\"林班\", '-', \"小班\")";
    expect(featureDisplayName(f), '12-い');
    expect(featureQgisDisplayName(f), '12-い');
    layer.debugDisplayExpression = '"林小班"';
    expect(featureDisplayName(f), '12-い');
    expect(featureQgisDisplayName(f), isNull);
  });

  test('.qgs の <previewExpression> を読み、フォルダ設定に往復する。空なら持たない', () {
    XmlElement maplayer(String preview) =>
        XmlDocument.parse('<maplayer><previewExpression>$preview</previewExpression></maplayer>').rootElement;
    final form = QgsFormReader.read(maplayer('"林小班"'));
    expect(form?.displayExpression, '"林小班"');
    expect(QgisForm.fromJson(form!.toJson()).displayExpression, '"林小班"');
    expect(form.withFields(const {}).displayExpression, '"林小班"');
    expect(QgsFormReader.read(maplayer('')), isNull);
  });
}
