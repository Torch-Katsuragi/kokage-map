// DOM 保持型 `.qgs` 文書のテスト
//
// 確かめるのは、正典を `.qgs` に移すうえで崩れたら意味が無くなる点:
//   1. QGIS が書いた未知のノード（レイアウト・ブックマーク・フィールド設定…）が往復で残る
//   2. 自分の管轄（参照・フィルタ・単一シンボルの色）は直り、知らないプロパティは残る
//   3. project に無いレイヤは外して報告する。埋め込みのものは残す
//   4. 印（kokage 名前空間）の往復と「最後に書いたのは自分か」の判定
//   5. レイヤ id がプラットフォームに依らず決定的
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:root_maps/utils/stable_hash.dart';
import 'package:xml/xml.dart';

String fixture() => File('test/fixtures/qgis_3_44_written.qgs').readAsStringSync();

/// フィクスチャ内の「林小班」グループにある2つの root 内レイヤの id
const idSugi = '___56902204_7d58_4032_ab25_8588e0e0aa73';
const idAll = '___574d01b1_4fc4_44f8_8645_634a0a308fca';

QgsLayer layer(
  String id,
  String name, {
  String? subset,
  QgsStyle? style,
  bool visible = true,
}) => QgsLayer(
  id: id,
  name: name,
  dataSourcePath: './林小班.gpkg',
  tableName: 'rinshoban',
  geometryType: GeometryType.point,
  crs: QgsCrs.wgs84,
  subset: subset,
  style: style,
  visible: visible,
);

QgsProject projectFromFixture({QgsStyle? sugiStyle, String? sugiSubset = 'area > 200'}) =>
    QgsProject(
      name: 'テスト',
      root: [
        QgsGroup(
          name: '林小班',
          children: [
            layer(idSugi, 'スギ', subset: sugiSubset, style: sugiStyle),
            layer(idAll, '全部', visible: false),
          ],
        ),
      ],
    );

String? optionValue(XmlElement symbolLayer, String name) => symbolLayer
    .findElements('Option')
    .where((o) => o.getAttribute('type') == 'Map')
    .first
    .findElements('Option')
    .where((o) => o.getAttribute('name') == name)
    .firstOrNull
    ?.getAttribute('value');

