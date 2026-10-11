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
/// 毎木調査の置き場所（gpkg の2レイヤ）と読み書き
///
/// - `tally_plots`（面）: 標準地。円形は中心と半径も列に持つ（面は 64 角形で近似、面積は πr² で出す）
/// - `tally_trees`（点）: 1本1行。`plot_id` で標準地に結ぶ
/// 列の意味は docs/features/tree-tally.md
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../i18n/strings.g.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/qgis_form.dart';
import '../../utils/app_logger.dart';
import '../../utils/geodesic.dart';
import '../kmeta_service.dart';
import 'tree_tally_stats.dart';

class TreeTallySchema {
  TreeTallySchema._();

  static const plotsLayer = 'tally_plots';
  static const treesLayer = 'tally_trees';

  static const plotColumns = {
    'plot_id': 'TEXT',
    'shape': 'TEXT', // circle / polygon
    'radius_m': 'REAL',
    'area_m2': 'REAL', // 作ったときの水平面積（集計は形から出し直す）
    'center_lon': 'REAL',
    'center_lat': 'REAL',
    'note': 'TEXT',
    'created_at': 'TEXT',
  };

  static const treeColumns = {
    'plot_id': 'TEXT',
    'tree_no': 'INTEGER',
    'species': 'TEXT',
    'dbh_cm': 'REAL',
    'height_m': 'REAL',
    'height_src': 'TEXT', // trupulse / manual
    'pos_src': 'TEXT', // gnss / trupulse
    'note': 'TEXT',
    'measured_at': 'TEXT',
  };

  /// 樹種の初期の選択肢（使った樹種は後ろに足していく）
  static const defaultSpecies = ['スギ', 'ヒノキ', 'アカマツ', 'カラマツ', 'モミ', 'ツガ', '広葉樹'];
}

/// 1つの gpkg の毎木調査レイヤ
class TreeTallyLayers {
  final PolygonLayerNode plots;
  final PointLayerNode trees;
  const TreeTallyLayers(this.plots, this.trees);

  /// [gpkg] の中の2レイヤを返す。無ければ作り、足りない列を足す。属性フォーム（別名・樹種の選択肢）も付ける
  static Future<TreeTallyLayers?> ensure(GeoPackageNode gpkg) async {
    LayerNode? find(String name) =>
        gpkg.children.whereType<LayerNode>().where((l) => l.layerName == name).firstOrNull;
    final plots = find(TreeTallySchema.plotsLayer) as PolygonLayerNode? ??
        await PolygonLayerNode.createIn(gpkg, TreeTallySchema.plotsLayer);
    final trees = find(TreeTallySchema.treesLayer) as PointLayerNode? ??
        await PointLayerNode.createIn(gpkg, TreeTallySchema.treesLayer);
    if (plots == null || trees == null) return null;
    await gpkg.geoPackageFile.addAttributeColumns(plots.layerName, TreeTallySchema.plotColumns);
    await gpkg.geoPackageFile.addAttributeColumns(trees.layerName, TreeTallySchema.treeColumns);
    plots.clearColumnNamesCache();
    trees.clearColumnNamesCache();
    await _attachForms(plots, trees);
    return TreeTallyLayers(plots, trees);
  }

  /// アプリの編集パネル用の属性フォーム（別名と、樹種は「一覧から選ぶ・新しい値も打てる」）
  static Future<void> _attachForms(PolygonLayerNode plots, PointLayerNode trees) async {
    final folder = trees.folderNode;
    final folderPath = folder?.getAbsoluteFilePath();
    if (folder == null || folderPath == null) return;
    try {
      if (await trees.getQgisForm() == null) {
        final a = t.treeTally.column;
        await KMetaService.instance.setLayerForm(folderPath, trees.layerKey, QgisForm(fields: {
          'plot_id': QgisFieldForm(name: 'plot_id', alias: a.plotId, widgetType: 'UniqueValues', config: const {'Editable': true}),
          'tree_no': QgisFieldForm(name: 'tree_no', alias: a.treeNo),
          'species': QgisFieldForm(name: 'species', alias: a.species, widgetType: 'UniqueValues', config: const {'Editable': true}),
          'dbh_cm': QgisFieldForm(name: 'dbh_cm', alias: a.dbh),
          'height_m': QgisFieldForm(name: 'height_m', alias: a.height),
          'note': QgisFieldForm(name: 'note', alias: a.note),
        }));
      }
      if (await plots.getQgisForm() == null) {
        final a = t.treeTally.column;
        await KMetaService.instance.setLayerForm(folderPath, plots.layerKey, QgisForm(fields: {
          'plot_id': QgisFieldForm(name: 'plot_id', alias: a.plotId),
          'radius_m': QgisFieldForm(name: 'radius_m', alias: a.radius),
          'note': QgisFieldForm(name: 'note', alias: a.note),
        }));
      }
      folder.invalidateMetaCache();
    } on Object catch (e) {
      AppLogger.debug('[TreeTally] 属性フォームを付けられない: $e');
    }
  }

  // ── 標準地 ───────────────────────────────

