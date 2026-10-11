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
/// - `tally_plots`（面）: 標準地。円形は中心と半径も列に持つ（面は πr² と同じ面積の 64 角形。集計の面積は面の形から出す）
/// - `tally_trees`（点）: 1本1行。`plot_id` で標準地に結ぶ
/// 列の意味は docs/features/tree-tally.md
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:turf/turf.dart' as turf;

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

/// 毎木調査のレイヤ名がほかの用途の表とぶつかっている（形が違う・地物の表でない・列を足せない）
class TreeTallyLayerConflict implements Exception {
  final String layerName;

  /// 求める形（true: 面、false: 点）
  final bool expectPolygon;

  /// 形は合うが、足りない列を足せなかった
  final bool columnsMissing;

  const TreeTallyLayerConflict(this.layerName, {required this.expectPolygon, this.columnsMissing = false});

  /// 通知に出す文
  String get message => columnsMissing
      ? t.treeTally.conflictColumns(layer: layerName)
      : expectPolygon
          ? t.treeTally.conflictNotPolygon(layer: layerName)
          : t.treeTally.conflictNotPoint(layer: layerName);

  @override
  String toString() => 'TreeTallyLayerConflict($layerName)';
}

/// 1つの gpkg の毎木調査レイヤ
class TreeTallyLayers {
  final PolygonLayerNode plots;
  final PointLayerNode trees;
  const TreeTallyLayers(this.plots, this.trees);

  /// [gpkg] の中の2レイヤを返す。無ければ作り、足りない列を足す。属性フォーム（別名・樹種の選択肢）も付ける。
  /// 同じ名前で形の違うレイヤ（面でない `tally_plots`・点でない `tally_trees`）や地物でない表があれば、
  /// 何も作らず・変えずに [TreeTallyLayerConflict] を投げる（利用者の表を勝手に直さない）
  static Future<TreeTallyLayers?> ensure(GeoPackageNode gpkg) async {
    final layers = gpkg.children.whereType<LayerNode>();
    LayerNode? find(String name) => layers.where((l) => l.layerName == name).firstOrNull;
    final foundPlots = find(TreeTallySchema.plotsLayer);
    final foundTrees = find(TreeTallySchema.treesLayer);
    if (foundPlots != null && foundPlots is! PolygonLayerNode) {
      throw const TreeTallyLayerConflict(TreeTallySchema.plotsLayer, expectPolygon: true);
    }
    if (foundTrees != null && foundTrees is! PointLayerNode) {
      throw const TreeTallyLayerConflict(TreeTallySchema.treesLayer, expectPolygon: false);
    }
    // レイヤとして見えていない同名の表（属性だけの表・ラスタなど）。作ると「tally_plots_2」ができてしまう
    final tables = await _tableNames(gpkg);
    if (foundPlots == null && tables.contains(TreeTallySchema.plotsLayer.toLowerCase())) {
      throw const TreeTallyLayerConflict(TreeTallySchema.plotsLayer, expectPolygon: true);
    }
    if (foundTrees == null && tables.contains(TreeTallySchema.treesLayer.toLowerCase())) {
      throw const TreeTallyLayerConflict(TreeTallySchema.treesLayer, expectPolygon: false);
    }
    final plots = foundPlots as PolygonLayerNode? ?? await PolygonLayerNode.createIn(gpkg, TreeTallySchema.plotsLayer);
    final trees = foundTrees as PointLayerNode? ?? await PointLayerNode.createIn(gpkg, TreeTallySchema.treesLayer);
    if (plots == null || trees == null) return null;
    // 形の合うレイヤに足りない列（前の版で作った表など）は足す。足せなければ（読み取り専用など）開かずに知らせる
    for (final (layer, columns, polygon) in [
      (plots, TreeTallySchema.plotColumns, true),
      (trees, TreeTallySchema.treeColumns, false),
    ]) {
      try {
        await gpkg.geoPackageFile.addAttributeColumns(layer.layerName, columns);
      } on Object catch (e) {
        AppLogger.debug('[TreeTally] ${layer.layerName} に列を足せない: $e');
        throw TreeTallyLayerConflict(layer.layerName, expectPolygon: polygon, columnsMissing: true);
      }
    }
    plots.clearColumnNamesCache();
    trees.clearColumnNamesCache();
    await _attachForms(plots, trees);
    return TreeTallyLayers(plots, trees);
  }

