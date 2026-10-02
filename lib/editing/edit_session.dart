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
// 地物の編集（情報パネルのまま、地図の上で形を直す）
//
// 編集は手元の写し（[EditState.geom]・[EditState.attrs]）に対して行い、「保存」で初めて書き込む。
// 「取消」なら何も書かない。形の変更は 1 手ごとに元に戻す・やり直すができる。
// 地図は真上（2D）に固定し、左の道具の列は編集専用に替わる（地物の種類で出す道具が違う）。
// 松本 2026-10-01「情報パネルの枠で編集できるように」「2D に移行」「ツールバーも編集専用に」
//
// 頂点ごとに「元の何番目の頂点か」（[EditState.ids]。足した頂点は null）を持ち歩く。
// GPS 測量の線は頂点ごとの記録（sub_table）を持つので、保存のときにこれで並べ直す。

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models/nodes/feature_node.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../tools/map_tool.dart';
import '../tutorial/tutorial.dart';
import '../utils/app_logger.dart';
import '../utils/feature_calc_utils.dart';
import '../widgets/feature_editor/shared/sub_table_helper.dart';
import 'edit_tool.dart';

enum EditKind { point, line, polygon }

/// 編集の道具
enum EditMode {
  /// 頂点を動かす・辺の中点で足す・押して選ぶ（選んだ頂点は消せる）
  vertex,

  /// 全体を平行移動（点はその点を動かす）
  move,

  /// 重心のまわりに回す
  rotate,

  /// 重心から大きく・小さく
  scale,

  /// 線の端から続けて描く
  extend,

  /// 頂点を間引く（パネルのつまみで許す幅を決める）
  simplify,

  /// 線の両端を切り落とす（パネルのつまみで残す範囲を決める）
  trim,
}

/// 地物の種類ごとに使える道具
List<EditMode> modesFor(EditKind k) => switch (k) {
      EditKind.point => const [EditMode.move],
      EditKind.line => const [
          EditMode.vertex,
          EditMode.move,
          EditMode.rotate,
          EditMode.scale,
          EditMode.extend,
          EditMode.simplify,
          EditMode.trim,
        ],
      EditKind.polygon => const [EditMode.vertex, EditMode.move, EditMode.rotate, EditMode.scale, EditMode.simplify],
    };

/// 形。点は [[p]]、線は [頂点…]、面は [外周, 穴…]（どれも閉じない。最後に最初の点を重ねない）
typedef Shape = List<List<LatLng>>;

/// 頂点ごとの元の番号（形と同じ並び。足した頂点は null）
typedef Ids = List<List<int?>>;

/// 形と番号の組（元に戻す・やり直すの 1 手分）
typedef Snap = (Shape, Ids);

class EditState {
  const EditState({
    required this.feature,
    required this.kind,
    required this.geom,
    required this.ids,
    required this.original,
    required this.mode,
    this.undo = const [],
    this.redo = const [],
    this.selected,
    this.columns = const [],
    this.attrs = const {},
    this.originalAttrs = const {},
    this.saving = false,
    this.tolerance = 0,
    this.trimRange,
    this.attrsTab = false,
  });

  /// パネルで属性を出しているか（このときパネルは上までせり上がる）
  final bool attrsTab;

  final FeatureNode feature;
  final EditKind kind;
  final Shape geom;
  final Ids ids;
  final Shape original;
  final EditMode mode;
  final List<Snap> undo;
  final List<Snap> redo;

  /// 選んだ頂点（リング, 番号）
  final (int, int)? selected;

  /// 書き換えられる属性の列（fid・geom・_ で始まるものは除く）
  final List<String> columns;
  final Map<String, Object?> attrs;
  final Map<String, Object?> originalAttrs;
  final bool saving;

  /// 間引くときの許す幅（m）。つまみの位置
  final double tolerance;

  /// 切り落とすときに残す範囲（元の頂点の番号, 両端を含む）。つまみの位置
  final (int, int)? trimRange;

  Snap get snap => (geom, ids);
  bool get shapeChanged => !_sameShape(geom, original);
  bool get attrsChanged => columns.any((c) => '${attrs[c] ?? ''}' != '${originalAttrs[c] ?? ''}');
  bool get dirty => shapeChanged || attrsChanged;

