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

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models/nodes/feature_node.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../tools/map_tool.dart';
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
}

/// 地物の種類ごとに使える道具
List<EditMode> modesFor(EditKind k) => switch (k) {
      EditKind.point => const [EditMode.move],
      EditKind.line => const [EditMode.vertex, EditMode.move, EditMode.rotate, EditMode.scale, EditMode.extend],
      EditKind.polygon => const [EditMode.vertex, EditMode.move, EditMode.rotate, EditMode.scale],
    };

/// 形。点は [[p]]、線は [頂点…]、面は [外周, 穴…]（どれも閉じない。最後に最初の点を重ねない）
typedef Shape = List<List<LatLng>>;

class EditState {
  const EditState({
    required this.feature,
    required this.kind,
    required this.geom,
    required this.original,
    required this.mode,
    this.undo = const [],
    this.redo = const [],
    this.selected,
    this.columns = const [],
    this.attrs = const {},
    this.originalAttrs = const {},
    this.saving = false,
  });

  final FeatureNode feature;
  final EditKind kind;
  final Shape geom;
  final Shape original;
  final EditMode mode;
  final List<Shape> undo;
  final List<Shape> redo;

  /// 選んだ頂点（リング, 番号）
  final (int, int)? selected;

  /// 書き換えられる属性の列（fid・geom・_ で始まるものは除く）
  final List<String> columns;
  final Map<String, Object?> attrs;
  final Map<String, Object?> originalAttrs;
  final bool saving;

  bool get shapeChanged => !_sameShape(geom, original);
  bool get attrsChanged => columns.any((c) => '${attrs[c] ?? ''}' != '${originalAttrs[c] ?? ''}');
  bool get dirty => shapeChanged || attrsChanged;

  EditState copyWith({
    Shape? geom,
    EditMode? mode,
    List<Shape>? undo,
    List<Shape>? redo,
    (int, int)? Function()? selected,
    List<String>? columns,
    Map<String, Object?>? attrs,
    Map<String, Object?>? originalAttrs,
    bool? saving,
  }) =>
      EditState(
        feature: feature,
        kind: kind,
        geom: geom ?? this.geom,
        original: original,
        mode: mode ?? this.mode,
        undo: undo ?? this.undo,
        redo: redo ?? this.redo,
        selected: selected != null ? selected() : this.selected,
        columns: columns ?? this.columns,
        attrs: attrs ?? this.attrs,
        originalAttrs: originalAttrs ?? this.originalAttrs,
        saving: saving ?? this.saving,
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

/// 閉じたリング（最後が最初と同じ）を開く
List<LatLng> _open(List<LatLng> ring) =>
    ring.length > 1 && ring.first == ring.last ? ring.sublist(0, ring.length - 1) : List.of(ring);

final featureEditorProvider = NotifierProvider<FeatureEditor, EditState?>(FeatureEditor.new);

class FeatureEditor extends Notifier<EditState?> {
  /// 編集の前に持っていた道具（終わったら戻す）
  MapTool? _toolBefore;

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
      original: _copy(shape),
      mode: modesFor(kind).first,
    );
    _toolBefore = ref.read(currentToolProvider);
    ref.read(currentToolProvider.notifier).set(ref.read(editToolProvider));
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

  /// 書き換えてよい列（番号・形・内部用は除く。属性テーブルと同じ決まり）
  static bool _editable(String name) {
    final n = name.toLowerCase();
    return !(n == 'id' || n == 'fid' || n == 'geom' || n == 'geometry' || n == 'rmaps_metadata' || n.startsWith('_'));
  }

  void setMode(EditMode m) {
    final s = state;
    if (s != null) state = s.copyWith(mode: m, selected: () => null);
  }

  void select((int, int)? v) {
    final s = state;
    if (s != null) state = s.copyWith(selected: () => v);
  }

  /// ドラッグ中の途中経過（元に戻す履歴には積まない）
  void preview(Shape g) {
    final s = state;
    if (s != null) state = s.copyWith(geom: g);
  }

  /// 1 手を確定する。[before] はその手の前の形
  void commit(Shape before) {
    final s = state;
    if (s == null || _sameShape(before, s.geom)) return;
    state = s.copyWith(undo: [...s.undo, before], redo: const []);
  }

  /// その場で 1 手（途中経過なし）
  void apply(Shape g) {
    final s = state;
    if (s == null) return;
    final before = s.geom;
    state = s.copyWith(geom: g);
    commit(before);
  }

  void undo() {
    final s = state;
    if (s == null || s.undo.isEmpty) return;
    state = s.copyWith(geom: s.undo.last, undo: s.undo.sublist(0, s.undo.length - 1), redo: [...s.redo, s.geom],
        selected: () => null);
  }

  void redo() {
    final s = state;
    if (s == null || s.redo.isEmpty) return;
    state = s.copyWith(geom: s.redo.last, redo: s.redo.sublist(0, s.redo.length - 1), undo: [...s.undo, s.geom],
        selected: () => null);
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
    final g = _copy(s.geom)..[v.$1].removeAt(v.$2);
    apply(g);
    select(null);
  }

  /// 辺の途中に頂点を足す（[after] の次に入る）
  void insertVertex(int ring, int after, LatLng p) {
    final s = state;
    if (s == null) return;
    apply(_copy(s.geom)..[ring].insert(after + 1, p));
  }

  /// 線の端に点を足す（始点が選ばれていれば始点の前、それ以外は終点の後）
  void extendLine(LatLng p) {
    final s = state;
    if (s == null || s.kind != EditKind.line) return;
    final atStart = s.selected == (0, 0);
    final g = _copy(s.geom);
    if (atStart) {
      g[0].insert(0, p);
    } else {
      g[0].add(p);
    }
    apply(g);
    select(atStart ? (0, 0) : (0, g[0].length - 1));
  }

  void setAttr(String col, Object? value) {
    final s = state;
    if (s != null) state = s.copyWith(attrs: {...s.attrs, col: value});
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
    return true;
  }

  /// 何も書かずに終える
  void cancel() => _end();

  void _end() {
    if (state == null) return;
    state = null;
    final back = _toolBefore;
    _toolBefore = null;
    if (back != null && back.name != 'Edit') {
      ref.read(currentToolProvider.notifier).set(back);
    } else {
      ref.read(currentToolProvider.notifier).set(ref.read(panToolProvider));
    }
  }
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
