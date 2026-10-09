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
/// `.qgs`（QGISプロジェクト）を読んで View に変換する。
///
/// > [!IMPORTANT] 読むときは寛容に、ただし捨てたものは必ず報告する
/// > 一度読んで変換して捨てるだけ。`.qgs` を正典として持たない。
/// > 他人が作ったファイルは多少崩れていても読むが、**飲み込めなかったものを
/// > 黙って落とすのが一番まずい**。全部 [QgsImportResult.discarded] に入れる。
///
/// ルール（[[docs/technical/project-format-design#QGISプロジェクトのインポート（寛容側）]]）:
///
/// 1. **root外への参照は丸ごと捨てる。** `C:\work\data.shp` やPostGIS接続を指す
///    レイヤは山の中のスマホでは開けない。残すと「レイヤはあるが表示されない」
///    という最悪の状態になる
/// 2. **QGISのグループ階層は採らない。** レイヤ構造は dir 構造に置き換える
/// 3. **生き残った参照のスタイルは View として再利用する**
/// 4. **捨てたものは必ず報告する**
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart' show Color;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/basemap_provider.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/image_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../models/nodes/view_node.dart';
import '../../utils/app_logger.dart';
import '../../utils/label_expression.dart';
import '../kmeta_service.dart';
import 'qgs_project_builder.dart' show QgsProjectBuilder;
import 'qgs_raster_source.dart';
import 'qgs_xml.dart';

/// px ⇄ mm（QGISのシンボル単位はMM）。96dpi 相当。[[qgs_writer]] の逆。
const double _kMmToPx = 96 / 25.4;

/// 取り込んだ結果。
class QgsImportResult {
  const QgsImportResult({
    required this.viewsByLayer,
    required this.discarded,
    this.baseMaps = const [],
    this.overlayCount = 0,
  });

  /// レイヤキー（`gpkgName/layerName`）→ 作った View名の並び
  final Map<String, List<String>> viewsByLayer;

  /// 取り込めなかったもの。理由つきの1行で入れる。
  final List<String> discarded;

  /// XYZ タイルのレイヤ（背景地図の一覧に当たったもの）。背景地図は端末の設定なので、
  /// ここでは読むだけで足さない（`QgsBaseMapImport` が足す）
  final List<QgsBaseMap> baseMaps;

  /// 可視性を読み戻したオーバーレイ画像（GeoTIFF）の数
  final int overlayCount;

  int get importedViewCount =>
      viewsByLayer.values.fold(0, (sum, list) => sum + list.length);

  bool get isEmpty => viewsByLayer.isEmpty;
}

/// QGISのデータソース文字列から取り出したもの。
class QgsDataSource {
  const QgsDataSource({required this.path, this.layerName, this.subset});

  /// `.qgs` からの相対、または絶対パス
  final String path;

  /// GeoPackage内のテーブル名
  final String? layerName;

  /// subset string（SQLのWHERE句）
  final String? subset;

  /// OGRのデータソース文字列を分解する。
  ///
  /// `path|layername=foo|subset=bar` の形。`|` で区切られ、`key=value` が続く。
  /// ⚠ subset にも `|` が入りうるので、**subset は最後まで丸ごと**取る。
  static QgsDataSource? parse(String raw) {
    if (raw.trim().isEmpty) return null;

    // subset は残り全部。先に切り出しておかないと `|` で壊れる
    String rest = raw;
    String? subset;
    final subsetAt = rest.indexOf('|subset=');
    if (subsetAt >= 0) {
      subset = rest.substring(subsetAt + '|subset='.length);
      rest = rest.substring(0, subsetAt);
    }

    final parts = rest.split('|');
    final path = parts.first.trim();
    String? layerName;
    for (final part in parts.skip(1)) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      final value = part.substring(eq + 1).trim();
      if (key == 'layername') layerName = value;
      // layerid / geometrytype / table 等は使わない
    }
    if (path.isEmpty) return null;
    return QgsDataSource(path: path, layerName: layerName, subset: subset);
  }
}