  EditState copyWith({
    Shape? geom,
    Ids? ids,
    EditMode? mode,
    List<Snap>? undo,
    List<Snap>? redo,
    (int, int)? Function()? selected,
    List<String>? columns,
    Map<String, Object?>? attrs,
    Map<String, Object?>? originalAttrs,
    bool? saving,
    double? tolerance,
    (int, int)? Function()? trimRange,
    bool? attrsTab,
  }) =>
      EditState(
        feature: feature,
        kind: kind,
        geom: geom ?? this.geom,
        ids: ids ?? this.ids,
        original: original,
        mode: mode ?? this.mode,
        undo: undo ?? this.undo,
        redo: redo ?? this.redo,
        selected: selected != null ? selected() : this.selected,
        columns: columns ?? this.columns,
        attrs: attrs ?? this.attrs,
        originalAttrs: originalAttrs ?? this.originalAttrs,
        saving: saving ?? this.saving,
        tolerance: tolerance ?? this.tolerance,
        trimRange: trimRange != null ? trimRange() : this.trimRange,
        attrsTab: attrsTab ?? this.attrsTab,
      );
}

bool _sameShape(Shape a, Shape b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].length != b[i].length) return false;
    for (var j = 0; j < a[i].length; j++) {
      if (a[i][j] != b[i][j]) return false;
    }
  }
  return true;
}

Shape _copy(Shape s) => [for (final r in s) List<LatLng>.of(r)];
Ids _copyIds(Ids s) => [for (final r in s) List<int?>.of(r)];

/// 閉じたリング（最後が最初と同じ）を開く
List<LatLng> _open(List<LatLng> ring) =>
    ring.length > 1 && ring.first == ring.last ? ring.sublist(0, ring.length - 1) : List.of(ring);

final featureEditorProvider = NotifierProvider<FeatureEditor, EditState?>(FeatureEditor.new);

class FeatureEditor extends Notifier<EditState?> {
  /// 編集の前に持っていた道具（終わったら戻す）
  MapTool? _toolBefore;

  /// 間引く・切り落とすの元（その道具に入ったときの形。つまみはいつもこれから計算する）
  Snap? _toolBase;

  /// つまみを動かし始めたときの形（離したらこれを 1 手の前として積む）
  Snap? _sliderStart;

  @override
  EditState? build() => null;

  bool get active => state != null;

  /// 編集を始める。地図は 2D に固定され、左の列は編集の道具に替わる
  Future<void> start(FeatureNode f) async {
    final (kind, shape) = switch (f) {
      final PointFeatureNode p => (EditKind.point, <List<LatLng>>[[p.point]]),
      final LineFeatureNode l => (EditKind.line, <List<LatLng>>[List.of(l.line)]),
      final PolygonFeatureNode g => (EditKind.polygon, [for (final r in g.polygon) _open(r)]),
      _ => (null, <List<LatLng>>[]),
    };
    if (kind == null || shape.isEmpty || shape.first.isEmpty) return;
    state = EditState(
      feature: f,
      kind: kind,
      geom: _copy(shape),
      ids: [for (final r in shape) [for (var i = 0; i < r.length; i++) i]],
      original: _copy(shape),
      mode: modesFor(kind).first,
    );
    _toolBefore = ref.read(currentToolProvider);
    ref.read(currentToolProvider.notifier).set(ref.read(editToolProvider));
    _tutorial(EditStarted(f.parent));
    await _loadAttributes(f);
  }

  Future<void> _loadAttributes(FeatureNode f) async {
    try {
      final info = await f.geoPackageFile.getAttributeColumnInfo(f.layerName);
      final cols = [
        for (final c in info)
          if (c['name'] is String && _editable(c['name'] as String))
            c['name'] as String,
      ];
      final values = <String, Object?>{for (final c in cols) c: f.turfFeature.properties?[c]};
      final s = state;
      if (s == null || !identical(s.feature, f)) return;
      state = s.copyWith(columns: cols, attrs: Map.of(values), originalAttrs: values);
    } catch (_) {}
  }