void main() {
  group('未知のノードを残す', () {
    test('QGIS が書いた最上位要素とレイヤ内の要素が往復で残る', () {
      final doc = QgsDocument.parse(fixture());
      doc.apply(projectFromFixture());
      final out = XmlDocument.parse(doc.toXmlString());
      final root = out.rootElement;

      for (final name in ['Layouts', 'Bookmarks', 'snapping-settings', 'relations', 'visibility-presets']) {
        expect(root.getElement(name), isNotNull, reason: '$name が消えた');
      }
      final sugi = out.findAllElements('maplayer').firstWhere(
        (e) => e.getElement('id')!.innerText == idSugi,
      );
      for (final name in ['fieldConfiguration', 'editform', 'map-layer-style-manager', 'extent']) {
        expect(sugi.getElement(name), isNotNull, reason: 'maplayer の $name が消えた');
      }
      // QGIS 固有の属性も残る
      expect(sugi.getAttribute('simplifyAlgorithm'), '0');
      // properties の他スコープも残る
      expect(root.getElement('properties')!.getElement('Paths'), isNotNull);
    });

    test('ツリー要素の customproperties を引き継ぐ', () {
      final doc = QgsDocument.parse(fixture());
      doc.apply(projectFromFixture());
      final tree = doc.root.getElement('layer-tree-group')!;
      final group = tree.findElements('layer-tree-group').single;
      expect(group.getAttribute('name'), '林小班');
      expect(group.getElement('customproperties'), isNotNull);
      final layers = group.findElements('layer-tree-layer').toList();
      expect(layers.map((l) => l.getAttribute('id')), [idSugi, idAll]);
      expect(layers.first.getElement('customproperties'), isNotNull);
      // QGIS が付けた属性も残る
      expect(layers.first.getAttribute('legend_split_behavior'), '0');
      expect(tree.getElement('custom-order'), isNotNull);
    });
  });

  group('自分の管轄だけ直す', () {
    test('フィルタと可視性が更新される', () {
      final doc = QgsDocument.parse(fixture());
      doc.apply(projectFromFixture(sugiSubset: "樹種 = 'スギ'"));
      final sugi = doc.findMapLayer(idSugi)!;
      expect(sugi.getElement('datasource')!.innerText, "./林小班.gpkg|layername=rinshoban|subset=樹種 = 'スギ'");
      final tree = doc.root.getElement('layer-tree-group')!;
      final all = tree.findAllElements('layer-tree-layer').firstWhere((l) => l.getAttribute('id') == idAll);
      expect(all.getAttribute('checked'), 'Qt::Unchecked');
    });

    test('単一シンボルは色だけ差し替え、知らないプロパティは残る', () {
      final doc = QgsDocument.parse(fixture());
      final symbolBefore = doc.findMapLayer(idSugi)!.getElement('renderer-v2')!
          .findAllElements('layer').first;
      final outlineBefore = optionValue(symbolBefore, 'outline_color');
      expect(outlineBefore, isNotNull);

      doc.apply(projectFromFixture(sugiStyle: const QgsStyle(pointColor: Color(0xFF00FF00))));
      final renderer = doc.findMapLayer(idSugi)!.getElement('renderer-v2')!;
      final symbolLayer = renderer.findAllElements('layer').first;
      expect(optionValue(symbolLayer, 'color'), '0,255,0,255');
      expect(optionValue(symbolLayer, 'outline_color'), outlineBefore);
      // data_defined_properties は触らない
      expect(renderer.findAllElements('data_defined_properties'), isNotEmpty);
    });

    test('単一シンボル以外のレンダラは触らず報告する', () {
      final doc = QgsDocument.parse(fixture());
      final renderer = doc.findMapLayer(idSugi)!.getElement('renderer-v2')!;
      renderer.setAttribute('type', 'categorizedSymbol');
      final before = renderer.toXmlString();

      final report = doc.apply(projectFromFixture(sugiStyle: const QgsStyle(pointColor: Color(0xFF00FF00))));
      expect(report.untouchedRenderers, [idSugi]);
      expect(doc.findMapLayer(idSugi)!.getElement('renderer-v2')!.toXmlString(), before);
    });

    test('project に無いレイヤは外して報告する', () {
      final doc = QgsDocument.parse(fixture());
      expect(doc.mapLayers.length, 3);
      final report = doc.apply(projectFromFixture());
      expect(doc.mapLayers.length, 2);
      expect(report.removedLayers, ['root外']);
      final order = doc.root.getElement('layerorder')!.findElements('layer').map((l) => l.getAttribute('id'));
      expect(order, [idSugi, idAll]);
    });

    test('同じ id の maplayer が重複していたら1つに畳む', () {
      final doc = QgsDocument.parse(fixture());
      final sugi = doc.findMapLayer(idSugi)!;
      sugi.parent!.children.add(sugi.copy());
      expect(doc.mapLayers.where((e) => e.getElement('id')!.innerText == idSugi).length, 2);
      final report = doc.apply(projectFromFixture());
      expect(doc.mapLayers.where((e) => e.getElement('id')!.innerText == idSugi).length, 1);
      // 重複の整理は「外した」には数えない
      expect(report.removedLayers, ['root外']);
    });

    test('簡易ラベルは text-style の管轄属性だけ差し替え、無ければ足す', () {
      final doc = QgsDocument.parse(fixture());
      const style = QgsStyle(
        labelEnabled: true,
        labelField: 'name',
        labelFontSizePt: 9,
        labelColor: Color(0xFF112233),
      );
      doc.apply(projectFromFixture(sugiStyle: style));
      final sugi = doc.findMapLayer(idSugi)!;
      expect(sugi.getAttribute('labelsEnabled'), '1');
      final text = sugi.getElement('labeling')!.getElement('settings')!.getElement('text-style')!;
      expect(text.getAttribute('fieldName'), 'name');
      expect(text.getAttribute('fontSize'), '9.0');
      expect(text.getAttribute('textColor'), '17,34,51,255');

      // QGIS が足した属性は残り、こちらの値だけ更新される
      text.setAttribute('fontFamily', 'Noto Sans JP');
      doc.apply(projectFromFixture(sugiStyle: const QgsStyle(labelEnabled: true, labelField: 'code')));
      final text2 = doc.findMapLayer(idSugi)!.getElement('labeling')!.getElement('settings')!.getElement('text-style')!;
      expect(text2.getAttribute('fieldName'), 'code');
      expect(text2.getAttribute('fontFamily'), 'Noto Sans JP');

      // 無効にしても設定は残す（QGIS と同じ）
      doc.apply(projectFromFixture(sugiStyle: const QgsStyle(labelEnabled: false)));
      final sugi3 = doc.findMapLayer(idSugi)!;
      expect(sugi3.getAttribute('labelsEnabled'), '0');
      expect(sugi3.getElement('labeling'), isNotNull);
    });

    test('グループの展開状態が書かれる', () {
      final doc = QgsDocument.parse(fixture());
      final project = QgsProject(
        name: 'テスト',
        root: [
          QgsGroup(name: '林小班', expanded: false, children: [layer(idSugi, 'スギ'), layer(idAll, '全部')]),
        ],
      );
      doc.apply(project);
      final group = doc.root.getElement('layer-tree-group')!.findElements('layer-tree-group').single;
      expect(group.getAttribute('expanded'), '0');
    });

    test('子 dir の埋め込み: グループとスタブを書き、無くなった埋め込みは外す', () {
      final doc = QgsDocument.parse(fixture());
      // 手で足された（dir 構造に無い）埋め込みは外される
      final tree = doc.root.getElement('layer-tree-group')!;
      tree.children.add(
        XmlElement(const XmlName.parts('layer-tree-group'), [
          XmlAttribute(const XmlName.parts('name'), 'よそ'),
          XmlAttribute(const XmlName.parts('embedded'), '1'),
          XmlAttribute(const XmlName.parts('embedded_project'), '../よそ/よそ.qgs'),
        ]),
      );
      doc.root.getElement('projectlayers')!.children.add(
        XmlElement(const XmlName.parts('maplayer'), [
          XmlAttribute(const XmlName.parts('embedded'), '1'),
          XmlAttribute(const XmlName.parts('project'), '../よそ/よそ.qgs'),
          XmlAttribute(const XmlName.parts('id'), 'yoso_1'),
        ]),
      );

      final project = QgsProject(
        name: 'テスト',
        root: [
          ...projectFromFixture().root,
          const QgsEmbeddedGroup(
            name: '写真',
            projectPath: './写真/写真.qgs',
            layerIds: ['photo_a', 'photo_b'],
            expanded: false,
          ),
        ],
      );
      final report = doc.apply(project);
      expect(report.removedLayers, ['root外']);

      final groups = doc.root.getElement('layer-tree-group')!.findElements('layer-tree-group').toList();
      expect(groups.map((g) => g.getAttribute('name')), ['林小班', '写真']);
      final embedded = groups.last;
      expect(embedded.getAttribute('embedded'), '1');
      expect(embedded.getAttribute('embedded_project'), './写真/写真.qgs');
      expect(embedded.getAttribute('expanded'), '0');
      expect(embedded.findElements('layer-tree-layer'), isEmpty);

      final stubs = doc.mapLayers.where(QgsDocument.isEmbedded).toList();
      expect(stubs.map((s) => s.getAttribute('id')), ['photo_a', 'photo_b']);
      expect(stubs.first.getAttribute('project'), './写真/写真.qgs');
      final order = doc.root.getElement('layerorder')!.findElements('layer').map((l) => l.getAttribute('id'));
      expect(order, [idSugi, idAll, 'photo_a', 'photo_b']);

      // 2回目: 埋め込みが無くなれば普通のグループに戻り、スタブも消える
      final project2 = QgsProject(
        name: 'テスト',
        root: [...projectFromFixture().root, const QgsGroup(name: '写真', children: [])],
      );
      doc.apply(project2);
      final group2 = doc.root.getElement('layer-tree-group')!
          .findElements('layer-tree-group').firstWhere((g) => g.getAttribute('name') == '写真');
      expect(group2.getAttribute('embedded'), isNull);
      expect(doc.mapLayers.where(QgsDocument.isEmbedded), isEmpty);
    });

    test('無かったレイヤは writer の形で足される', () {
      final doc = QgsDocument.parse(fixture());
      final extra = layer('new_id', '新規', style: const QgsStyle(pointColor: Color(0xFFFF0000)));
      final project = QgsProject(
        name: 'テスト',
        root: [
          QgsGroup(name: '林小班', children: [layer(idSugi, 'スギ'), layer(idAll, '全部'), extra]),
        ],
      );
      doc.apply(project);
      final added = doc.findMapLayer('new_id')!;
      expect(added.getElement('renderer-v2'), isNotNull);
      expect(added.getElement('datasource')!.innerText, './林小班.gpkg|layername=rinshoban');
      final treeIds = doc.root.getElement('layer-tree-group')!
          .findAllElements('layer-tree-layer').map((l) => l.getAttribute('id'));
      expect(treeIds, contains('new_id'));
    });
  });

  group('印', () {
    final stamp = KokageStamp(
      schemaVersion: 1,
      app: 'kokage-map 0.6.1+18',
      savedAt: DateTime(2026, 9, 6, 15, 30, 0),
      savedBy: 'device-A',
      dirName: '写真',
    );

    test('往復して同じ値が読める。saveDateTime も揃う', () {
      final doc = QgsDocument.parse(fixture());
      expect(doc.stamp, isNull);
      expect(doc.lastWrittenByKokage, isFalse);

      doc.setStamp(stamp);
      final again = QgsDocument.parse(doc.toXmlString());
      final read = again.stamp!;
      expect(read.schemaVersion, 1);
      expect(read.app, 'kokage-map 0.6.1+18');
      expect(read.savedAt, DateTime(2026, 9, 6, 15, 30, 0));
      expect(read.savedBy, 'device-A');
      expect(read.dirName, '写真');
      expect(again.root.getAttribute('saveDateTime'), '2026-09-06T15:30:00');
      expect(again.lastWrittenByKokage, isTrue);
      // QGIS の他スコープは残る
      expect(again.root.getElement('properties')!.getElement('Paths'), isNotNull);
    });

    test('QGIS が保存し直すと「最後に書いたのは自分」でなくなる', () {
      final doc = QgsDocument.parse(fixture());
      doc.setStamp(stamp);
      doc.root.setAttribute('saveDateTime', '2026-09-06T18:00:00');
      expect(doc.stamp, isNotNull);
      expect(doc.lastWrittenByKokage, isFalse);
    });

    test('新規文書にも印が書ける', () {
      final doc = QgsDocument.create(projectName: '新規');
      doc.setStamp(stamp);
      doc.apply(projectFromFixture());
      final again = QgsDocument.parse(doc.toXmlString());
      expect(again.stamp?.dirName, '写真');
      expect(again.mapLayers.length, 2);
    });
  });

  group('レイヤ id', () {
    test('安定ハッシュは既知のベクタに一致する', () {
      // md5("abc") = 900150983cd24fb0d6963f7d28e17f72
      expect(stableHashHex('abc'), '900150983cd2');
      expect(stableHashHex('abc', length: 32), '900150983cd24fb0d6963f7d28e17f72');
    });

    test('View キーから決定的な id ができ、非ASCIIでも衝突しない', () {
      final a = QgsProjectBuilder.layerIdForViewKey('林小班.gpkg/rinshoban/スギ');
      final b = QgsProjectBuilder.layerIdForViewKey('林小班.gpkg/rinshoban/ヒノキ');
      expect(a, QgsProjectBuilder.layerIdForViewKey('林小班.gpkg/rinshoban/スギ'));
      expect(a, isNot(b));
      expect(a, matches(RegExp(r'^[A-Za-z0-9_]+$')));
    });

    test('同名の gpkg が別 dir にあっても id が衝突しない', () {
      const key = 'forest_roads.gpkg/forest_roads/既定';
      final root = QgsProjectBuilder.layerIdForViewKey(key);
      final rootDot = QgsProjectBuilder.layerIdForViewKey(key, dirPath: '.');
      final sub = QgsProjectBuilder.layerIdForViewKey(key, dirPath: './demo');
      final subNoDot = QgsProjectBuilder.layerIdForViewKey(key, dirPath: 'demo');
      expect(root, rootDot);
      expect(sub, subNoDot);
      expect(root, isNot(sub));
    });
  });
}