class QgsImporter {
  const QgsImporter();

  /// [qgsPath] を読み、[root] の下にある GeoPackage レイヤに View を足す。
  ///
  /// 同じレイヤを指す QGISレイヤが N枚あれば、**N個の View** になる。
  /// View が無かった状態からのロスがここで消える。
  ///
  /// ⚠ 取り込み対象になったレイヤの View は**丸ごと置き換える**。
  /// 何度読んでも増えないようにするため。触らなかったレイヤはそのまま。
  ///
  /// [acceptOwner] は、設定の持ち主の dir（レイヤ・gpkg なら置き場所の dir、dir の可視性なら親）
  /// ごとに取り込むかを決める。祖先の `.qgs` にある写しが、持ち主の新しい設定より古いときに
  /// 巻き戻さないため（[QgsReadBack]）。
  Future<QgsImportResult> import(
    String qgsPath,
    FolderNode root, {
    bool Function(FolderNode owner)? acceptOwner,
  }) async {
    bool accepts(FolderNode? owner) => acceptOwner == null || (owner != null && acceptOwner(owner));
    final discarded = <String>[];

    final XmlDocument doc;
    try {
      final raw = await readQgsText(qgsPath);
      try {
        doc = XmlDocument.parse(raw);
      } catch (e) {
        return QgsImportResult(viewsByLayer: const {}, discarded: ['XMLとして読めませんでした（$e）']);
      }
    } catch (e) {
      AppLogger.debug('[QgsImporter] 読めない: $e');
      return QgsImportResult(viewsByLayer: const {}, discarded: ['$qgsPath を読めませんでした（$e）']);
    }

    final rootPath = root.getAbsoluteFilePath();
    final qgsDir = p.dirname(p.normalize(qgsPath));
    final sources = _SourceResolver(qgsDir, rootPath, _indexGeoPackages(root), _indexImages(root));
    final tree = _TreeVisibility.read(doc);
    // 形が合ったレイヤの、グループ側の可視性（レイヤ・gpkg・dir）
    final layerGroupChecked = <LayerNode, bool>{};
    final containerChecked = <LayerTreeNode, bool>{};

    // 取り込み対象になったレイヤ。ここに入ったものだけ View を差し替える
    final touched = <LayerNode, List<ViewNode>>{};

    // ⚠ `maplayer` は文書全体を探さない。QGIS は `<main-annotation-layer>` の
    //    ような「ユーザーのレイヤではないもの」も同じ形で書くため、
    //    `<projectlayers>` の下だけを相手にする。
    final projectLayers = doc.rootElement.findElements('projectlayers').firstOrNull;
    for (final maplayer in projectLayers?.findElements('maplayer') ?? const <XmlElement>[]) {
      final target = sources.resolve(maplayer, discarded);
      if (target == null) continue;
      final (:name, :source, :layer, :gpkg) = target;
      // 持ち主のほうが新しい（この写しは古い）。黙って飛ばす
      if (!accepts(layer.folderNode)) continue;

      final id = childText(maplayer, 'id');
      final shaped = id != null && tree.readGroups(id, layer, gpkg, root, layerGroupChecked, containerChecked);
      final views = touched.putIfAbsent(layer, () => []);
      // レイヤと同じ名前でフィルタの無い QGIS レイヤは既定 View（こかげマップは既定 View をレイヤ名で書く。
      // QGIS でふつうに足したレイヤもこの形）。旧版が書いた「既定」もそのまま既定 View
      final isDefault = name == layer.layerName &&
          (source.subset == null || source.subset!.isEmpty) &&
          !views.any((v) => v.name == kDefaultViewName);
      views.add(
        ViewNode(
          name: isDefault ? kDefaultViewName : _uniqueName(name, views),
          parent: layer,
          filter: source.subset,
          style: readStyleWithLabel(maplayer),
          visible: id == null ? true : (shaped ? tree.ownChecked[id]! : (tree.checked[id] ?? true)),
        ),
      );
    }

    // まとめて差し替える。途中で失敗しても中途半端に混ざらないように
    final viewsByLayer = <String, List<String>>{};
    for (final MapEntry(key: layer, value: views) in touched.entries) {
      await _replaceViews(layer, views, layerGroupChecked[layer]);
      // 子孫の dir の写しも取り込むので、同名の gpkg/レイヤが別の dir にありうる。dir を添えて数え分ける
      final folderPath = layer.folderNode?.getAbsoluteFilePath();
      final relDir = folderPath == null || rootPath == null ? '.' : p.relative(folderPath, from: rootPath);
      viewsByLayer[relDir == '.' ? layer.layerKey : '${relDir.replaceAll(r'\', '/')}/${layer.layerKey}'] = [
        for (final v in views) v.name,
      ];
    }

    // gpkg と dir のグループの可視性（変わったものだけ書く）
    for (final MapEntry(key: node, value: checked) in containerChecked.entries) {
      if (node.visible == checked) continue;
      final owner = node.parent;
      if (!accepts(owner is FolderNode ? owner : null)) continue;
      node.visible = checked;
      await node.persistVisibility();
    }

    // オーバーレイ画像（GeoTIFF）の可視性。ファイルは dir にあるものが正で、`.qgs` からは表示だけ取る
    var overlayCount = 0;
    for (final (:node, :id) in sources.overlays) {
      final owner = node.parent;
      if (owner is! FolderNode || !accepts(owner)) continue;
      // こかげマップが書いた形（決定的な id）なら dir グループの消灯は dir の可視性なので、自身の checked。
      // QGIS で足したものは祖先で畳む（グループごと消灯した場合も読み戻す）
      final abs = node.getAbsoluteFilePath();
      final rel = abs == null ? null : relativeInside(qgsDir, abs);
      final ownForm = rel != null && id == QgsProjectBuilder.rasterLayerIdForPath('./$rel');
      final visible = (ownForm ? tree.ownChecked[id] : tree.checked[id]) ?? true;
      overlayCount++;
      if (node.visible == visible) continue;
      node.visible = visible;
      await node.persistVisibility();
    }

    // XYZ タイル（背景地図）。端末の設定なのでここでは読むだけ
    final baseMaps = [
      for (final (:providerId, :name, :id, :opacity) in sources.baseMaps)
        QgsBaseMap(providerId: providerId, layerName: name, visible: tree.checked[id] ?? true, opacity: opacity),
    ];

    AppLogger.debug(
      '[QgsImporter] View ${viewsByLayer.values.fold(0, (s, l) => s + l.length)} 個を'
      '${viewsByLayer.length} レイヤに取り込み（オーバーレイ $overlayCount 枚・背景地図 ${baseMaps.length} 枚・'
      '除外 ${discarded.length} 件）',
    );
    return QgsImportResult(
      viewsByLayer: viewsByLayer,
      discarded: discarded,
      baseMaps: baseMaps,
      overlayCount: overlayCount,
    );
  }