  /// 書き換えてよい列（番号・形・内部用は除く。属性テーブルと同じ決まり。
  /// sub_table は頂点ごとの記録なので形と一緒に扱う）
  static bool _editable(String name) {
    final n = name.toLowerCase();
    return !(n == 'id' ||
        n == 'fid' ||
        n == 'geom' ||
        n == 'geometry' ||
        n == 'rmaps_metadata' ||
        n == 'sub_table' ||
        n.startsWith('_'));
  }

  void setMode(EditMode m) {
    final s = state;
    if (s == null) return;
    _toolBase = s.snap;
    final n = s.geom.first.length;
    state = s.copyWith(mode: m, selected: () => null, tolerance: 0, trimRange: () => (0, n - 1));
  }

  void setAttrsTab(bool on) {
    final s = state;
    if (s != null) state = s.copyWith(attrsTab: on);
    if (on) _tutorial(const AttrsTabOpened());
  }

  void _tutorial(TutorialEvent e) => ref.read(tutorialProvider.notifier).report(e);

  void select((int, int)? v) {
    final s = state;
    if (s != null) state = s.copyWith(selected: () => v);
  }

  /// ドラッグ中の途中経過（元に戻す履歴には積まない）。頂点の数が変わらないときは [ids] を省く
  void preview(Shape g, [Ids? ids]) {
    final s = state;
    if (s != null) state = s.copyWith(geom: g, ids: ids);
  }

  /// 頂点を足した形を途中経過として出す（中点を掴んでそのまま動かすとき）
  void previewInsert(int ring, int at, LatLng p) {
    final s = state;
    if (s == null) return;
    preview(_copy(s.geom)..[ring].insert(at, p), _copyIds(s.ids)..[ring].insert(at, null));
  }

  /// 1 手を確定する。[before] はその手の前
  void commit(Snap before) {
    final s = state;
    if (s == null || (_sameShape(before.$1, s.geom) && before.$2.length == s.ids.length)) return;
    state = s.copyWith(undo: [...s.undo, before], redo: const []);
    _tutorial(const ShapeEdited());
  }

  /// その場で 1 手（途中経過なし）
  void apply(Shape g, [Ids? ids]) {
    final s = state;
    if (s == null) return;
    final before = s.snap;
    state = s.copyWith(geom: g, ids: ids);
    commit(before);
  }

  void undo() {
    final s = state;
    if (s == null || s.undo.isEmpty) return;
    final (g, ids) = s.undo.last;
    state = s.copyWith(geom: g, ids: ids, undo: s.undo.sublist(0, s.undo.length - 1), redo: [...s.redo, s.snap],
        selected: () => null);
    _rebaseTool();
    _tutorial(const EditUndone());
  }

  void redo() {
    final s = state;
    if (s == null || s.redo.isEmpty) return;
    final (g, ids) = s.redo.last;
    state = s.copyWith(geom: g, ids: ids, redo: s.redo.sublist(0, s.redo.length - 1), undo: [...s.undo, s.snap],
        selected: () => null);
    _rebaseTool();
  }

  /// 元に戻したあとは、間引く・切り落とすのつまみを今の形から始め直す
  void _rebaseTool() {
    final s = state;
    if (s == null) return;
    _toolBase = s.snap;
    state = s.copyWith(tolerance: 0, trimRange: () => (0, s.geom.first.length - 1));
  }

  /// 頂点の最少数（これより減らせない）
  static int minVertices(EditKind k) => switch (k) { EditKind.point => 1, EditKind.line => 2, EditKind.polygon => 3 };

  bool get canDeleteSelected {
    final s = state;
    final v = s?.selected;
    if (s == null || v == null) return false;
    return s.geom[v.$1].length > minVertices(s.kind);
  }

  void deleteSelected() {
    final s = state;
    final v = s?.selected;
    if (s == null || v == null || !canDeleteSelected) return;
    apply(_copy(s.geom)..[v.$1].removeAt(v.$2), _copyIds(s.ids)..[v.$1].removeAt(v.$2));
    select(null);
  }

  /// 辺の途中に頂点を足す（[after] の次に入る）
  void insertVertex(int ring, int after, LatLng p) {
    final s = state;
    if (s == null) return;
    apply(_copy(s.geom)..[ring].insert(after + 1, p), _copyIds(s.ids)..[ring].insert(after + 1, null));
  }

