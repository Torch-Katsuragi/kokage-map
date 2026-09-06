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
// こかげマップ: DOM 保持型の `.qgs` 文書
//
// 設計は [[docs/technical/project-format-design#正典を `.qgs` に移す（2026-09-06 決定・設計）]]。
//
// > [!IMPORTANT] 理解しないノードは触らない（不変条件3）
// > `.qgs` を正典にするなら、QGIS が保存した巨大な XML のうち自分が知らない部分
// > （印刷レイアウト・リレーション・スナップ設定・フィールド設定…）を残したまま、
// > 自分の管轄（レイヤツリー・maplayer の参照とフィルタ・単一シンボルの色と太さ・
// > `<layerorder>`・`kokage` 名前空間）だけを差し替える。
// > [QgsWriter] が「ゼロから生成」なのに対し、こちらは「あるものを直す」。
//
// > [!IMPORTANT] 表現できないスタイルは触らない（不変条件4）
// > `renderer-v2` が単一シンボル以外（分類・ルールベース…）なら XML をそのまま残す。
// > 単一シンボルでも、自分が持つ値（色・サイズ・線幅・不透明度）だけを既存の
// > `<Option>` の中で差し替え、知らないプロパティ（破線・オフセット…）は残す。

import 'package:flutter/painting.dart' show Color;
import 'package:xml/xml.dart';

import '../../models/geometry_type.dart';
import 'qgs_model.dart';
import 'qgs_writer.dart';

/// `kokage` 名前空間に書く印。「この `.qgs` を最後に書いたのは誰か」の根拠。
class KokageStamp {
  const KokageStamp({
    required this.schemaVersion,
    required this.app,
    required this.savedAt,
    required this.dirName,
    this.savedBy,
  });

  /// アプリ側の `.qgs` の読み方の版
  final int schemaVersion;

  /// 例: `kokage-map 0.6.1+18`
  final String app;

  /// 書いた時刻。root の `saveDateTime` と同じ文字列で書く
  final DateTime savedAt;

  /// 書いた端末（deviceId）。null なら不明
  final String? savedBy;

  /// 書いた時点の dir 名。現在の dir 名と違えば改名の痕跡
  final String dirName;

  /// QGIS が root に書くのと同じ書式（`2026-08-26T10:49:28`・ローカル時刻・秒まで）
  String get savedAtText => formatQgisDateTime(savedAt);

  static String formatQgisDateTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}'
        'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

/// [QgsDocument.apply] の結果。捨てたものは必ず呼び出し側が見せること。
class QgsApplyReport {
  /// 文書にあったが [QgsProject] に無いので外した maplayer の id（と表示名）
  final List<String> removedLayers = [];

  /// 単一シンボル以外だったので触らなかったレイヤの id
  final List<String> untouchedRenderers = [];

  bool get isEmpty => removedLayers.isEmpty && untouchedRenderers.isEmpty;
}

/// DOM 保持型の `.qgs` 文書
class QgsDocument {
  QgsDocument._(this._doc);

  final XmlDocument _doc;

  static const _writer = QgsWriter();

  /// 既存の `.qgs` を読む。QGIS が書いたものでも、こかげマップが書いたものでもよい。
  factory QgsDocument.parse(String xml) {
    final doc = XmlDocument.parse(xml);
    if (doc.rootElement.name.local != 'qgis') {
      throw FormatException('root 要素が <qgis> ではありません: ${doc.rootElement.name}');
    }
    return QgsDocument._(doc);
  }

  /// 空のプロジェクトから作る（新規 dir 用）。骨格は [QgsWriter] と同じ。
  factory QgsDocument.create({
    required String projectName,
    QgsCrs projectCrs = QgsCrs.wgs84,
  }) {
    final xml = _writer.build(
      QgsProject(name: projectName, root: const [], projectCrs: projectCrs),
    );
    return QgsDocument.parse(xml);
  }

  XmlElement get root => _doc.rootElement;

  /// 文字列にする。QGIS と同じくインデント付き
  String toXmlString() => _doc.toXmlString(pretty: true, indent: '  ');

  // =============================================
  // 印（kokage 名前空間）
  // =============================================

  static const _kokageScope = 'kokage';

  /// `<properties><kokage>` を返す。無ければ null
  XmlElement? get _kokageElement =>
      root.getElement('properties')?.getElement(_kokageScope);