  // =============================================
  // 部品
  // =============================================

  /// [layer] の View を [views] に置き換えて保存する。可視性とスタイルも書く。
  /// [groupChecked] はこかげマップが書いた形のときの、レイヤグループの可視性
  Future<void> _replaceViews(LayerNode layer, List<ViewNode> views, bool? groupChecked) async {
    layer.views
      ..clear()
      ..addAll(views);
    await layer.persistViews();
    // 可視性は View 定義とは別の場所に持つ。
    // 既定 View 1枚だけのレイヤは View ではなく**レイヤの可視性**で表す
    // （暗黙の既定 View は フォルダ設定（`.qgs`） に書かれず、可視性も読まれないため）
    if (views.length == 1 && views.first.isDefaultView) {
      layer.visible = views.first.visible && (groupChecked ?? true);
      await layer.persistVisibility();
      // スタイルもレイヤ側に持つ。既定 View は書かれないので、View に入れたままだと消える
      // （2026-09-29 まで、QGIS で変えた色は既定 View 1枚のレイヤに届いていなかった）
      final imported = views.first.style;
      if (imported != null) await _applyLayerStyle(layer, imported);
      return;
    }
    for (final v in views) {
      await v.persistVisibility();
    }
    if (groupChecked != null && layer.visible != groupChecked) {
      layer.visible = groupChecked;
      await layer.persistVisibility();
    }
  }