  /// gpkg にある表の名前（小文字。SQLite の表名は大小を区別しない）
  static Future<Set<String>> _tableNames(GeoPackageNode gpkg) async {
    try {
      final db = await gpkg.geoPackageFile.getDatabase();
      final rows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')");
      return {for (final r in rows) '${r['name']}'.toLowerCase()};
    } on Object catch (e) {
      AppLogger.debug('[TreeTally] 表の一覧を読めない: $e');
      return const {};
    }
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

  /// 円形の標準地の面の角の数
  static const circleSegments = 64;

  /// 円形の標準地を作る。面は半径 [radiusM] の円と同じ面積の正 64 角形
  /// （内接にすると πr² より約 0.16% 小さく、集計が作ったときの面積とずれる）
  Future<TallyPlot?> createCirclePlot(String plotId, LatLng center, double radiusM) async {
    const n = circleSegments;
    // 正 n 角形の面積 n/2·R²·sin(2π/n) を πr² にそろえる外接半径 R
    final vertexRadius = radiusM * math.sqrt(2 * math.pi / (n * math.sin(2 * math.pi / n)));
    final ring = [
      for (var i = 0; i < n; i++) const Distance().offset(center, vertexRadius, 360.0 * i / n),
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

  /// 立木の plot_id。標準地の側（[TallyPlot.fromFeature]）と同じく前後の空白を落とす
  /// （属性の編集で打ち直した「P1 」が標準地から外れ、面積 0 の別の行に数えられていた）
  static String _plotIdOf(Map<String, dynamic> row) => '${row['plot_id'] ?? ''}'.trim();

  /// 標準地の次の立木番号
  Future<int> nextTreeNo(String plotId) async {
    var n = 0;
    for (final r in await _treeRows()) {
      if (_plotIdOf(r) == plotId) n = math.max(n, (r['tree_no'] as num?)?.toInt() ?? 0);
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
  /// [volume] は1本の幹材積（PlotSummary.of）。省くと材積は出さない
  Future<List<PlotTally>> summarize({double? Function(TallyTree)? volume}) async {
    final plotList = await loadPlots();
    final byPlot = <String, List<TallyTree>>{};
    for (final r in await _treeRows()) {
      byPlot.putIfAbsent(_plotIdOf(r), () => []).add(TallyTree(
            species: '${r['species'] ?? ''}'.trim(),
            dbhCm: (r['dbh_cm'] as num?)?.toDouble(),
            heightM: (r['height_m'] as num?)?.toDouble(),
          ));
    }
    final result = <PlotTally>[
      for (final p in plotList) PlotTally.of(p.plotId, byPlot.remove(p.plotId) ?? const [], p.areaM2, volume: volume),
    ];
    byPlot.forEach((id, trees) => result.add(PlotTally.of(id, trees, 0, volume: volume)));
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

  /// 面積は面の形の楕円体の上の面積（QGIS の楕円体での `$area` と同じ。円形も同じ）。
  /// `radius_m`・`center_*` の列は作ったときの値のまま（面を動かしても直さない。開いたときにも書き直さない）。
  /// 中心は列の値を器械点に使う
  static TallyPlot fromFeature(PolygonFeatureNode f) {
    final p = f.turfFeature.properties ?? const {};
    final radius = (p['radius_m'] as num?)?.toDouble();
    final lon = (p['center_lon'] as num?)?.toDouble();
    final lat = (p['center_lat'] as num?)?.toDouble();
    final id = '${p['plot_id'] ?? ''}'.trim();
    return TallyPlot(
      plotId: id.isEmpty ? '#${f.rowId}' : id,
      areaM2: areaOf(f.turfFeature.geometry, radius),
      radiusM: radius,
      center: lon != null && lat != null ? LatLng(lat, lon) : f.centroid,
    );
  }

  /// 標準地の面積 [m²]: 面があればその楕円体の上の面積、面が無い（空の）ときだけ半径から πr²
  static double areaOf(turf.GeometryObject? geometry, double? radiusM) {
    final area = Geodesic.areaOf(geometry);
    if (area != null && area > 0) return area;
    return radiusM != null && radiusM > 0 ? circlePlotAreaM2(radiusM) : 0;
  }
}