  /// 印を読む。無ければ null（QGIS か他人が作ったファイル）
  KokageStamp? get stamp {
    final k = _kokageElement;
    if (k == null) return null;
    final savedAt = k.getElement('savedAt')?.innerText;
    final dirName = k.getElement('dirName')?.innerText;
    if (savedAt == null || dirName == null) return null;
    final parsed = DateTime.tryParse(savedAt);
    if (parsed == null) return null;
    return KokageStamp(
      schemaVersion: int.tryParse(k.getElement('schemaVersion')?.innerText ?? '') ?? 0,
      app: k.getElement('app')?.innerText ?? '',
      savedAt: parsed,
      savedBy: k.getElement('savedBy')?.innerText,
      dirName: dirName,
    );
  }

  /// 印を書く。root の `saveDateTime` も同じ値にする（QGIS が保存すると上書きされる）。
  void setStamp(KokageStamp stamp) {
    final props = _ensureChild(root, 'properties');
    final k = _ensureChild(props, _kokageScope);
    _setProperty(k, 'schemaVersion', '${stamp.schemaVersion}', type: 'int');
    _setProperty(k, 'app', stamp.app);
    _setProperty(k, 'savedAt', stamp.savedAtText);
    _setProperty(k, 'dirName', stamp.dirName);
    if (stamp.savedBy != null) {
      _setProperty(k, 'savedBy', stamp.savedBy!);
    } else {
      final stale = k.getElement('savedBy');
      if (stale != null) _detach(stale);
    }
    root.setAttribute('saveDateTime', stamp.savedAtText);
    root.setAttribute('saveUser', 'kokage-map');
    root.setAttribute('saveUserFull', stamp.app);
  }

  /// 最後に書いたのはこかげマップか。
  ///
  /// 印の `savedAt` と root の `saveDateTime` が一致すれば自分。QGIS が保存すると
  /// `saveDateTime` が更新されて食い違う。印が無ければ false。
  bool get lastWrittenByKokage {
    final s = stamp;
    if (s == null) return false;
    return root.getAttribute('saveDateTime') == s.savedAtText;
  }

  /// QGIS の `<properties>` 流儀で値を置く（`<key type="QString">value</key>`）
  void _setProperty(XmlElement scope, String key, String value, {String type = 'QString'}) {
    final el = _ensureChild(scope, key);
    el.setAttribute('type', type);
    el.children.clear();
    el.children.add(XmlText(value));
  }

  // =============================================
  // レイヤ
  // =============================================

  XmlElement get _projectLayers => _ensureChild(root, 'projectlayers');

  /// 文書内の `<maplayer>`
  Iterable<XmlElement> get mapLayers => _projectLayers.findElements('maplayer');

  XmlElement? findMapLayer(String id) => mapLayers
      .where((e) => e.getElement('id')?.innerText == id)
      .firstOrNull;

  /// 埋め込み（別プロジェクト由来）の maplayer か。子 dir の `.qgs` が正典なので触らない
  static bool isEmbedded(XmlElement e) => e.getAttribute('embedded') == '1';

  // =============================================
  // 反映
  // =============================================

  /// [project] の内容を文書に反映する。
  ///
  /// - レイヤツリーは [project] の構造で組み直す。既存の要素は id / 名前で拾って
  ///   属性と未知の子（`customproperties` 等）を引き継ぐ
  /// - `<maplayer>` は id で突き合わせ、あれば参照・フィルタ・単一シンボルの値だけ直す。
  ///   無ければ [QgsWriter] の形で足す。[project] に無いものは外して報告する
  ///   （埋め込みのものは残す）
  /// - `<layerorder>` は [project] の順で書き直す
  QgsApplyReport apply(QgsProject project) {
    final report = QgsApplyReport();
    root.setAttribute('projectname', project.name);
    _ensureChild(root, 'title')
      ..children.clear()
      ..children.add(XmlText(project.name));

    _applyTree(project);
    _applyMapLayers(project, report);
    _applyLayerOrder(project);
    return report;
  }

  // ---- レイヤツリー ----