  /// QGIS から読んだスタイルをレイヤのスタイルに重ねる。QGIS が持たない項目（ラベルの濃さ等）は残し、
  /// 描き分けの印（[KMetaLayerStyle.qgisRenderer]）は QGIS の今の状態に合わせる（単一シンボルに戻したら外す）
  Future<void> _applyLayerStyle(LayerNode layer, KMetaLayerStyle imported) async {
    final folder = layer.folderNode;
    final folderPath = folder?.getAbsoluteFilePath();
    if (folder == null || folderPath == null) return;
    final existing = (await KMetaService.instance.getMeta(folderPath)).styles.layers[layer.layerKey];
    var merged = imported.mergeWith(existing);
    if (imported.qgisRenderer == null && merged.qgisRenderer != null) {
      merged = KMetaLayerStyle.fromJson(merged.toJson()..remove('qgisRenderer'));
    }
    await KMetaService.instance.setLayerStyle(folderPath, layer.layerKey, merged);
    folder.invalidateMetaCache();
    layer.invalidateKmetaStyleCache();
  }

  /// `.qgs` ならそのまま、`.qgz`（zip）なら中の `.qgs` を取り出して返す。
  ///
  /// QGIS の既定保存形式は `.qgz`。中に `.qgs`（本体）と `.qgd`（補助 DB）が入る。
  /// 読むだけで、書くときは常に `.qgs`。
  static Future<String> readQgsText(String path) async {
    if (!path.toLowerCase().endsWith('.qgz')) {
      return fs.readAsString(path);
    }
    final bytes = await fs.readAsBytes(path);
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive.files) {
      if (file.isFile && file.name.toLowerCase().endsWith('.qgs')) {
        return utf8.decode(file.content as List<int>);
      }
    }
    throw const FormatException('.qgz の中に .qgs がありません');
  }

  /// ルート以下の GeoPackage を、正規化した絶対パスで引けるようにする
  Map<String, GeoPackageNode> _indexGeoPackages(LayerTreeNode node) {
    final result = <String, GeoPackageNode>{};
    void walk(LayerTreeNode n) {
      if (n is GeoPackageNode) {
        final abs = n.geoPackageFile.getAbsolutePath();
        if (abs != null) result[p.normalize(abs)] = n;
      }
      for (final child in n.children) {
        walk(child);
      }
    }

    walk(node);
    return result;
  }

  /// ルート以下の画像（写真・オーバーレイ）を、正規化した絶対パスで引けるようにする
  Map<String, ImageNode> _indexImages(LayerTreeNode node) {
    final result = <String, ImageNode>{};
    void walk(LayerTreeNode n) {
      if (n is ImageNode) {
        final abs = n.getAbsoluteFilePath();
        if (abs != null) result[p.normalize(abs)] = n;
      }
      for (final child in n.children) {
        walk(child);
      }
    }

    walk(node);
    return result;
  }

  /// 同一レイヤ内で View名が衝突しないようにする（QGISは同名レイヤを許す）
  String _uniqueName(String base, List<ViewNode> existing) {
    if (!existing.any((v) => v.name == base)) return base;
    var n = 2;
    while (existing.any((v) => v.name == '$base $n')) {
      n++;
    }
    return '$base $n';
  }

  // =============================================
  // レンダラ → KMetaLayerStyle
  // =============================================

  /// シンボルとラベルをまとめて読む（どちらも無ければ null）
  KMetaLayerStyle? readStyleWithLabel(XmlElement maplayer) {
    final symbol = readStyle(maplayer);
    final label = readLabel(maplayer);
    if (label == null) return symbol;
    return (symbol ?? const KMetaLayerStyle()).mergeWith(label);
  }

  /// `<labeling type="simple">` のフィールド（式）・サイズ・色と `labelsEnabled`。
  ///
  /// QGIS が `isExpression="0"` で書いた列名は `"列"` の式に読み替える。
  /// 式そのものは検証せずに持ち帰る（読めない式は地図に出ないだけで、消さない）
  KMetaLayerStyle? readLabel(XmlElement maplayer) {
    final enabledAttr = maplayer.getAttribute('labelsEnabled');
    final labeling = maplayer.findElements('labeling').firstOrNull;
    if (enabledAttr == null && labeling == null) return null;
    String? expression;
    double? fontPx;
    Color? color;
    Color? halo;
    if (labeling != null && labeling.getAttribute('type') == 'simple') {
      final textStyle = labeling.getElement('settings')?.getElement('text-style');
      if (textStyle != null) {
        final field = textStyle.getAttribute('fieldName');
        if (field != null && field.isNotEmpty) {
          expression = textStyle.getAttribute('isExpression') == '1' ? field : quoteField(field);
        }
        final size = double.tryParse(textStyle.getAttribute('fontSize') ?? '');
        if (size != null) {
          // Point → px（書き出しの逆: px * 0.75 = pt）
          fontPx = textStyle.getAttribute('fontSizeUnit') == 'Point' ? size / 0.75 : size;
        }
        color = _color(textStyle.getAttribute('textColor'));
        final buffer = textStyle.getElement('text-buffer');
        if (buffer != null && buffer.getAttribute('bufferDraw') == '1') {
          halo = _color(buffer.getAttribute('bufferColor'));
        }
      }
    }
    final enabled = enabledAttr == null ? (expression != null) : enabledAttr == '1';
    return KMetaLayerStyle(
      labelEnabled: enabled,
      labelProperty: expression,
      labelFontSize: fontPx,
      labelColor: color,
      labelHaloColor: halo,
    );
  }

  /// `renderer-v2` から見た目を拾う。読めない形なら null（＝スタイル無し）。
  ///
  /// > [!NOTE] 拾うのは単一シンボルの1レイヤ目だけ
  /// > QGISのシンボルは重ね合わせも段階分けもできるが、こかげマップ 側に受け皿が無い。
  /// > 分類分け（categorizedSymbol 等）は最初のシンボルの色を採るだけ。
  /// > **完全再現は狙わない。** 狙うと「開けるファイルを選り好みする」方向に行く。
  KMetaLayerStyle? readStyle(XmlElement maplayer) {
    final style = _readSymbolStyle(maplayer);
    final type = maplayer.findElements('renderer-v2').firstOrNull?.getAttribute('type');
    // 単一シンボル以外は、代表の色で描きつつ「QGIS で設定されたスタイル」として印を付ける
    if (type == null || type == 'singleSymbol') return style;
    return (style ?? const KMetaLayerStyle()).copyWith(qgisRenderer: type);
  }

  KMetaLayerStyle? _readSymbolStyle(XmlElement maplayer) {
    final renderer = maplayer.findElements('renderer-v2').firstOrNull;
    if (renderer == null) return null;
    final symbol = renderer.findAllElements('symbol').firstOrNull;
    if (symbol == null) return null;
    final symbolLayer = symbol.findElements('layer').firstOrNull;
    if (symbolLayer == null) return null;

    final props = _readProps(symbolLayer);
    if (props.isEmpty) return null;

    switch (symbol.getAttribute('type')) {
      case 'marker':
        return KMetaLayerStyle(
          pointColor: _color(props['color']),
          // QGIS の size は直径(MM)。こかげマップ は半径感覚の px
          pointSize: _px(props['size'], divideBy: 2),
        );
      case 'line':
        return KMetaLayerStyle(
          lineColor: _color(props['line_color'] ?? props['color']),
          lineWidth: _px(props['line_width'] ?? props['width']),
        );
      case 'fill':
        final fill = _color(props['color']);
        final stroke = _color(props['outline_color'] ?? props['border_color']);
        return KMetaLayerStyle(
          polygonFillColor: fill,
          polygonFillOpacity: _alpha(props['color']),
          polygonBorderColor: stroke,
          polygonBorderOpacity: _alpha(
            props['outline_color'] ?? props['border_color'],
          ),
          polygonBorderWidth: _px(
            props['outline_width'] ?? props['border_width'],
          ),
        );
      default:
        return null;
    }
  }

  /// シンボルレイヤのプロパティを読む。
  ///
  /// ⚠ QGIS 3.x は `<Option name= value=>`、それ以前は `<prop k= v=>`。
  /// **両方読む。** 他人のファイルは古い形式で来る。
  Map<String, String> _readProps(XmlElement symbolLayer) {
    final props = <String, String>{};

    // 旧形式（QGIS 3.x より前）。`<layer>` の直下に並ぶ
    for (final prop in symbolLayer.findElements('prop')) {
      final k = prop.getAttribute('k');
      final v = prop.getAttribute('v');
      if (k != null && v != null) props[k] = v;
    }

    // 新形式。`<layer>` の**直下の** `<Option type="Map">` の子だけを見る。
    //
    // ⚠ 再帰で拾ってはいけない。QGIS は `<layer>` の中に
    //   `<data_defined_properties>` も書き、そこにも `name="name"` などの
    //   `<Option>` が入っている。まとめて読むと本物の値を上書きしてしまう
    //   （QGIS 3.44 の実出力で確認）。
    for (final map in symbolLayer.findElements('Option')) {
      if (map.getAttribute('type') != 'Map') continue;
      for (final option in map.findElements('Option')) {
        final name = option.getAttribute('name');
        final value = option.getAttribute('value');
        if (name != null && value != null) props[name] = value;
      }
    }
    return props;
  }

  /// QGIS の `R,G,B,A`（各0-255）
  ///
  /// ⚠ QGIS 3.44 は後ろに浮動小数表記を足してくる:
  /// `30,144,255,255,rgb:0.1176471,0.5647059,1,1`。先頭4つだけ見ればよい。
  Color? _color(String? value) {
    if (value == null) return null;
    final parts = value.split(',');
    if (parts.length < 3) return null;
    final rgb = [
      for (final part in parts.take(3)) int.tryParse(part.trim()) ?? 0,
    ];
    // アルファは別途 opacity として持つので、色は不透明にしておく
    return Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
  }

  /// `R,G,B,A` のAを 0..1 で返す
  double? _alpha(String? value) {
    if (value == null) return null;
    final parts = value.split(',');
    if (parts.length < 4) return null;
    final a = int.tryParse(parts[3].trim());
    return a == null ? null : a / 255;
  }

  double? _px(String? mm, {double divideBy = 1}) {
    if (mm == null) return null;
    final value = double.tryParse(mm.trim());
    if (value == null) return null;
    return value * _kMmToPx / divideBy;
  }
}

