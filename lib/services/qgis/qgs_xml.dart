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
// こかげマップ: `.qgs` の XML・色/単位変換・データソース参照を扱う共通ヘルパー
// （書き手・DOM 保持の文書・プロジェクト構築・取り込みで共通）

import 'package:flutter/painting.dart' show Color;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/geometry_type.dart';

// =============================================
// 単位・色コード変換
// =============================================

/// px → mm（QGISのシンボル単位はMM）。96dpi 相当。
///
/// ⚠ こかげマップ のスタイル値は地図の画面ピクセルなので、厳密な対応は無い。
/// **見た目が近くなるだけの近似**であって、往復しても同じ値には戻らない。
const double kQgsPxToMm = 25.4 / 96;

/// mm → px（QGISのシンボル単位はMM）。96dpi 相当。[kQgsPxToMm] の逆。
const double kQgsMmToPx = 96 / 25.4;

/// px ⇄ pt（ラベル文字サイズ）。96dpi で `1px = 0.75pt`。
const double kQgsPxToPt = 0.75;

/// px → QGIS のシンボル単位（MM）文字列
String formatQgsMm(double px) => (px * kQgsPxToMm).toStringAsFixed(2);

/// QGIS のシンボル単位（MM）文字列 → px
double? parseQgsMmToPx(String? mm, {double divideBy = 1}) {
  if (mm == null) return null;
  final value = double.tryParse(mm.trim());
  if (value == null) return null;
  return value * kQgsMmToPx / divideBy;
}

/// QGIS の色表記 `R,G,B,A`（各0-255）。[opacity] があればアルファはそれにする
String formatQgsColor(Color color, {double? opacity}) {
  final argb = color.toARGB32();
  final a = opacity != null
      ? (opacity.clamp(0.0, 1.0) * 255).round()
      : (argb >> 24) & 0xFF;
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return '$r,$g,$b,$a';
}

/// QGIS の `R,G,B,A`（各0-255）から不透明の [Color] を返す。読めなければ null。
///
/// ⚠ QGIS 3.44 以降は後ろに浮動小数表記を足してくる:
/// `30,144,255,255,rgb:0.1176471,0.5647059,1,1`。先頭3チャンネルだけ見る。
Color? parseQgsColor(String? value) {
  if (value == null) return null;
  final parts = value.split(',');
  if (parts.length < 3) return null;
  int channel(int i) => (int.tryParse(parts[i].trim()) ?? 0).clamp(0, 255);
  // アルファは別途 opacity として持つので、色は不透明にしておく
  return Color.fromARGB(255, channel(0), channel(1), channel(2));
}

/// QGIS の `R,G,B,A` の A を `0..1` で返す。無ければ null
double? parseQgsColorAlpha(String? value) {
  if (value == null) return null;
  final parts = value.split(',');
  if (parts.length < 4) return null;
  final a = int.tryParse(parts[3].trim());
  return a == null ? null : a.clamp(0, 255) / 255;
}

// =============================================
// XML 要素・属性操作
// =============================================

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

/// [optionMap] 内の `<Option name=[name]>` の `value` を設定する（無ければ追加）
void setNamedOption(XmlElement optionMap, String name, String value) {
  final option = namedOption(optionMap, name);
  if (option != null) {
    option.setAttribute('value', value);
  } else {
    optionMap.children.add(
      XmlElement(const XmlName.parts('Option'), [
        XmlAttribute(const XmlName.parts('name'), name),
        XmlAttribute(const XmlName.parts('type'), 'QString'),
        XmlAttribute(const XmlName.parts('value'), value),
      ]),
    );
  }
}

/// `<properties>` の中の [key] を返す。QGIS の書き方は 2 通りある:
/// 3.x までの `<key type="…">` と、4.x の `<properties name="key" type="…">`
/// （QGIS 4.2 で保存し直すと、こかげマップが書いた印も後者に書き換わる。2026-09-30 実測）
XmlElement? qgsProperty(XmlElement scope, String key) =>
    scope.getElement(key) ??
    scope.findElements('properties').where((e) => e.getAttribute('name') == key).firstOrNull;

/// [qgsProperty] と同じだが、無ければ作る。作るときは [root] 文書の書き方に合わせる
XmlElement ensureQgsProperty(XmlElement root, XmlElement scope, String key) {
  final existing = qgsProperty(scope, key);
  if (existing != null) return existing;
  final named = root.getElement('properties')?.getAttribute('name') == 'properties';
  final created = named
      ? XmlElement(const XmlName.parts('properties'), [XmlAttribute(const XmlName.parts('name'), key)])
      : XmlElement(XmlName.parts(key));
  scope.children.add(created);
  return created;
}