  void _applyTree(QgsProject project) {
    final treeRoot = _ensureChild(root, 'layer-tree-group');

    // 既存ノードを控える（id とグループ名で引く）
    final oldLayers = <String, XmlElement>{
      for (final e in treeRoot.findAllElements('layer-tree-layer'))
        if (e.getAttribute('id') != null) e.getAttribute('id')!: e,
    };

    final rebuilt = _rebuildChildren(project.root, treeRoot, oldLayers);

    // root 直下は customproperties と custom-order を残して差し替える
    final keep = <XmlNode>[
      for (final c in treeRoot.childElements)
        if (c.name.local == 'customproperties') c.copy(),
    ];
    final customOrder = treeRoot.getElement('custom-order')?.copy();
    treeRoot.children.clear();
    treeRoot.children.addAll(keep);
    treeRoot.children.addAll(rebuilt);
    treeRoot.children.add(
      customOrder ?? XmlElement(XmlName('custom-order'), [XmlAttribute(XmlName('enabled'), '0')]),
    );
  }

  List<XmlElement> _rebuildChildren(
    List<QgsTreeNode> nodes,
    XmlElement? oldParent,
    Map<String, XmlElement> oldLayers,
  ) {
    final oldGroups = <String, XmlElement>{
      if (oldParent != null)
        for (final g in oldParent.findElements('layer-tree-group'))
          if (g.getAttribute('name') != null) g.getAttribute('name')!: g,
    };

    final result = <XmlElement>[];
    for (final node in nodes) {
      switch (node) {
        case QgsEmbeddedGroup(:final name, :final projectPath, :final visible, :final expanded):
          final old = oldGroups[name];
          final group = old?.copy() ?? _writer.embeddedGroupElement(node);
          group.setAttribute('name', name);
          group.setAttribute('checked', QgsWriter.checkedValue(visible));
          group.setAttribute('expanded', expanded ? '1' : '0');
          group.setAttribute('embedded', '1');
          group.setAttribute('embedded_project', projectPath);
          // 子は書かない（QGIS が子プロジェクトから再構成する）
          group.children.removeWhere(
            (c) =>
                c is XmlElement &&
                (c.name.local == 'layer-tree-group' || c.name.local == 'layer-tree-layer'),
          );
          result.add(group);
        case QgsGroup(:final name, :final children, :final visible, :final expanded):
          final old = oldGroups[name];
          final group = old?.copy() ?? _writer.treeGroupElement(name, visible: visible);
          // 以前は埋め込みだったが、いまは普通のグループ（子 dir の .kmeta.json が消えた等）
          group.removeAttribute('embedded');
          group.removeAttribute('embedded_project');
          group.setAttribute('name', name);
          group.setAttribute('checked', QgsWriter.checkedValue(visible));
          group.setAttribute('expanded', expanded ? '1' : '0');
          // 子は組み直す。customproperties 等の非ツリー要素は残す
          final nonTree = [
            for (final c in group.childElements)
              if (c.name.local != 'layer-tree-group' && c.name.local != 'layer-tree-layer') c.copy(),
          ];
          final rebuilt = _rebuildChildren(children, old, oldLayers);
          group.children.clear();
          group.children.addAll(nonTree);
          group.children.addAll(rebuilt);
          result.add(group);
        case QgsLayer():
          final old = oldLayers[node.id];
          final el = old?.copy() ?? _writer.treeLayerElement(node);
          el.setAttribute('id', node.id);
          el.setAttribute('name', node.name);
          el.setAttribute('source', node.dataSourceUri);
          el.setAttribute('providerKey', 'ogr');
          el.setAttribute('checked', QgsWriter.checkedValue(node.visible));
          result.add(el);
      }
    }
    return result;
  }

  // ---- maplayer ----