/// `<maplayer>` のデータソースを、ツリーの GeoPackage レイヤに結びつける
class _SourceResolver {
  _SourceResolver(this.qgsDir, this.rootPath, this.gpkgIndex, this.imageIndex);

  /// `.qgs` のある dir（相対パスの基準）
  final String qgsDir;
  final String? rootPath;

  /// 正規化した絶対パス → GeoPackage
  final Map<String, GeoPackageNode> gpkgIndex;

  /// 正規化した絶対パス → 画像（写真・オーバーレイ）
  final Map<String, ImageNode> imageIndex;

  /// gdal のラスタのうち、dir にあるオーバーレイ画像に当たったもの（maplayer の id つき）
  final overlays = <({OverlayImageNode node, String id})>[];

  /// wms の XYZ タイルのうち、背景地図の一覧に当たったもの
  final baseMaps = <({String providerId, String name, String id, int opacity})>[];

  /// 取り込む先のレイヤ。取り込めなければ理由を [discarded] に足して null。
  /// 黙って飛ばすもの（埋め込みスタブ・ラスタ）も null
  ({String name, QgsDataSource source, LayerNode layer, GeoPackageNode gpkg})? resolve(
    XmlElement maplayer,
    List<String> discarded,
  ) {
    // 埋め込みスタブ（別プロジェクトの管轄。2026-09-30 以前にこかげマップが書いたものか、手で足したもの）
    if (maplayer.getAttribute('embedded') == '1') return null;

    final name = childText(maplayer, 'layername') ?? '(名前なし)';
    final provider = childText(maplayer, 'provider')?.toLowerCase();

    // ラスタはレイヤ（View）にはならない。GeoTIFF はオーバーレイ画像、XYZ タイルは背景地図へ
    if (maplayer.getAttribute('type') == 'raster') {
      _resolveRaster(maplayer, name, provider, discarded);
      return null;
    }

    if (provider != null && provider != 'ogr') {
      // PostGIS / WMS / メモリレイヤ等。ファイルとして持ち歩けない
      discarded.add('$name（$provider は取り込めません）');
      return null;
    }

    final source = QgsDataSource.parse(childText(maplayer, 'datasource') ?? '');
    if (source == null || source.layerName == null) {
      discarded.add('$name（データソースを読み取れません）');
      return null;
    }

    final absPath = p.normalize(p.isAbsolute(source.path) ? source.path : p.join(qgsDir, source.path));
    final root = rootPath;
    if (root == null || relativeInside(root, absPath) == null) {
      // ⚠ 相対パスで root 外を指すケース（`../shared/kyoyu.gpkg`）は
      //    林業では現実にありそう。判定は正規化した絶対パスで行う
      discarded.add('$name（プロジェクトフォルダの外を参照している）');
      return null;
    }

    final gpkg = gpkgIndex[absPath];
    if (gpkg == null) {
      discarded.add('$name（${p.basename(absPath)} が見つかりません）');
      return null;
    }

    final layer = gpkg.children.whereType<LayerNode>().where((l) => l.layerName == source.layerName).firstOrNull;
    if (layer == null) {
      discarded.add('$name（${gpkg.name} に ${source.layerName} がありません）');
      return null;
    }
    return (name: name, source: source, layer: layer, gpkg: gpkg);
  }

