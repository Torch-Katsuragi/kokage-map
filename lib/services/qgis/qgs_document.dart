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

import 'qgs_model.dart';
import 'qgs_writer.dart';
import 'qgs_xml.dart';

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

  /// `<properties>` の下の `<kokage>` を返す。無ければ null
  XmlElement? get _kokageElement {
    final props = root.getElement('properties');
    return props == null ? null : _property(props, _kokageScope);
  }

  /// `<properties>` の中の [key] を返す。QGIS の書き方は 2 通りある:
  /// 3.x までの `<key type="…">` と、4.x の `<properties name="key" type="…">`
  /// （QGIS 4.2 で保存し直すと、こかげマップが書いた印も後者に書き換わる。2026-09-30 実測）
  static XmlElement? _property(XmlElement scope, String key) =>
      scope.getElement(key) ??
      scope.findElements('properties').where((e) => e.getAttribute('name') == key).firstOrNull;

  /// [_property] と同じだが、無ければ作る。作るときは文書の書き方に合わせる
  XmlElement _ensureProperty(XmlElement scope, String key) {
    final existing = _property(scope, key);
    if (existing != null) return existing;
    final named = root.getElement('properties')?.getAttribute('name') == 'properties';
    final created = named
        ? XmlElement(const XmlName.parts('properties'), [XmlAttribute(const XmlName.parts('name'), key)])
        : XmlElement(XmlName.parts(key));
    scope.children.add(created);
    return created;
  }

  /// 印を読む。無ければ null（QGIS か他人が作ったファイル）
  KokageStamp? get stamp {
    final k = _kokageElement;
    if (k == null) return null;
    final savedAt = _property(k, 'savedAt')?.innerText;
    final dirName = _property(k, 'dirName')?.innerText;
    if (savedAt == null || dirName == null) return null;
    final parsed = DateTime.tryParse(savedAt);
    if (parsed == null) return null;
    return KokageStamp(
      schemaVersion: int.tryParse(_property(k, 'schemaVersion')?.innerText ?? '') ?? 0,
      app: _property(k, 'app')?.innerText ?? '',
      savedAt: parsed,
      savedBy: _property(k, 'savedBy')?.innerText,
      dirName: dirName,
    );
  }

  /// 印を書く。root の `saveDateTime` も同じ値にする（QGIS が保存すると上書きされる）。
  void setStamp(KokageStamp stamp) {
    final props = ensureChild(root, 'properties');
    final k = _ensureProperty(props, _kokageScope);
    _setProperty(k, 'schemaVersion', '${stamp.schemaVersion}', type: 'int');
    _setProperty(k, 'app', stamp.app);
    _setProperty(k, 'savedAt', stamp.savedAtText);
    _setProperty(k, 'dirName', stamp.dirName);
    if (stamp.savedBy != null) {
      _setProperty(k, 'savedBy', stamp.savedBy!);
    } else {
      final stale = _property(k, 'savedBy');
      if (stale != null) detachNode(stale);
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

  /// アプリのフォルダ設定（`KMeta` の JSON）。無ければ null（QGIS か他人が作ったファイル）。
  ///
  /// `.kmeta.json` をやめて `.qgs` に一本化したときの置き場（2026-09-29）。QGIS が表現できる
  /// 部分（可視性・フィルタ・単一シンボル・並び）は別に QGIS の形でも書いてあり、QGIS 側で
  /// 保存されたときは読み戻し（`QgsReadBack`）がそちらを取り込んでここを書き直す。
  /// QGIS は保存時に知らない `<properties>` を残す（4.x では書き方だけ変わる。[_property]）。
  String? get kokageMeta {
    final k = _kokageElement;
    final text = k == null ? null : _property(k, 'meta')?.innerText;
    return text == null || text.isEmpty ? null : text;
  }

  set kokageMeta(String? json) {
    if (json == null) {
      final k = _kokageElement;
      final stale = k == null ? null : _property(k, 'meta');
      if (stale != null) detachNode(stale);
      return;
    }
    final props = ensureChild(root, 'properties');
    _setProperty(_ensureProperty(props, _kokageScope), 'meta', json);
  }

  /// QGIS の `<properties>` 流儀で値を置く（`<key type="QString">value</key>` か 4.x の書き方）
  void _setProperty(XmlElement scope, String key, String value, {String type = 'QString'}) {
    final el = _ensureProperty(scope, key);
    el.setAttribute('type', type);
    el.children.clear();
    el.children.add(XmlText(value));
  }

  // =============================================
  // レイヤ
  // =============================================

  XmlElement get _projectLayers => ensureChild(root, 'projectlayers');

  /// 文書内の `<maplayer>`
  Iterable<XmlElement> get mapLayers => _projectLayers.findElements('maplayer');

  XmlElement? findMapLayer(String id) => mapLayers
      .where((e) => e.getElement('id')?.innerText == id)
      .firstOrNull;

  /// 埋め込み（別プロジェクト由来）の maplayer か。[apply] は外す（子 dir は写しで入る）
  static bool isEmbedded(XmlElement e) => e.getAttribute('embedded') == '1';

  /// レイヤツリーのグループを埋め込みにする customproperties のキー
  static const _embeddingKeys = {'embedded', 'embedded_project', 'embedded-invisible-layers'};

  // =============================================
  // 反映
  // =============================================

  /// [project] の内容を文書に反映する。
  ///
  /// - レイヤツリーは [project] の構造で組み直す。既存の要素は id / 名前で拾って
  ///   属性と未知の子（`customproperties` 等）を引き継ぐ
  /// - `<maplayer>` は id で突き合わせ、あれば参照・フィルタ・単一シンボルの値だけ直す。
  ///   無ければ [QgsWriter] の形で足す。[project] に無いものは外して報告する
  ///   （埋め込みスタブは報告せずに外す）
  /// - `<layerorder>` は [project] の順で書き直す
  QgsApplyReport apply(QgsProject project) {
    final report = QgsApplyReport();
    root.setAttribute('projectname', project.name);
    ensureChild(root, 'title')
      ..children.clear()
      ..children.add(XmlText(project.name));

    _adoptRasterIds(project);
    final web = _webLayerIds();
    _applyTree(project, web);
    _applyMapLayers(project, report, web);
    _applyLayerOrder(project, web);
    return report;
  }

  // ---- 管轄外のレイヤ（ネットワークのタイル・サービス）----

  /// ネットワーク越しのデータを指すプロバイダ。ファイルではないのでこかげマップの管轄に入らず、
  /// `.qgs` に QGIS 側で足されたものはそのまま残す（外すと QGIS の利用者の背景地図が消える）
  static const _webProviders = {'wms', 'wcs', 'wfs', 'arcgismapserver', 'arcgisfeatureserver', 'xyzvectortiles'};

  /// ネットワーク越しのレイヤ（XYZ タイル・WMS など）か
  static bool isWebLayer(XmlElement maplayer) {
    if (maplayer.getAttribute('type') == 'vector-tile') return true;
    final provider = maplayer.getElement('provider')?.innerText.trim().toLowerCase();
    return provider != null && _webProviders.contains(provider);
  }

  /// 残す（触らない）maplayer の id。ツリーと `<layerorder>` でも残す
  Set<String> _webLayerIds() => {
        for (final e in mapLayers)
          if (!isEmbedded(e) && isWebLayer(e) && e.getElement('id') != null) e.getElement('id')!.innerText,
      };

  /// QGIS で足した gdal のラスタが、アプリの GeoTIFF（[QgsRasterLayer]）と同じファイルを指していれば、
  /// アプリの決定的な id に付け替える。外して足し直すと QGIS が付けたレンダラ（不透明度など）が消えるため
  void _adoptRasterIds(QgsProject project) {
    final layers = mapLayers.toList();
    final present = {for (final e in layers) e.getElement('id')?.innerText};
    final byPath = <String, QgsRasterLayer>{
      for (final r in project.rasterLayers)
        if (!present.contains(r.id)) _rasterPathKey(r.dataSourcePath): r,
    };
    if (byPath.isEmpty) return;
    final wanted = {for (final r in project.rasterLayers) r.id};
    for (final e in layers) {
      if (isEmbedded(e) || e.getAttribute('type') != 'raster') continue;
      if (e.getElement('provider')?.innerText.trim() != 'gdal') continue;
      final oldId = e.getElement('id')?.innerText;
      if (oldId == null || wanted.contains(oldId)) continue;
      final target = byPath.remove(_rasterPathKey(e.getElement('datasource')?.innerText ?? ''));
      if (target == null) continue;
      setChildText(e, 'id', target.id);
      for (final t in root.findAllElements('layer-tree-layer').where((t) => t.getAttribute('id') == oldId)) {
        t.setAttribute('id', target.id);
      }
    }
  }

  /// `./sub/a.tif` と `sub\a.tif` を同じに見る
  static String _rasterPathKey(String path) {
    var s = path.split('|').first.trim().replaceAll(r'\', '/');
    while (s.startsWith('./')) {
      s = s.substring(2);
    }
    return s.toLowerCase();
  }

  // ---- レイヤツリー ----

  void _applyTree(QgsProject project, Set<String> web) {
    final treeRoot = ensureChild(root, 'layer-tree-group');

    // 既存ノードを控える（id とグループ名で引く）
    final oldLayers = <String, XmlElement>{
      for (final e in treeRoot.findAllElements('layer-tree-layer'))
        if (e.getAttribute('id') != null) e.getAttribute('id')!: e,
    };

    // 管轄外（ネットワークのタイル等）は残す。グループは組み直すので root の一番下（地図では一番下）へ寄せる
    final rebuilt = [
      ..._rebuildChildren(project.root, treeRoot, oldLayers),
      for (final MapEntry(key: id, value: e) in oldLayers.entries)
        if (web.contains(id)) e.copy(),
    ];

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
      customOrder ?? XmlElement(const XmlName.parts('custom-order'), [XmlAttribute(const XmlName.parts('enabled'), '0')]),
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
        case QgsGroup():
          result.add(_rebuildGroup(node, oldGroups[node.name], oldLayers));
        case QgsLayer():
          result.add(
            _treeLayer(oldLayers[node.id] ?? _writer.treeLayerElement(node), node.id, node.name, node.dataSourceUri, 'ogr', node.visible),
          );
        case QgsRasterLayer():
          result.add(
            _treeLayer(
              oldLayers[node.id] ?? _writer.treeRasterLayerElement(node),
              node.id,
              node.name,
              node.dataSourcePath,
              'gdal',
              node.visible,
            ),
          );
      }
    }
    return result;
  }

  /// `<layer-tree-group>` を組み直す。[old]（同じ名前の既存グループ）があれば属性と
  /// ツリー以外の子（customproperties 等）を引き継ぐ。子のグループ・レイヤは [node] の構造で作り直す
  XmlElement _rebuildGroup(QgsGroup node, XmlElement? old, Map<String, XmlElement> oldLayers) {
    final XmlElement group;
    if (old == null) {
      group = _writer.treeGroupElement(node.name, visible: node.visible);
    } else {
      // 子は作り直すので、丸ごと写さず殻とツリー以外の子だけ写す（深いツリーで写しが重ならないように）
      group = XmlElement(XmlName.qualified(old.name.qualified), [
        for (final a in old.attributes) a.copy(),
      ], [
        for (final c in old.childElements)
          if (c.name.local != 'layer-tree-group' && c.name.local != 'layer-tree-layer') c.copy(),
      ]);
    }
    // 以前は埋め込みだったが、いまは普通のグループ（2026-09-30 に埋め込みをやめて写しにした）。
    // QGIS 4 は同じ印を customproperties にも書く（`<Option name="embedded" …/>`）
    group.removeAttribute('embedded');
    group.removeAttribute('embedded_project');
    for (final props in group.findElements('customproperties')) {
      props.descendantElements
          .where((e) => _embeddingKeys.contains(e.getAttribute('name') ?? e.getAttribute('key')))
          .toList()
          .forEach(detachNode);
    }
    group.setAttribute('name', node.name);
    group.setAttribute('checked', qgsCheckedValue(node.visible));
    group.setAttribute('expanded', node.expanded ? '1' : '0');
    group.children.addAll(_rebuildChildren(node.children, old, oldLayers));
    return group;
  }

  /// `<layer-tree-layer>` を [base] の写しから作り、管轄の属性だけ合わせる（他の属性と子は引き継ぐ）
  static XmlElement _treeLayer(XmlElement base, String id, String name, String source, String provider, bool visible) {
    final el = base.copy();
    el.setAttribute('id', id);
    el.setAttribute('name', name);
    el.setAttribute('source', source);
    el.setAttribute('providerKey', provider);
    el.setAttribute('checked', qgsCheckedValue(visible));
    return el;
  }

  // ---- maplayer ----

  void _applyMapLayers(QgsProject project, QgsApplyReport report, Set<String> web) {
    final layers = project.layers;
    final rasters = project.rasterLayers;
    final wanted = <String, QgsTreeNode>{
      for (final l in layers) l.id: l,
      for (final r in rasters) r.id: r,
    };
    final container = _projectLayers;

    // 埋め込みスタブは外す。子 dir も写しとして平らに入る（2026-09-30 に埋め込みをやめた。
    // それ以前に書いた `.qgs` と、手で足された埋め込み）
    for (final e in container.findElements('maplayer').toList()) {
      if (isEmbedded(e)) detachNode(e);
    }

    // 既存: 直す or 外す
    // ⚠ 同じ id の maplayer が複数あることがある（id 衝突バグがあった版の出力）。
    //   2つ目以降は外す。残さないと QGIS が1つに畳んで、どちらかの設定が消える
    final seen = <String>{};
    for (final e in container.findElements('maplayer').toList()) {
      if (isEmbedded(e)) continue;
      final id = e.getElement('id')?.innerText;
      // 管轄外（ネットワークのタイル等）は触らない
      if (id != null && web.contains(id) && !wanted.containsKey(id)) continue;
      final layer = id == null ? null : wanted[id];
      if (layer == null) {
        final name = e.getElement('layername')?.innerText ?? id ?? '?';
        report.removedLayers.add(name);
        detachNode(e);
        continue;
      }
      if (!seen.add(id!)) {
        detachNode(e);
        continue;
      }
      switch (layer) {
        case QgsLayer():
          _patchMapLayer(e, layer, report);
        case QgsRasterLayer():
          // ラスタは参照と名前だけが管轄。レンダラ（pipe）は QGIS 側の設定を残す
          setChildText(e, 'datasource', layer.dataSourcePath);
          setChildText(e, 'layername', layer.name);
        default:
          break;
      }
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
    for (final raster in rasters) {
      if (existing.contains(raster.id)) continue;
      container.children.add(_writer.rasterMapLayerElement(raster));
    }
  }

  /// 既存の `<maplayer>` を [layer] に合わせる。自分の管轄だけ触る
  void _patchMapLayer(XmlElement e, QgsLayer layer, QgsApplyReport report) {
    setChildText(e, 'datasource', layer.dataSourceUri);
    setChildText(e, 'layername', layer.name);
    e.setAttribute('geometry', qgsGeometryName(layer.geometryType));

    final renderer = e.getElement('renderer-v2');
    if (renderer == null) {
      final fresh = _writer.rendererElement(layer);
      if (fresh != null) insertIntoMapLayer(e, fresh);
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
      if (fresh != null) insertIntoMapLayer(e, fresh);
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
    final map = symbolOptionMap(symbolLayer);
    if (map == null) return;
    for (final entry in values.entries) {
      final option = namedOption(map, entry.key);
      if (option != null) {
        option.setAttribute('value', entry.value);
      } else {
        map.children.add(
          XmlElement(const XmlName.parts('Option'), [
            XmlAttribute(const XmlName.parts('name'), entry.key),
            XmlAttribute(const XmlName.parts('type'), 'QString'),
            XmlAttribute(const XmlName.parts('value'), entry.value),
          ]),
        );
      }
    }
  }

  /// 既存の色（`R,G,B,A,...`）を読む。読めなければ黒
  static Color _readColor(XmlElement symbolLayer, String name) {
    final map = symbolOptionMap(symbolLayer);
    final value = map == null ? null : namedOption(map, name)?.getAttribute('value');
    final parts = value?.split(',') ?? const [];
    if (parts.length < 3) return const Color(0xFF000000);
    int channel(int i) => int.tryParse(parts[i].trim())?.clamp(0, 255) ?? 0;
    return Color.fromARGB(255, channel(0), channel(1), channel(2));
  }

  // ---- layerorder ----

  void _applyLayerOrder(QgsProject project, Set<String> web) {
    final order = ensureChild(root, 'layerorder');
    // 管轄外のレイヤは下（後ろ）に、元の順のまま
    final previous = [for (final l in order.findElements('layer')) l.getAttribute('id')];
    final keptWeb = [
      for (final id in previous)
        if (id != null && web.contains(id)) id,
      for (final id in web)
        if (!previous.contains(id)) id,
    ];
    order.children.clear();
    for (final id in [...project.orderedLayerIds, ...keptWeb]) {
      order.children.add(
        XmlElement(const XmlName.parts('layer'), [XmlAttribute(const XmlName.parts('id'), id)]),
      );
    }
  }
}