  void _applyMapLayers(QgsProject project, QgsApplyReport report) {
    final layers = project.layers;
    final wanted = {for (final l in layers) l.id: l};
    final container = _projectLayers;

    // 埋め込みスタブ: project の埋め込みグループに合わせて作り直す
    final wantedStubs = <String, String>{
      for (final g in project.embeddedGroups)
        for (final id in g.layerIds) id: g.projectPath,
    };
    for (final e in container.findElements('maplayer').toList()) {
      if (!isEmbedded(e)) continue;
      final id = e.getAttribute('id');
      final path = id == null ? null : wantedStubs.remove(id);
      if (path == null) {
        _detach(e); // dir 構造に無い埋め込み（不変条件2）
      } else {
        e.setAttribute('project', path);
      }
    }
    for (final entry in wantedStubs.entries) {
      container.children.add(_writer.embeddedStubElement(entry.value, entry.key));
    }

    // 既存: 直す or 外す
    // ⚠ 同じ id の maplayer が複数あることがある（id 衝突バグがあった版の出力）。
    //   2つ目以降は外す。残さないと QGIS が1つに畳んで、どちらかの設定が消える
    final seen = <String>{};
    for (final e in container.findElements('maplayer').toList()) {
      if (isEmbedded(e)) continue;
      final id = e.getElement('id')?.innerText;
      final layer = id == null ? null : wanted[id];
      if (layer == null) {
        final name = e.getElement('layername')?.innerText ?? id ?? '?';
        report.removedLayers.add(name);
        _detach(e);
        continue;
      }
      if (!seen.add(id!)) {
        _detach(e);
        continue;
      }
      _patchMapLayer(e, layer, report);
    }

    // 無かったものを足す（project の順に、末尾へ）
    final existing = {
      for (final e in container.findElements('maplayer'))
        if (e.getElement('id') != null) e.getElement('id')!.innerText,
    };
    for (final layer in layers) {
      if (existing.contains(layer.id)) continue;
      container.children.add(_writer.mapLayerElement(layer));
    }
  }

  /// 既存の `<maplayer>` を [layer] に合わせる。自分の管轄だけ触る
  void _patchMapLayer(XmlElement e, QgsLayer layer, QgsApplyReport report) {
    _setText(e, 'datasource', layer.dataSourceUri);
    _setText(e, 'layername', layer.name);
    e.setAttribute('geometry', _geometryName(layer.geometryType));

    final renderer = e.getElement('renderer-v2');
    if (renderer == null) {
      final fresh = _writer.rendererElement(layer);
      if (fresh != null) {
        // QGIS の並び（srs/provider の後、customproperties の前）に厳密さは要らない。
        // `previewExpression` の前に置けば読める
        final anchor = e.getElement('previewExpression');
        if (anchor != null) {
          e.children.insert(e.children.indexOf(anchor), fresh);
        } else {
          e.children.add(fresh);
        }
      }
      return;
    }
    if (renderer.getAttribute('type') != 'singleSymbol') {
      report.untouchedRenderers.add(layer.id);
      _patchLabeling(e, layer);
      return;
    }
    _patchSingleSymbol(renderer, layer);
    _patchLabeling(e, layer);
  }

  /// 簡易ラベル。自分が持つ属性だけ差し替える。
  ///
  /// - `labelEnabled` が null（アプリ側に設定なし）なら何も触らない
  /// - 有効なら `labelsEnabled="1"`。`<labeling>` が無ければ足し、
  ///   `type="simple"` なら `text-style` の管轄属性だけ差し替える。それ以外（ルールベース）は触らない
  /// - 無効なら `labelsEnabled="0"` にするだけ（設定は残す。QGIS も同じ振る舞い）
  void _patchLabeling(XmlElement e, QgsLayer layer) {
    final style = layer.style;
    if (style == null || style.labelEnabled == null) return;
    if (!style.hasLabel) {
      e.setAttribute('labelsEnabled', '0');
      return;
    }
    e.setAttribute('labelsEnabled', '1');
    final labeling = e.getElement('labeling');
    if (labeling == null) {
      final fresh = _writer.labelingElement(layer);
      if (fresh == null) return;
      final anchor = e.getElement('previewExpression');
      if (anchor != null) {
        e.children.insert(e.children.indexOf(anchor), fresh);
      } else {
        e.children.add(fresh);
      }
      return;
    }
    if (labeling.getAttribute('type') != 'simple') return;
    final textStyle = labeling.getElement('settings')?.getElement('text-style');
    if (textStyle == null) return;
    for (final entry in QgsWriter.labelTextStyleAttributes(style).entries) {
      textStyle.setAttribute(entry.key, entry.value);
    }
    final buffer = textStyle.getElement('text-buffer');
    if (buffer != null && style.labelHaloColor != null) {
      buffer.setAttribute('bufferColor', QgsWriter.formatColor(style.labelHaloColor!));
    }
  }

