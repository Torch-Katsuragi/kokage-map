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
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/view_node.dart';
import '../../utils/app_logger.dart';
import 'qgs_raster_source.dart';
import 'qgs_relation_importer.dart';
import 'qgs_source_resolver.dart';
import 'qgs_style_reader.dart';
import 'qgs_tree_reader.dart';
import 'qgs_xml.dart';

export 'qgs_source_resolver.dart' show QgsDataSource;

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

  /// XYZ タイル・WMS のレイヤ（一覧に無い URL は利用者の地図の定義つき）。背景地図は端末の設定なので、
  /// ここでは読むだけで足さない（`QgsBaseMapImport` が足す）
  final List<QgsBaseMap> baseMaps;

  /// 可視性を読み戻したオーバーレイ画像（GeoTIFF）の数
  final int overlayCount;

  int get importedViewCount =>
      viewsByLayer.values.fold(0, (sum, list) => sum + list.length);

  bool get isEmpty => viewsByLayer.isEmpty;
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
    final sources = QgsSourceResolver.fromRoot(qgsDir, root);
    final tree = QgsTreeVisibility.read(doc);
    // レイヤツリーの並び（上から）。こかげマップの一覧の並び（= 描く順）に写す
    final placement = QgsTreePlacement.fromDocument(doc);
    // 形が合ったレイヤの、グループ側の可視性（レイヤ・gpkg・dir）
    final layerGroupChecked = <LayerNode, bool>{};
    final containerChecked = <LayerTreeNode, bool>{};

    // 取り込み対象になったレイヤ。ここに入ったものだけ View を差し替える
    final touched = <LayerNode, List<ViewNode>>{};
    // 属性フォームの設定を読む maplayer（既定 View のもの、無ければ最初のもの。QGIS では maplayer ごとに持つ）
    final formSource = <LayerNode, XmlElement>{};

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
      placement.place(layer, id);
      final shaped = id != null && tree.readGroups(id, layer, gpkg, root, layerGroupChecked, containerChecked);
      final views = touched.putIfAbsent(layer, () => []);
      // レイヤと同じ名前でフィルタの無い QGIS レイヤは既定 View（こかげマップは既定 View をレイヤ名で書く。
      // QGIS でふつうに足したレイヤもこの形）。旧版が書いた「既定」もそのまま既定 View
      final isDefault = name == layer.layerName &&
          (source.subset == null || source.subset!.isEmpty) &&
          !views.any((v) => v.name == kDefaultViewName);
      if (isDefault || !formSource.containsKey(layer)) formSource[layer] = maplayer;
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

    // 属性フォームの設定（`.qgs` の側は QGIS の持ち物なので、読んで写すだけ）
    await QgsRelationImporter.applyForms(formSource, projectLayers, sources, discarded);

    // 表の結合（`<vectorjoins>`。結合先は表のノードに読み替える）
    await QgsRelationImporter.applyJoins(formSource, projectLayers, sources, discarded);

    // gpkg と dir のグループの可視性（変わったものだけ書く）
    await applyQgsContainerVisibility(containerChecked, accepts);

    // オーバーレイ画像（GeoTIFF）の可視性。ファイルは dir にあるものが正で、`.qgs` からは表示だけ取る
    final overlayCount = await applyQgsOverlayVisibility(sources.overlays, tree, qgsDir, accepts);

    // 並び（レイヤツリーの上から）。オーバーレイは持ち主を問わず位置だけ取る（持ち主の判定は [applyQgsTreeOrder]）
    for (final (:node, :id) in sources.overlays) {
      placement.place(node, id);
    }
    await applyQgsTreeOrder(root, placement.placed, accepts);

    // XYZ タイル（背景地図）。端末の設定なのでここでは読むだけ
    final baseMaps = [
      for (final (:providerId, :name, :id, :opacity, :custom) in sources.baseMaps)
        QgsBaseMap(
          providerId: providerId,
          layerName: name,
          visible: tree.checked[id] ?? true,
          opacity: opacity,
          custom: custom,
        ),
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

  /// 描き分けの印（[KMetaLayerStyle.qgisRenderer]）だけを持ち、中身（[KMetaLayerStyle.qgisRendererDef]）が
  /// 無いスタイルに、`.qgs` のレンダラの中身を足す。足した数を返す。
  Future<int> backfillRendererDefs(String qgsPath, FolderNode root) async {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(await readQgsText(qgsPath));
    } on Object catch (e) {
      AppLogger.debug('[QgsImporter] 描き分けの補完: 読めない $e');
      return 0;
    }
    final sources = QgsSourceResolver.fromRoot(p.dirname(p.normalize(qgsPath)), root, includeTables: false);
    return QgsStyleReader.backfillRendererDefs(doc, qgsPath, sources);
  }

  /// 属性フォームの設定を持たないレイヤに、`.qgs` の設定を足す。足した数を返す。
  Future<int> backfillForms(String qgsPath, FolderNode root) async {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(await readQgsText(qgsPath));
    } on Object catch (e) {
      AppLogger.debug('[QgsImporter] 属性フォームの補完: 読めない $e');
      return 0;
    }
    final sources = QgsSourceResolver.fromRoot(p.dirname(p.normalize(qgsPath)), root, includeTables: false);
    return QgsRelationImporter.backfillForms(doc, qgsPath, sources);
  }

  /// [layer] の View を [views] に置き換えて保存する。可視性とスタイルも書く。
  /// [groupChecked] はこかげマップが書いた形のときの、レイヤグループの可視性
  Future<void> _replaceViews(LayerNode layer, List<ViewNode> views, bool? groupChecked) async {
    // 既定 View に読んだスタイルを控える（persistViews がレイヤのスタイルへ移し、View からは外す）
    final importedDefault = views.where((v) => v.isDefaultView).firstOrNull?.style;
    layer.views
      ..clear()
      ..addAll(views);
    await layer.persistViews();
    // persistViews は前のスタイルに重ねるだけなので、QGIS で単一シンボルに戻した描き分けの印が残っていた。
    // QGIS の今の状態に合わせ直す（2026-10-12）
    if (importedDefault != null) await QgsStyleReader.applyImportedLayerStyle(layer, importedDefault);
    // 可視性は View 定義とは別の場所に持つ。
    // 既定 View 1枚だけのレイヤは View ではなく**レイヤの可視性**で表す
    // （暗黙の既定 View は フォルダ設定（`.qgs`） に書かれず、可視性も読まれないため）
    if (views.length == 1 && views.first.isDefaultView) {
      layer.visible = views.first.visible && (groupChecked ?? true);
      await layer.persistVisibility();
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

  /// 同一レイヤ内で View名が衝突しないようにする（QGISは同名レイヤを許す）
  String _uniqueName(String base, List<ViewNode> existing) {
    if (!existing.any((v) => v.name == base)) return base;
    var n = 2;
    while (existing.any((v) => v.name == '$base $n')) {
      n++;
    }
    return '$base $n';
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

  /// シンボルとラベルをまとめて読む（どちらも無ければ null）
  KMetaLayerStyle? readStyleWithLabel(XmlElement maplayer) => QgsStyleReader.readStyleWithLabel(maplayer);

  /// `<labeling type="simple">` のフィールド（式）・サイズ・色と `labelsEnabled`。
  KMetaLayerStyle? readLabel(XmlElement maplayer) => QgsStyleReader.readLabel(maplayer);

  /// `renderer-v2` から見た目を拾う。読めない形なら null（＝スタイル無し）。
  KMetaLayerStyle? readStyle(XmlElement maplayer) => QgsStyleReader.readStyle(maplayer);
}
