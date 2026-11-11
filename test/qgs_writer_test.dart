// `.qgs`（QGISプロジェクト）ライターのテスト
//
// > [!WARNING] ここで確かめられるのは「XMLの形」まで
// > **QGISで実際に開けるかは、このテストでは分からない。**
// > 開発機にQGISが入っていないため未検証（2026-08-26）。
// > 実機確認したら docs/technical/qgis-interop.md に結果を残すこと。
//
// 検証するのは、設計上ここが崩れたら意味が無くなる点:
//   1. dir / GeoPackage / Layer がグループ、View だけがレイヤになる（1:1対応）
//   2. `layer-tree-layer` と `maplayer` のIDが一致する（一致しないとQGISが結べない）
//   3. IDが決定的（毎回変わると .qgs の差分が出てDrive同期が無駄に動く）
//   4. フィルタが OGR のデータソースURIに `|subset=` として載る
//   5. パスが相対で書かれる（連携dirを単体で渡された人が開けるように）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_writer.dart';
import 'package:xml/xml.dart';

QgsLayer makeLayer(
  String name, {
  String? subset,
  GeometryType geometry = GeometryType.point,
  QgsStyle? style,
  bool visible = true,
}) => QgsLayer(
  id: 'id_$name',
  name: name,
  dataSourcePath: './区画.gpkg',
  tableName: 'parcels',
  geometryType: geometry,
  crs: QgsCrs.wgs84,
  subset: subset,
  style: style,
  visible: visible,
);

