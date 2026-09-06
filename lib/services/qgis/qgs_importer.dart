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
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart' show Color;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/view_node.dart';
import '../../utils/app_logger.dart';

/// px ⇄ mm（QGISのシンボル単位はMM）。96dpi 相当。[[qgs_writer]] の逆。
const double _kMmToPx = 96 / 25.4;

/// 取り込んだ結果。
class QgsImportResult {
  const QgsImportResult({
    required this.viewsByLayer,
    required this.discarded,
  });

  /// レイヤキー（`gpkgName/layerName`）→ 作った View名の並び
  final Map<String, List<String>> viewsByLayer;

  /// 取り込めなかったもの。理由つきの1行で入れる。
  final List<String> discarded;

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
  Future<QgsImportResult> import(String qgsPath, FolderNode root) async {
    final discarded = <String>[];
    final viewsByLayer = <String, List<String>>{};

    final String raw;
    try {
      raw = await readQgsText(qgsPath);
    } catch (e) {
      AppLogger.debug('[QgsImporter] 読めない: $e');
      return QgsImportResult(
        viewsByLayer: const {},
        discarded: ['$qgsPath を読めませんでした（$e）'],
      );
    }

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(raw);
    } catch (e) {
      return QgsImportResult(
        viewsByLayer: const {},
        discarded: ['XMLとして読めませんでした（$e）'],
      );
    }

    final qgsDir = p.dirname(p.normalize(qgsPath));
    final rootPath = root.getAbsoluteFilePath();
    final gpkgIndex = _indexGeoPackages(root);

    // ツリーの表示状態（checked）はレイヤツリー側にある。IDで引けるようにする。
    // QGIS は親グループが Unchecked なら子も描かないので、祖先の checked を AND で畳む
    // （QGIS ユーザーがグループごと消灯した場合も読み戻せるように）
    final checkedById = <String, bool>{};
    void walkTree(XmlElement node, bool parentChecked) {
      for (final child in node.childElements) {
        final checked = parentChecked && child.getAttribute('checked') != 'Qt::Unchecked';
        if (child.name.local == 'layer-tree-group') {
          walkTree(child, checked);
        } else if (child.name.local == 'layer-tree-layer') {
          final id = child.getAttribute('id');
          if (id != null) checkedById[id] = checked;
        }
      }
    }
    final treeRoot = doc.rootElement.findElements('layer-tree-group').firstOrNull;
    if (treeRoot != null) walkTree(treeRoot, true);

    // 取り込み対象になったレイヤ。ここに入ったものだけ View を差し替える
    final touched = <LayerNode, List<ViewNode>>{};

    // ⚠ `maplayer` は文書全体を探さない。QGIS は `<main-annotation-layer>` の
    //    ような「ユーザーのレイヤではないもの」も同じ形で書くため、
    //    `<projectlayers>` の下だけを相手にする。
    final projectLayers =
        doc.rootElement.findElements('projectlayers').firstOrNull;
    for (final maplayer in projectLayers?.findElements('maplayer') ??
        const <XmlElement>[]) {
      // 埋め込みスタブ（子 dir の `.qgs` の管轄）。ここでは扱わない
      if (maplayer.getAttribute('embedded') == '1') continue;

      final name = _text(maplayer, 'layername') ?? '(名前なし)';
      final provider = _text(maplayer, 'provider')?.toLowerCase();

      if (provider != null && provider != 'ogr') {
        // PostGIS / WMS / メモリレイヤ等。ファイルとして持ち歩けない
        discarded.add('$name（$provider は取り込めません）');
        continue;
      }

      final source = QgsDataSource.parse(_text(maplayer, 'datasource') ?? '');
      if (source == null || source.layerName == null) {
        discarded.add('$name（データソースを読み取れません）');
        continue;
      }

      final absPath = p.normalize(
        p.isAbsolute(source.path) ? source.path : p.join(qgsDir, source.path),
      );

      if (!_isInsideRoot(rootPath, absPath)) {
        // ⚠ 相対パスで root 外を指すケース（`../shared/kyoyu.gpkg`）は
        //    林業では現実にありそう。判定は正規化した絶対パスで行う
        discarded.add('$name（プロジェクトフォルダの外を参照している）');
        continue;
      }

      final gpkg = gpkgIndex[absPath];
      if (gpkg == null) {
        discarded.add('$name（${p.basename(absPath)} が見つかりません）');
        continue;
      }

      final layer = gpkg.children
          .whereType<LayerNode>()
          .where((l) => l.layerName == source.layerName)
          .firstOrNull;
      if (layer == null) {
        discarded.add('$name（${gpkg.name} に ${source.layerName} がありません）');
        continue;
      }

      final id = _text(maplayer, 'id');
      final views = touched.putIfAbsent(layer, () => []);
      views.add(
        ViewNode(
          name: _uniqueName(name, views),
          parent: layer,
          filter: source.subset,
          style: readStyle(maplayer),
          visible: id == null ? true : (checkedById[id] ?? true),
        ),
      );
    }

    // まとめて差し替える。途中で失敗しても中途半端に混ざらないように
    for (final entry in touched.entries) {
      final layer = entry.key;
      layer.views
        ..clear()
        ..addAll(entry.value);
      await layer.persistViews();
      // 可視性は View 定義とは別の場所に持つ。
      // 既定 View 1枚だけのレイヤは View ではなく**レイヤの可視性**で表す
      // （暗黙の既定 View は `.kmeta.json` に書かれず、可視性も読まれないため）
      final views = entry.value;
      if (views.length == 1 && views.first.isDefaultView) {
        layer.visible = views.first.visible;
        await layer.persistVisibility();
      } else {
        for (final v in views) {
          await v.persistVisibility();
        }
      }
      viewsByLayer[layer.layerKey] = [for (final v in views) v.name];
    }

    AppLogger.debug(
      '[QgsImporter] View ${viewsByLayer.values.fold(0, (s, l) => s + l.length)} 個を'
      '${viewsByLayer.length} レイヤに取り込み（除外 ${discarded.length} 件）',
    );
    return QgsImportResult(viewsByLayer: viewsByLayer, discarded: discarded);
  }

  // =============================================
  // 部品
  // =============================================

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

  String? _text(XmlElement parent, String tag) {
    final e = parent.findElements(tag).firstOrNull;
    return e?.innerText.trim().isEmpty ?? true ? null : e!.innerText.trim();
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

  bool _isInsideRoot(String? rootPath, String absPath) {
    if (rootPath == null) return false;
    final rel = p.relative(absPath, from: p.normalize(rootPath));
    return !rel.startsWith('..') && !p.isAbsolute(rel);
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

  /// `renderer-v2` から見た目を拾う。読めない形なら null（＝スタイル無し）。
  ///
  /// > [!NOTE] 拾うのは単一シンボルの1レイヤ目だけ
  /// > QGISのシンボルは重ね合わせも段階分けもできるが、こかげマップ 側に受け皿が無い。
  /// > 分類分け（categorizedSymbol 等）は最初のシンボルの色を採るだけ。
  /// > **完全再現は狙わない。** 狙うと「開けるファイルを選り好みする」方向に行く。
  @visibleForTesting
  KMetaLayerStyle? readStyle(XmlElement maplayer) {
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