  /// 線の端に点を足す（始点が選ばれていれば始点の前、それ以外は終点の後）
  void extendLine(LatLng p) {
    final s = state;
    if (s == null || s.kind != EditKind.line) return;
    final atStart = s.selected == (0, 0);
    final g = _copy(s.geom);
    final ids = _copyIds(s.ids);
    if (atStart) {
      g[0].insert(0, p);
      ids[0].insert(0, null);
    } else {
      g[0].add(p);
      ids[0].add(null);
    }
    apply(g, ids);
    select(atStart ? (0, 0) : (0, g[0].length - 1));
  }

  // ── つまみの道具（間引く・切り落とす） ──

  void sliderStart() => _sliderStart = state?.snap;

  void sliderEnd() {
    final before = _sliderStart;
    _sliderStart = null;
    if (before != null) commit(before);
  }

  /// 間引く（外周と線だけ。穴はそのまま）
  void setTolerance(double meters) {
    final s = state;
    final base = _toolBase ?? s?.snap;
    if (s == null || base == null) return;
    final (bg, bids) = base;
    final ring = bg.first;
    final closed = s.kind == EditKind.polygon;
    final input = closed ? [...ring, ring.first] : ring;
    var out = meters <= 0 ? input : LineSimplification.simplifyLineDouglasPeucker(input, meters);
    if (closed) out = out.sublist(0, out.length - 1);
    if (out.length < minVertices(s.kind)) return;
    // 残った頂点の元の番号（順に前から探す）
    final keptIds = <int?>[];
    var from = 0;
    for (final p in out) {
      var i = from;
      while (i < ring.length && ring[i] != p) {
        i++;
      }
      if (i == ring.length) i = from; // 見つからないことはないはず
      keptIds.add(bids.first[i]);
      from = i + 1;
    }
    state = s.copyWith(
      geom: [out, ...bg.skip(1).map(List<LatLng>.of)],
      ids: [keptIds, ...bids.skip(1).map(List<int?>.of)],
      tolerance: meters,
    );
  }

  /// 切り落とす（線だけ）。[start]〜[end] を残す（道具に入ったときの頂点の番号）
  void setTrim(int start, int end) {
    final s = state;
    final base = _toolBase ?? s?.snap;
    if (s == null || base == null || s.kind != EditKind.line || end - start < 1) return;
    final (bg, bids) = base;
    state = s.copyWith(
      geom: [bg.first.sublist(start, end + 1)],
      ids: [bids.first.sublist(start, end + 1)],
      trimRange: () => (start, end),
    );
  }

  /// 切り落とすつまみの最大（道具に入ったときの頂点の数 - 1）
  int get trimMax => ((_toolBase ?? state?.snap)?.$1.first.length ?? 1) - 1;

  void setAttr(String col, Object? value) {
    final s = state;
    if (s != null) state = s.copyWith(attrs: {...s.attrs, col: value});
    _tutorial(AttrEdited(col));
  }

  /// 書き込んで終える
  Future<bool> save() async {
    final s = state;
    if (s == null || s.saving) return false;
    state = s.copyWith(saving: true);
    var ok = true;
    final f = s.feature;
    if (s.shapeChanged) {
      ok = switch (f) {
        final PointFeatureNode p => await p.updateLocation(s.geom.first.first),
        final LineFeatureNode l => await l.updateLine(s.geom.first),
        final PolygonFeatureNode g => await g.updatePolygon([for (final r in s.geom) [...r, r.first]]),
        _ => false,
      };
      if (ok && s.kind != EditKind.point) await _syncSubTable(s);
    }
    if (ok) {
      for (final c in s.columns) {
        if ('${s.attrs[c] ?? ''}' != '${s.originalAttrs[c] ?? ''}') {
          await f.setAttributeValue(c, s.attrs[c]);
        }
      }
    }
    if (!ok) {
      state = state?.copyWith(saving: false);
      return false;
    }
    _end();
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
    _tutorial(EditSaved(f.parent));
    return true;
  }