  /// 標準地の一覧（作った順）
  Future<List<TallyPlot>> loadPlots() async {
    // 属性の書き込みは後でまとめて保存される（FeatureNode.setAttributeValues）。読む前に書き出す
    await plots.geoPackageFile.flushChanges();
    await plots.updateChildren();
    return [
      for (final f in plots.features.whereType<PolygonFeatureNode>()) TallyPlot.fromFeature(f),
    ];
  }

  /// 次の標準地の番号（P1, P2, ...）
  static String nextPlotId(Iterable<String> existing) {
    var n = 0;
    for (final id in existing) {
      final m = RegExp(r'^P(\d+)$').firstMatch(id);
      if (m != null) n = math.max(n, int.parse(m.group(1)!));
    }
    return 'P${n + 1}';
  }

  /// 円形の標準地を作る
  Future<TallyPlot?> createCirclePlot(String plotId, LatLng center, double radiusM) async {
    const segments = 64;
    final ring = [
      for (var i = 0; i < segments; i++) const Distance().offset(center, radiusM, 360.0 * i / segments),
    ];
    ring.add(ring.first);
    final f = await PolygonFeatureNode.createIn(plots, [ring], '', '');
    if (f == null) return null;
    await f.setAttributeValues({
      'plot_id': plotId,
      'shape': 'circle',
      'radius_m': radiusM,
      'area_m2': circlePlotAreaM2(radiusM),
      'center_lon': center.longitude,
      'center_lat': center.latitude,
      'created_at': DateTime.now().toIso8601String(),
    });
    return TallyPlot.fromFeature(f);
  }

  // ── 立木 ─────────────────────────────────

  Future<List<Map<String, dynamic>>> _treeRows() async {
    await trees.geoPackageFile.flushChanges(); // loadPlots と同じ
    return trees.geoPackageFile.getAllFeatureAttributes(
      trees.layerName,
      columns: const ['plot_id', 'tree_no', 'species', 'dbh_cm', 'height_m'],
    );
  }

  /// 標準地の次の立木番号
  Future<int> nextTreeNo(String plotId) async {
    var n = 0;
    for (final r in await _treeRows()) {
      if ('${r['plot_id']}' == plotId) n = math.max(n, (r['tree_no'] as num?)?.toInt() ?? 0);
    }
    return n + 1;
  }

  /// 使ったことのある樹種（多い順）
  Future<List<String>> usedSpecies() async {
    final counts = <String, int>{};
    for (final r in await _treeRows()) {
      final s = '${r['species'] ?? ''}'.trim();
      if (s.isNotEmpty) counts[s] = (counts[s] ?? 0) + 1;
    }
    return counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  /// 器械点（標準地の中心）から TruPulse で測った位置に1本記録する
  Future<PointFeatureNode?> addTreeAt(LatLng position, Map<String, dynamic> attributes) async {
    final f = await PointFeatureNode.createIn(trees, position, '', '');
    if (f == null) return null;
    await f.setAttributeValues(attributes);
    return f;
  }

  /// 標準地ごとの集計（標準地のない立木の plot_id は面積 0 で並べる）
  Future<List<PlotTally>> summarize() async {
    final plotList = await loadPlots();
    final byPlot = <String, List<TallyTree>>{};
    for (final r in await _treeRows()) {
      byPlot.putIfAbsent('${r['plot_id'] ?? ''}', () => []).add(TallyTree(
            species: '${r['species'] ?? ''}'.trim(),
            dbhCm: (r['dbh_cm'] as num?)?.toDouble(),
            heightM: (r['height_m'] as num?)?.toDouble(),
          ));
    }
    final result = <PlotTally>[
      for (final p in plotList) PlotTally.of(p.plotId, byPlot.remove(p.plotId) ?? const [], p.areaM2),
    ];
    byPlot.forEach((id, trees) => result.add(PlotTally.of(id, trees, 0)));
    return result;
  }
}

/// 標準地1つ
class TallyPlot {
  final String plotId;
  final double areaM2;
  final double? radiusM;

  /// 器械点（円形は中心、多角形は重心）
  final LatLng center;

  const TallyPlot({required this.plotId, required this.areaM2, required this.center, this.radiusM});

  /// 円形（radius_m あり）は πr²、ほかは楕円体の上の面積
  static TallyPlot fromFeature(PolygonFeatureNode f) {
    final p = f.turfFeature.properties ?? const {};
    final radius = (p['radius_m'] as num?)?.toDouble();
    final lon = (p['center_lon'] as num?)?.toDouble();
    final lat = (p['center_lat'] as num?)?.toDouble();
    final id = '${p['plot_id'] ?? ''}'.trim();
    return TallyPlot(
      plotId: id.isEmpty ? '#${f.rowId}' : id,
      areaM2: radius != null && radius > 0 ? circlePlotAreaM2(radius) : (Geodesic.areaOf(f.turfFeature.geometry) ?? 0),
      radiusM: radius,
      center: lon != null && lat != null ? LatLng(lat, lon) : f.centroid,
    );
  }
}