/// QGIS の `<properties>` 流儀で値を置く（`<key type="QString">value</key>` か 4.x の書き方）
void setQgsProperty(
  XmlElement root,
  XmlElement scope,
  String key,
  String value, {
  String type = 'QString',
}) {
  final el = ensureQgsProperty(root, scope, key);
  el.setAttribute('type', type);
  el.children
    ..clear()
    ..add(XmlText(value));
}

/// `<maplayer>` に要素を足す。QGIS の並びに厳密さは要らないが、`previewExpression` の前に置く
void insertIntoMapLayer(XmlElement mapLayer, XmlElement element) {
  final anchor = mapLayer.getElement('previewExpression');
  if (anchor != null) {
    mapLayer.children.insert(mapLayer.children.indexOf(anchor), element);
  } else {
    mapLayer.children.add(element);
  }
}

// =============================================
// パス・データソース・ツリー走査
// =============================================

/// [rootPath] から見た [absPath] の相対パス。[rootPath] の外なら null。
///
/// ⚠ 判定は**正規化した絶対パス**で行う。`../shared/kyoyu.gpkg` のように
/// 相対パスで外に出るケースがあるため、素朴な文字列比較では足りない。
String? relativeInside(String rootPath, String absPath) {
  final rel = p.relative(p.normalize(absPath), from: p.normalize(rootPath));
  if (rel.startsWith('..') || p.isAbsolute(rel)) return null;
  return rel;
}

/// `.qgs` のある [rootPath] から見た `./…` 形式の相対パス（区切りは `/`）。root 外なら null。
/// QGIS は `./` 始まりを相対パスとして扱う。
String? qgsRelativePath(String? rootPath, String? absPath) {
  if (rootPath == null || absPath == null) return null;
  final rel = relativeInside(rootPath, absPath);
  return rel == null ? null : './${rel.replaceAll(r'\', '/')}';
}

/// データソース文字列から `./sub/a.tif` と `sub\a.tif` を同じに見る比較キーを作る
String qgsNormalizedPathKey(String path) {
  var s = path.split('|').first.trim().replaceAll(r'\', '/');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  return s.toLowerCase();
}

/// 形の無い表の `<maplayer>` か（`wkbType="NoGeometry"`、古い形は `geometry="No geometry"`）
bool isQgsTableLayer(XmlElement maplayer) =>
    maplayer.getAttribute('type') == 'vector' &&
    (maplayer.getAttribute('wkbType') == 'NoGeometry' || maplayer.getAttribute('geometry') == 'No geometry');

/// 表の `<maplayer>` が指すファイルのパス（`.qgs` に書かれたまま。相対なら `./…`）。
/// delimitedtext は `file:./%E6….csv?type=csv&…`（パスは % エンコード）、ogr は `./属性表.csv|…`
String? qgsTableSourcePath(XmlElement maplayer) {
  final provider = childText(maplayer, 'provider')?.toLowerCase();
  final raw = childText(maplayer, 'datasource') ?? '';
  if (raw.isEmpty) return null;
  if (provider == 'delimitedtext') {
    var path = raw.split('?').first;
    if (path.startsWith('file:')) path = path.substring(5);
    // file:///C:/… → C:/…（ドライブ文字が無ければ / から）
    if (path.startsWith('///')) {
      path = RegExp('^///[A-Za-z]:').hasMatch(path) ? path.substring(3) : path.substring(2);
    }
    try {
      return Uri.decodeComponent(path);
    } catch (_) {
      return path;
    }
  }
  if (provider == 'ogr') return raw.split('|').first.trim();
  return null;
}

/// レイヤツリー（root の `<layer-tree-group>`）の `<layer-tree-layer>` の id を上から順に（深さ優先）。
/// QGIS の描く順（`<custom-order enabled="0">` のとき）で、先頭ほど手前。同じ id は最初の 1 回だけ
List<String> qgsTreeLayerIds(XmlDocument doc) {
  final treeRoot = doc.rootElement.getElement('layer-tree-group');
  if (treeRoot == null) return const [];
  final out = <String>[];
  final seen = <String>{};
  void walk(XmlElement group) {
    for (final child in group.childElements) {
      if (child.name.local == 'layer-tree-group') {
        walk(child);
      } else if (child.name.local == 'layer-tree-layer') {
        final id = child.getAttribute('id');
        if (id != null && seen.add(id)) out.add(id);
      }
    }
  }

  walk(treeRoot);
  return out;
}