  /// 頂点ごとの記録（sub_table）を新しい頂点の並びに合わせる。
  /// 残った頂点は元の記録を引き継ぎ（位置は新しい場所へ）、足した頂点には空の記録を入れる
  Future<void> _syncSubTable(EditState s) async {
    final json = await SubTableHelper.getSubTableJson(s.feature);
    if (json == null) return;
    final next = remapSubTable(json, s.original.first.length, s.geom.first, s.ids.first, closed: s.kind == EditKind.polygon);
    if (next == null) {
      AppLogger.debug('[FeatureEditor] sub_table の並びが頂点と合わないので触らない');
      return;
    }
    await SubTableHelper.setSubTableJson(s.feature, next);
  }

  /// 何も書かずに終える
  void cancel() {
    if (state == null) return;
    _end();
    _tutorial(const EditCancelled());
  }

  void _end() {
    if (state == null) return;
    state = null;
    _toolBase = null;
    _sliderStart = null;
    final back = _toolBefore;
    _toolBefore = null;
    if (back != null && back.name != 'Edit') {
      ref.read(currentToolProvider.notifier).set(back);
    } else {
      ref.read(currentToolProvider.notifier).set(ref.read(panToolProvider));
    }
  }
}

/// sub_table（GeoJSON FeatureCollection か、旧形式の [見出し, 行…]）を並べ直す。
/// [originalCount] は元の頂点の数（閉じたリングは閉じない数）。記録の数が合わなければ null（触らない）
String? remapSubTable(String json, int originalCount, List<LatLng> points, List<int?> ids, {bool closed = false}) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is Map && decoded['type'] == 'FeatureCollection') {
      final features = (decoded['features'] as List).toList();
      final hasClosing = closed && features.length == originalCount + 1;
      if (features.length != originalCount && !hasClosing) return null;
      Map<String, Object?> entry(int k) {
        final id = ids[k];
        final p = points[k];
        final geometry = {
          'type': 'Point',
          'coordinates': [p.longitude, p.latitude],
        };
        if (id == null) return {'type': 'Feature', 'geometry': geometry, 'properties': <String, Object?>{}};
        final old = Map<String, Object?>.from(features[id] as Map);
        old['geometry'] = geometry;
        return old;
      }

      final out = [for (var k = 0; k < points.length; k++) entry(k)];
      if (hasClosing && out.isNotEmpty) out.add(out.first);
      return jsonEncode({...decoded, 'features': out});
    }
    if (decoded is List && decoded.isNotEmpty && decoded.first is List) {
      final header = decoded.first as List;
      final rows = decoded.skip(1).toList();
      final hasClosing = closed && rows.length == originalCount + 1;
      if (rows.length != originalCount && !hasClosing) return null;
      final out = [
        for (final id in ids) id == null ? List<Object?>.filled(header.length, '') : rows[id],
      ];
      if (hasClosing && out.isNotEmpty) out.add(out.first);
      return jsonEncode([header, ...out]);
    }
  } catch (e) {
    AppLogger.debug('[FeatureEditor] sub_table を読めない: $e');
  }
  return null;
}

// ── 平面での計算（狭い範囲なので経度を緯度で縮めた平面で足りる） ──

/// 形の重心（頂点の平均）
LatLng centroidOf(Shape g) {
  final pts = g.expand((r) => r).toList();
  final lat = pts.map((p) => p.latitude).reduce((a, b) => a + b) / pts.length;
  final lng = pts.map((p) => p.longitude).reduce((a, b) => a + b) / pts.length;
  return LatLng(lat, lng);
}

/// [c] のまわりに [angle]（ラジアン、画面で時計回り）回し、[scale] 倍する
Shape transformShape(Shape g, LatLng c, {double angle = 0, double scale = 1}) {
  final k = math.cos(c.latitude * math.pi / 180);
  final cosA = math.cos(angle);
  final sinA = math.sin(angle);
  LatLng t(LatLng p) {
    // 東を x、北を y にした平面。画面の時計回りは北が上なので y を反転して回す
    final x = (p.longitude - c.longitude) * k;
    final y = p.latitude - c.latitude;
    final rx = (x * cosA + y * sinA) * scale;
    final ry = (-x * sinA + y * cosA) * scale;
    return LatLng(c.latitude + ry, c.longitude + rx / k);
  }

  return [for (final r in g) [for (final p in r) t(p)]];
}

Shape translateShape(Shape g, double dLat, double dLng) =>
    [for (final r in g) [for (final p in r) LatLng(p.latitude + dLat, p.longitude + dLng)]];