void main() {
  const writer = QgsWriter();

  group('レイヤツリーの構造', () {
    test('dir / gpkg / Layer はグループ、View だけがレイヤになる', () {
      final project = QgsProject(
        name: 'テストプロジェクト',
        root: [
          QgsGroup(
            name: '2026年度',
            children: [
              QgsGroup(
                name: '区画.gpkg',
                children: [
                  QgsGroup(
                    name: 'parcels',
                    children: [
                      makeLayer('A種', subset: "区分 = 'A種'"),
                      makeLayer('B種', subset: "区分 = 'B種'"),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      final doc = XmlDocument.parse(writer.build(project));
      final tree = doc.rootElement.findElements('layer-tree-group').single;

      // グループは dir → gpkg → Layer の3段
      final dir = tree.findElements('layer-tree-group').single;
      expect(dir.getAttribute('name'), '2026年度');
      final gpkg = dir.findElements('layer-tree-group').single;
      expect(gpkg.getAttribute('name'), '区画.gpkg');
      final layer = gpkg.findElements('layer-tree-group').single;
      expect(layer.getAttribute('name'), 'parcels');

      // レイヤは View のぶんだけ
      final treeLayers = layer.findElements('layer-tree-layer').toList();
      expect(treeLayers.map((e) => e.getAttribute('name')), ['A種', 'B種']);

      // maplayer も同数
      final mapLayers = doc.rootElement
          .findElements('projectlayers')
          .single
          .findElements('maplayer');
      expect(mapLayers.length, 2);
    });

    test('layer-tree-layer と maplayer のIDが一致する', () {
      final project = QgsProject(
        name: 'p',
        root: [
          QgsGroup(name: 'g', children: [makeLayer('A種'), makeLayer('B種')]),
        ],
      );
      final doc = XmlDocument.parse(writer.build(project));

      final treeIds = doc.rootElement
          .findAllElements('layer-tree-layer')
          .map((e) => e.getAttribute('id'))
          .toList();
      final mapIds = doc.rootElement
          .findAllElements('maplayer')
          .map((e) => e.findElements('id').single.innerText)
          .toList();
      final orderIds = doc.rootElement
          .findElements('layerorder')
          .single
          .findElements('layer')
          .map((e) => e.getAttribute('id'))
          .toList();

      expect(mapIds, treeIds, reason: 'IDが違うとQGISがツリーとレイヤを結べない');
      expect(orderIds, treeIds, reason: '描画順もツリーの並びと揃える');
    });

    test('非表示は Qt::Unchecked になる', () {
      final project = QgsProject(
        name: 'p',
        root: [
          QgsGroup(
            name: 'g',
            visible: false,
            children: [makeLayer('隠す', visible: false)],
          ),
        ],
      );
      final doc = XmlDocument.parse(writer.build(project));
      expect(
        doc.rootElement
            .findAllElements('layer-tree-group')
            .last
            .getAttribute('checked'),
        'Qt::Unchecked',
      );
      expect(
        doc.rootElement
            .findAllElements('layer-tree-layer')
            .single
            .getAttribute('checked'),
        'Qt::Unchecked',
      );
    });
  });

  group('データソース', () {
    test('フィルタが |subset= として載る', () {
      final layer = makeLayer('A種', subset: "区分 = 'A種' AND 面積 > 10");
      expect(
        layer.dataSourceUri,
        "./区画.gpkg|layername=parcels|subset=区分 = 'A種' AND 面積 > 10",
      );
    });

    test('フィルタが無ければ |subset= を付けない', () {
      expect(
        makeLayer('全部').dataSourceUri,
        './区画.gpkg|layername=parcels',
      );
    });

    test('相対パスを絶対パスに書き換えない', () {
      final project = QgsProject(
        name: 'p',
        root: [
          QgsGroup(name: 'g', children: [makeLayer('A種')]),
        ],
      );
      final xml = writer.build(project);
      expect(xml, contains('./区画.gpkg'));
      expect(xml, isNot(contains('C:')), reason: '絶対パスが混ざると他人の環境で開けない');
      // 相対パスで解決させる設定も要る
      expect(xml, contains('<Absolute type="bool">false</Absolute>'));
    });

    test('XMLとして正しくエスケープされる', () {
      final project = QgsProject(
        name: 'p',
        root: [
          QgsGroup(name: 'g', children: [makeLayer('大', subset: 'area > 105')]),
        ],
      );
      final doc = XmlDocument.parse(writer.build(project));
      // パースして戻したときに元の `>` に復元されること
      final datasource =
          doc.rootElement.findAllElements('datasource').single.innerText;
      expect(datasource, endsWith('|subset=area > 105'));
    });
  });

  group('レンダラ', () {
    test('スタイルが無ければレンダラを書かない（QGISの既定に任せる）', () {
      final project = QgsProject(
        name: 'p',
        root: [
          QgsGroup(name: 'g', children: [makeLayer('A種')]),
        ],
      );
      final doc = XmlDocument.parse(writer.build(project));
      expect(doc.rootElement.findAllElements('renderer-v2'), isEmpty);
    });

    test('ジオメトリ種別に応じたシンボル型になる', () {
      const style = QgsStyle(pointSizePx: 8, lineWidthPx: 4);
      for (final (geometry, symbolType, layerClass) in [
        (GeometryType.point, 'marker', 'SimpleMarker'),
        (GeometryType.linestring, 'line', 'SimpleLine'),
        (GeometryType.polygon, 'fill', 'SimpleFill'),
      ]) {
        final project = QgsProject(
          name: 'p',
          root: [
            QgsGroup(
              name: 'g',
              children: [makeLayer('v', geometry: geometry, style: style)],
            ),
          ],
        );
        final doc = XmlDocument.parse(writer.build(project));
        final symbol = doc.rootElement.findAllElements('symbol').single;
        expect(symbol.getAttribute('type'), symbolType);
        expect(
          symbol.findAllElements('layer').single.getAttribute('class'),
          layerClass,
        );
      }
    });

    test('色は QGIS の R,G,B,A 形式で書く', () {
      final project = QgsProject(
        name: 'p',
        root: [
          QgsGroup(
            name: 'g',
            children: [
              makeLayer(
                'v',
                style: const QgsStyle(pointColor: Color(0xFF1E90FF)),
              ),
            ],
          ),
        ],
      );
      final doc = XmlDocument.parse(writer.build(project));
      final color = doc.rootElement
          .findAllElements('Option')
          .firstWhere((e) => e.getAttribute('name') == 'color')
          .getAttribute('value');
      expect(color, '30,144,255,255');
    });
  });

  test('プロジェクト全体がパースできる最小構成になっている', () {
    const project = QgsProject(name: '空っぽ', root: []);
    final doc = XmlDocument.parse(writer.build(project));
    expect(doc.rootElement.name.local, 'qgis');
    expect(doc.rootElement.getAttribute('version'), kQgsVersion);
    // レイヤが0本でも、QGISが探す要素は揃えておく
    expect(doc.rootElement.findElements('layer-tree-group').length, 1);
    expect(doc.rootElement.findElements('projectlayers').length, 1);
    expect(doc.rootElement.findElements('projectCrs').length, 1);
  });
}
