// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// こかげマップ: `.qgs` の `<maplayer>` に、写真の列の欄（ExternalResource）を書く
//
// 写真の列の値は gpkg の dir からの相対パス（`photos/<レイヤ>/…jpg`）。QGIS で開くと
// 属性フォームに写真が出るよう、アプリが作った列（[QgsLayer.photoFields]）にだけ
// `ExternalResource` を書く。
//
// - gpkg が `.qgs` と同じ dir: 「プロジェクトからの相対」（RelativeStorage=1）。QGIS・QField の普通の形
// - gpkg が下の dir（子 dir のレイヤを写した `.qgs`）: 「既定のパスからの相対」（RelativeStorage=2）にし、
//   既定のパスを式 `@project_folder || '/<dir>'` で与える（data-defined の rootPath）
//
// ユーザーが QGIS で別の欄（文字・値の対応表など）にした列は触らない。触るのは欄の指定が無いか空、
// または既に ExternalResource のときだけ。
// QGIS 4.2.2 で、書いた `.qgs` の写真の欄が上のとおり解けることを確かめた（2026-10-11、
// [[docs/features/feature-photos]]）。

import 'package:xml/xml.dart';

import 'qgs_model.dart';
import 'qgs_xml.dart';

/// [layer] の写真の列の欄を [mapLayer] に書く（DOM 保持型。ほかの列の設定は触らない）
void applyPhotoWidgets(XmlElement mapLayer, QgsLayer layer) {
  if (layer.photoFields.isEmpty) return;
  var config = mapLayer.getElement('fieldConfiguration');
  if (config == null) {
    config = XmlElement(const XmlName.parts('fieldConfiguration'));
    insertIntoMapLayer(mapLayer, config);
  }
  for (final name in layer.photoFields) {
    var field = config.findElements('field').where((f) => f.getAttribute('name') == name).firstOrNull;
    if (field == null) {
      field = XmlElement(const XmlName.parts('field'), [XmlAttribute(const XmlName.parts('name'), name)]);
      config.children.add(field);
    }
    final existing = field.getElement('editWidget');
    final type = existing?.getAttribute('type') ?? '';
    if (type.isNotEmpty && type != 'ExternalResource') continue; // ユーザーが選んだ欄
    if (existing != null) detachNode(existing);
    field.children.add(photoEditWidget(layer.dataSourceDir));
  }
}

/// ExternalResource の `<editWidget>`。[gpkgDir] は `.qgs` から見た gpkg の dir（同じなら `.`）
XmlElement photoEditWidget(String gpkgDir) {
  final dir = gpkgDir.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');
  final sameDir = dir.isEmpty || dir == '.';
  XmlElement option(String name, String type, String value) => XmlElement(const XmlName.parts('Option'), [
        XmlAttribute(const XmlName.parts('name'), name),
        XmlAttribute(const XmlName.parts('type'), type),
        XmlAttribute(const XmlName.parts('value'), value),
      ]);
  XmlElement map(String? name, List<XmlElement> children) => XmlElement(
        const XmlName.parts('Option'),
        [if (name != null) XmlAttribute(const XmlName.parts('name'), name), XmlAttribute(const XmlName.parts('type'), 'Map')],
        children,
      );
  final expression = "@project_folder || '/${dir.replaceAll("'", "''")}'";
  return XmlElement(const XmlName.parts('editWidget'), [XmlAttribute(const XmlName.parts('type'), 'ExternalResource')], [
    XmlElement(const XmlName.parts('config'), const [], [
      map(null, [
        if (!sameDir) option('DefaultRoot', 'QString', ''),
        option('DocumentViewer', 'int', '1'), // 画像として出す
        option('DocumentViewerHeight', 'int', '0'),
        option('DocumentViewerWidth', 'int', '0'),
        option('FileWidget', 'bool', 'true'),
        option('FileWidgetButton', 'bool', 'true'),
        option('FileWidgetFilter', 'QString', ''),
        if (!sameDir)
          map('PropertyCollection', [
            option('name', 'QString', ''),
            map('properties', [
              map('propertyRootPath', [
                option('active', 'bool', 'true'),
                option('expression', 'QString', expression),
                option('type', 'int', '3'),
              ]),
            ]),
            option('type', 'QString', 'collection'),
          ]),
        option('RelativeStorage', 'int', sameDir ? '1' : '2'),
        option('StorageMode', 'int', '0'), // ファイル
      ]),
    ]),
  ]);
}
