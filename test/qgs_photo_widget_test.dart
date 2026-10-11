// `.qgs` の写真の欄（ExternalResource）: アプリが作った写真の列にだけ書き、ユーザーの設定は残す
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_model.dart';
import 'package:xml/xml.dart';

const _id = 'pts_1';

QgsProject _project({List<String> photoFields = const [], String path = './調査.gpkg'}) => QgsProject(
      name: 'テスト',
      root: [
        QgsGroup(name: '調査.gpkg', children: [
          QgsLayer(
            id: _id,
            name: '既定',
            dataSourcePath: path,
            tableName: 'pts',
            geometryType: GeometryType.point,
            crs: QgsCrs.wgs84,
            photoFields: photoFields,
          ),
        ]),
      ],
    );

XmlElement? _widget(QgsDocument doc, String field) => doc
    .findMapLayer(_id)
    ?.getElement('fieldConfiguration')
    ?.findElements('field')
    .where((f) => f.getAttribute('name') == field)
    .firstOrNull
    ?.getElement('editWidget');

String? _option(XmlElement widget, String name) => widget
    .descendantElements
    .where((o) => o.name.local == 'Option' && o.getAttribute('name') == name)
    .firstOrNull
    ?.getAttribute('value');

void main() {
  test('アプリが作った写真の列に ExternalResource を書く（gpkg と同じ dir はプロジェクトからの相対）', () {
    final doc = QgsDocument.create(projectName: 'テスト')..apply(_project(photoFields: ['photo', 'photo_2']));
    for (final f in ['photo', 'photo_2']) {
      final w = _widget(doc, f)!;
      expect(w.getAttribute('type'), 'ExternalResource');
      expect(_option(w, 'RelativeStorage'), '1');
      expect(_option(w, 'DocumentViewer'), '1');
      expect(_option(w, 'StorageMode'), '0');
      expect(_option(w, 'expression'), isNull);
    }
  });

  test('写真の列を作っていなければ何も書かない（ユーザーが作った同名の列には付けない）', () {
    final doc = QgsDocument.create(projectName: 'テスト')..apply(_project());
    expect(doc.findMapLayer(_id)!.getElement('fieldConfiguration'), isNull);
  });

  test('gpkg が下の dir なら既定のパスからの相対にし、根を式で与える', () {
    final doc = QgsDocument.create(projectName: 'テスト')
      ..apply(_project(photoFields: ['photo'], path: "./区域'A/調査.gpkg"));
    final w = _widget(doc, 'photo')!;
    expect(_option(w, 'RelativeStorage'), '2');
    expect(_option(w, 'expression'), "@project_folder || '/区域''A'");
    expect(_option(w, 'active'), 'true');
  });

  test('何度書いても 1 つ。gpkg を動かしたら根も直る', () {
    final doc = QgsDocument.create(projectName: 'テスト')..apply(_project(photoFields: ['photo']));
    doc.apply(_project(photoFields: ['photo']));
    final config = doc.findMapLayer(_id)!.getElement('fieldConfiguration')!;
    expect(config.findElements('field').where((f) => f.getAttribute('name') == 'photo'), hasLength(1));
    expect(config.findAllElements('editWidget'), hasLength(1));

    doc.apply(_project(photoFields: ['photo'], path: './sub/調査.gpkg'));
    expect(_option(_widget(doc, 'photo')!, 'RelativeStorage'), '2');
  });

  test('QGIS で別の欄にした列・ほかの列の設定は触らない。空の欄（QGIS の既定）は写真の欄にする', () {
    final doc = QgsDocument.create(projectName: 'テスト')..apply(_project());
    final layer = doc.findMapLayer(_id)!;
    layer.children.add(XmlDocument.parse('''
<fieldConfiguration>
  <field configurationFlags="0" name="name"><editWidget type="TextEdit"><config><Option/></config></editWidget></field>
  <field configurationFlags="0" name="photo"><editWidget type="ValueMap"><config><Option/></config></editWidget></field>
  <field configurationFlags="0" name="photo_2"><editWidget type=""><config><Option/></config></editWidget></field>
</fieldConfiguration>''').rootElement.copy());

    doc.apply(_project(photoFields: ['photo', 'photo_2']));
    expect(_widget(doc, 'name')!.getAttribute('type'), 'TextEdit');
    expect(_widget(doc, 'photo')!.getAttribute('type'), 'ValueMap');
    expect(_widget(doc, 'photo_2')!.getAttribute('type'), 'ExternalResource');
    // 文字列にして読み直しても同じ（往復で崩れない）
    final again = QgsDocument.parse(doc.toXmlString());
    expect(_widget(again, 'photo_2')!.getAttribute('type'), 'ExternalResource');
  });

  test('QGIS が書いた .qgs（フィクスチャ）の maplayer に足しても、ほかの列の設定は残る', () {
    const idSugi = '___56902204_7d58_4032_ab25_8588e0e0aa73';
    final doc = QgsDocument.parse(File('test/fixtures/qgis_3_44_written.qgs').readAsStringSync());
    doc.apply(const QgsProject(name: 'テスト', root: [
      QgsLayer(
        id: idSugi,
        name: 'スギ',
        dataSourcePath: './林小班.gpkg',
        tableName: 'rinshoban',
        geometryType: GeometryType.point,
        crs: QgsCrs.wgs84,
        photoFields: ['photo'],
      ),
    ]));
    final fields = doc.findMapLayer(idSugi)!.getElement('fieldConfiguration')!.findElements('field');
    expect([for (final f in fields) f.getAttribute('name')], ['fid', 'name', 'area', 'photo']);
    expect(fields.first.getAttribute('configurationFlags'), 'NoFlag');
    expect(fields.last.getElement('editWidget')!.getAttribute('type'), 'ExternalResource');
  });
}