  /// ラスタの `<maplayer>` を [overlays] か [baseMaps] に振り分ける。扱えなければ理由を [discarded] に足す。
  ///
  /// dir に置かれたファイルが正で、`.qgs` は表示の設定を運ぶだけ（[[docs/technical/external-formats]]）。
  /// GeoTIFF のノードは dir の中身から作られているので、ここでは突き合わせるだけで作らない
  void _resolveRaster(XmlElement maplayer, String name, String? provider, List<String> discarded) {
    final id = childText(maplayer, 'id') ?? '';
    final datasource = childText(maplayer, 'datasource') ?? '';
    switch (provider) {
      case 'gdal':
        if (datasource.trim().isEmpty || QgsRasterSource.isNonFileSource(datasource)) {
          discarded.add('$name（ファイルではないラスタは取り込めません）');
          return;
        }
        final path = datasource.split('|').first.trim();
        final absPath = p.normalize(p.isAbsolute(path) ? path : p.join(qgsDir, path));
        final root = rootPath;
        if (root == null || relativeInside(root, absPath) == null) {
          discarded.add('$name（プロジェクトフォルダの外を参照している）');
          return;
        }
        final ext = p.extension(absPath).toLowerCase();
        if (ext != '.tif' && ext != '.tiff') {
          discarded.add('$name（GeoTIFF 以外のラスタは未対応）');
          return;
        }
        final node = imageIndex[absPath];
        if (node == null) {
          discarded.add('$name（${p.basename(absPath)} が見つかりません）');
        } else if (node is! OverlayImageNode) {
          // 位置を読めるのはこかげマップが書く形（ModelTransformationTag・WGS84）だけ。
          // GDAL の既定（ModelTiepoint + ModelPixelScale）や投影座標系の GeoTIFF は写真として並ぶ
          discarded.add('$name（${p.basename(absPath)} の位置を読めません。こかげマップで位置合わせした GeoTIFF のみ対応）');
        } else {
          overlays.add((node: node, id: id));
        }
      case 'wms':
        final url = QgsRasterSource.xyzUrl(datasource);
        if (url == null) {
          discarded.add('$name（WMS は未対応）');
          return;
        }
        final known = BaseMapProvider.findByTileUrl(url);
        if (known == null) {
          final host = Uri.tryParse(url)?.host ?? '';
          discarded.add('$name（背景地図の一覧に無い XYZ タイル${host.isEmpty ? '' : ': $host'}）');
          return;
        }
        baseMaps.add((providerId: known.id, name: name, id: id, opacity: QgsRasterSource.opacityPercent(maplayer)));
      default:
        discarded.add('$name（${provider ?? '不明なプロバイダ'} のラスタは取り込めません）');
    }
  }
}