  /// 単一シンボルの `<Option>` を、自分が持つ値だけ差し替える
  void _patchSingleSymbol(XmlElement renderer, QgsLayer layer) {
    final style = layer.style;
    if (style == null || style.isEmpty) return;
    final symbol = renderer.getElement('symbols')?.getElement('symbol');
    final symbolLayer = symbol?.getElement('layer');
    if (symbol == null || symbolLayer == null) return;

    final values = <String, String>{};
    switch (symbol.getAttribute('type')) {
      case 'marker':
        if (style.pointColor != null) values['color'] = QgsWriter.formatColor(style.pointColor!);
        if (style.pointSizePx != null) values['size'] = QgsWriter.formatMm(style.pointSizePx! * 2);
      case 'line':
        if (style.lineColor != null) values['line_color'] = QgsWriter.formatColor(style.lineColor!);
        if (style.lineWidthPx != null) values['line_width'] = QgsWriter.formatMm(style.lineWidthPx!);
      case 'fill':
        if (style.fillColor != null || style.fillOpacity != null) {
          values['color'] = QgsWriter.formatColor(
            style.fillColor ?? _readColor(symbolLayer, 'color'),
            opacity: style.fillOpacity,
          );
        }
        if (style.strokeColor != null || style.strokeOpacity != null) {
          values['outline_color'] = QgsWriter.formatColor(
            style.strokeColor ?? _readColor(symbolLayer, 'outline_color'),
            opacity: style.strokeOpacity,
          );
        }
        if (style.strokeWidthPx != null) {
          values['outline_width'] = QgsWriter.formatMm(style.strokeWidthPx!);
        }
      default:
        return;
    }
    if (values.isEmpty) return;

    // `<layer>` 直下の `<Option type="Map">` だけを見る（data_defined_properties は触らない）
    final map = symbolLayer
        .findElements('Option')
        .where((o) => o.getAttribute('type') == 'Map')
        .firstOrNull;
    if (map == null) return;
    for (final entry in values.entries) {
      final option = map
          .findElements('Option')
          .where((o) => o.getAttribute('name') == entry.key)
          .firstOrNull;
      if (option != null) {
        option.setAttribute('value', entry.value);
      } else {
        map.children.add(
          XmlElement(XmlName('Option'), [
            XmlAttribute(XmlName('name'), entry.key),
            XmlAttribute(XmlName('type'), 'QString'),
            XmlAttribute(XmlName('value'), entry.value),
          ]),
        );
      }
    }
  }

  /// 既存の色（`R,G,B,A,...`）を読む。読めなければ黒
  static Color _readColor(XmlElement symbolLayer, String name) {
    final map = symbolLayer
        .findElements('Option')
        .where((o) => o.getAttribute('type') == 'Map')
        .firstOrNull;
    final value = map
        ?.findElements('Option')
        .where((o) => o.getAttribute('name') == name)
        .firstOrNull
        ?.getAttribute('value');
    final parts = value?.split(',') ?? const [];
    if (parts.length < 3) return const Color(0xFF000000);
    int channel(int i) => int.tryParse(parts[i].trim())?.clamp(0, 255) ?? 0;
    return Color.fromARGB(255, channel(0), channel(1), channel(2));
  }

  // ---- layerorder ----

  void _applyLayerOrder(QgsProject project) {
    final order = _ensureChild(root, 'layerorder');
    order.children.clear();
    for (final layer in project.layers) {
      order.children.add(
        XmlElement(XmlName('layer'), [XmlAttribute(XmlName('id'), layer.id)]),
      );
    }
    for (final group in project.embeddedGroups) {
      for (final id in group.layerIds) {
        order.children.add(
          XmlElement(XmlName('layer'), [XmlAttribute(XmlName('id'), id)]),
        );
      }
    }
  }

  // =============================================
  // 小道具
  // =============================================

  static XmlElement _ensureChild(XmlElement parent, String name) {
    final existing = parent.getElement(name);
    if (existing != null) return existing;
    final created = XmlElement(XmlName(name));
    parent.children.add(created);
    return created;
  }

  static void _setText(XmlElement parent, String name, String text) {
    final el = _ensureChild(parent, name);
    el.children.clear();
    el.children.add(XmlText(text));
  }

  static void _detach(XmlNode node) {
    node.parent?.children.remove(node);
  }

  static String _geometryName(GeometryType type) => switch (type) {
    GeometryType.point => 'Point',
    GeometryType.linestring => 'Line',
    GeometryType.polygon => 'Polygon',
  };
}
