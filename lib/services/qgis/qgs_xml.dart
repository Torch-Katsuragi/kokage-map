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
// こかげマップ: `.qgs` の XML を読み書きする小道具（書き手・DOM 保持の文書・取り込みで共通）

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/geometry_type.dart';

/// `<maplayer geometry="…">` の値
String qgsGeometryName(GeometryType type) => switch (type) {
  GeometryType.point => 'Point',
  GeometryType.linestring => 'Line',
  GeometryType.polygon => 'Polygon',
};

/// 可視性の属性（`checked`）の値
String qgsCheckedValue(bool visible) => visible ? 'Qt::Checked' : 'Qt::Unchecked';

/// [parent] 直下の [name] の要素。無ければ作って末尾に足す
XmlElement ensureChild(XmlElement parent, String name) {
  final existing = parent.getElement(name);
  if (existing != null) return existing;
  final created = XmlElement(XmlName.parts(name));
  parent.children.add(created);
  return created;
}

/// [parent] 直下の [name] の要素の中身を [text] だけにする（無ければ作る）
void setChildText(XmlElement parent, String name, String text) {
  final el = ensureChild(parent, name);
  el.children
    ..clear()
    ..add(XmlText(text));
}

/// [parent] 直下で最初の [tag] の文字（前後の空白を除く）。無い・空なら null
String? childText(XmlElement parent, String tag) {
  final text = parent.findElements(tag).firstOrNull?.innerText.trim();
  return text == null || text.isEmpty ? null : text;
}

/// 文書から外す
void detachNode(XmlNode node) {
  node.parent?.children.remove(node);
}

/// シンボルレイヤ（`<layer class=…>`）直下の `<Option type="Map">`。
/// ⚠ 中の `data_defined_properties` の `<Option>` は拾わない
XmlElement? symbolOptionMap(XmlElement symbolLayer) =>
    symbolLayer.findElements('Option').where((o) => o.getAttribute('type') == 'Map').firstOrNull;

/// `<Option name=… value=…>` のうち [name] のもの
XmlElement? namedOption(XmlElement optionMap, String name) =>
    optionMap.findElements('Option').where((o) => o.getAttribute('name') == name).firstOrNull;

/// `<maplayer>` に要素を足す。QGIS の並びに厳密さは要らないが、`previewExpression` の前に置く
void insertIntoMapLayer(XmlElement mapLayer, XmlElement element) {
  final anchor = mapLayer.getElement('previewExpression');
  if (anchor != null) {
    mapLayer.children.insert(mapLayer.children.indexOf(anchor), element);
  } else {
    mapLayer.children.add(element);
  }
}

/// [rootPath] から見た [absPath] の相対パス。[rootPath] の外なら null。
///
/// ⚠ 判定は**正規化した絶対パス**で行う。`../shared/kyoyu.gpkg` のように
/// 相対で外に出るケースが林業では現実にありそうなので、素朴な文字列比較では足りない。
String? relativeInside(String rootPath, String absPath) {
  final rel = p.relative(p.normalize(absPath), from: p.normalize(rootPath));
  if (rel.startsWith('..') || p.isAbsolute(rel)) return null;
  return rel;
}