/// レイヤツリーの表示状態（checked）。レイヤの id で引く
class _TreeVisibility {
  /// 祖先の checked を AND で畳んだもの。QGIS は親グループが Unchecked なら子も描かないので、
  /// QGIS ユーザーがグループごと消灯した場合も読み戻せるように
  final checked = <String, bool>{};

  /// レイヤ自身の checked（こかげマップが書いた形なら、グループの checked は別に読むので畳まない）
  final ownChecked = <String, bool>{};

  /// 近い順の祖先グループ（名前と自身の checked）
  final ancestors = <String, List<(String, bool)>>{};

  static _TreeVisibility read(XmlDocument doc) {
    final result = _TreeVisibility();
    final treeRoot = doc.rootElement.findElements('layer-tree-group').firstOrNull;
    if (treeRoot != null) result._walk(treeRoot, true, const []);
    return result;
  }

  void _walk(XmlElement node, bool parentChecked, List<(String, bool)> chain) {
    for (final child in node.childElements) {
      final own = child.getAttribute('checked') != 'Qt::Unchecked';
      final folded = parentChecked && own;
      if (child.name.local == 'layer-tree-group') {
        _walk(child, folded, [(child.getAttribute('name') ?? '', own), ...chain]);
      } else if (child.name.local == 'layer-tree-layer') {
        final id = child.getAttribute('id');
        if (id != null) {
          checked[id] = folded;
          ownChecked[id] = own;
          ancestors[id] = chain;
        }
      }
    }
  }

  /// こかげマップが書いた形（dir グループ > gpkg グループ > レイヤグループ > View）なら、
  /// グループの checked をレイヤ・gpkg・dir の可視性として [layerGroup] と [containers] に入れて true
  bool readGroups(
    String id,
    LayerNode layer,
    GeoPackageNode gpkg,
    FolderNode root,
    Map<LayerNode, bool> layerGroup,
    Map<LayerTreeNode, bool> containers,
  ) {
    final chain = ancestors[id];
    // 親がレイヤグループ、その親が gpkg グループ
    if (chain == null || chain.length < 2 || chain[0].$1 != layer.layerName || chain[1].$1 != gpkg.name) {
      return false;
    }
    layerGroup[layer] = chain[0].$2;
    containers[gpkg] = chain[1].$2;
    // その上は dir グループ（プロジェクト root 自身はグループにならない）
    LayerTreeNode? folder = gpkg.parent;
    for (var i = 2; i < chain.length && folder is FolderNode && !identical(folder, root); i++) {
      if (chain[i].$1 != folder.name) break;
      containers[folder] = chain[i].$2;
      folder = folder.parent;
    }
    return true;
  }
}
