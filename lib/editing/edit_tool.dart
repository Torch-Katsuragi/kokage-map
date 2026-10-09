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
// 編集中の地図の道具（名前は 'Edit'）。1 本指は形の操作、地図は 2 本指で動かす。
//
// 地図の層（TerrainMapLayer）は 'Edit' を「1 本指を取る道具」として扱い、真上に固定して指を渡してくる。
// 当たり判定は画面の上で行う（地図の縮尺に関係なく指で押しやすい大きさにするため）。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../interfaces/map_state_interface.dart';
import '../tools/map_tool.dart';
import 'edit_session.dart';

final editToolProvider = Provider<EditTool>(EditTool.new);

/// 頂点に当たったとみなす距離（論理ピクセル）
const _vertexHit = 30.0;
const _midHit = 24.0;

class EditTool extends MapTool {
  EditTool(this._ref);
  final Ref _ref;

  @override
  String get name => 'Edit';

  @override
  IconData get icon => Icons.edit_location_alt;

  FeatureEditor get _ed => _ref.read(featureEditorProvider.notifier);
  EditState? get _s => _ref.read(featureEditorProvider);

  // ドラッグの途中で使うもの
  /// ドラッグを始めたときの形（離したらこれを 1 手の前として積む）
  Snap? _snap;
  Shape? _base;
  (int, int)? _dragVertex;
  bool _dragAll = false;
  LatLng? _startLatLng;
  Offset? _centre;
  Offset? _startVec;

  /// 一番近い頂点（画面で [limit] 以内）
  (int, int)? _hitVertex(Shape g, Offset p, IMapState m, double limit) {
    (int, int)? best;
    var bestD = limit;
    for (var r = 0; r < g.length; r++) {
      for (var i = 0; i < g[r].length; i++) {
        final d = (m.latLngToOffset(g[r][i]) - p).distance;
        if (d < bestD) {
          bestD = d;
          best = (r, i);
        }
      }
    }
    return best;
  }

  /// 一番近い辺の中点。（リング, 辺の始まりの番号, 中点）
  (int, int, LatLng)? _hitMid(EditState s, Offset p, IMapState m) {
    (int, int, LatLng)? best;
    var bestD = _midHit;
    for (var r = 0; r < s.geom.length; r++) {
      final ring = s.geom[r];
      final edges = s.kind == EditKind.polygon ? ring.length : ring.length - 1;
      for (var i = 0; i < edges; i++) {
        final a = ring[i];
        final b = ring[(i + 1) % ring.length];
        final mid = LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);
        final d = (m.latLngToOffset(mid) - p).distance;
        if (d < bestD) {
          bestD = d;
          best = (r, i, mid);
        }
      }
    }
    return best;
  }

  /// ドラッグを始める（離したときに今の形を 1 手の前として積む）
  void _grab(EditState s) {
    _base = s.geom;
    _snap = s.snap;
  }

  void _reset() {
    _base = null;
    _snap = null;
    _dragVertex = null;
    _dragAll = false;
    _startLatLng = null;
    _centre = null;
    _startVec = null;
  }

  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {
    final s = _s;
    if (s == null) return;
    _reset();
    final p = details.localFocalPoint;
    switch (s.mode) {
      case EditMode.vertex:
        final v = _hitVertex(s.geom, p, mapState, _vertexHit);
        if (v != null) {
          _grab(s);
          _dragVertex = v;
          _ed.select(v);
          return;
        }
        final mid = _hitMid(s, p, mapState);
        if (mid != null) {
          // 中点を掴んだら、そこに頂点を足してそのまま動かす（足すのと動かすのを 1 手にする）
          _grab(s);
          final (r, i, ll) = mid;
          _ed.previewInsert(r, i + 1, ll);
          _dragVertex = (r, i + 1);
          _ed.select(_dragVertex);
        }
      case EditMode.move:
        _grab(s);
        _dragAll = true;
        _startLatLng = mapState.offsetToLatLng(p);
      case EditMode.rotate:
      case EditMode.scale:
        _grab(s);
        _centre = mapState.latLngToOffset(centroidOf(s.geom));
        _startVec = p - _centre!;
      case EditMode.extend:
      case EditMode.simplify:
      case EditMode.trim:
        break; // 簡略化・切り落とすはパネルのつまみで
    }
  }

  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {
    final s = _s;
    final base = _base;
    if (s == null || base == null) return;
    final p = details.localFocalPoint;
    final v = _dragVertex;
    if (v != null) {
      final g = [for (final ring in s.geom) List<LatLng>.of(ring)];
      g[v.$1][v.$2] = mapState.offsetToLatLng(p);
      _ed.preview(g);
      return;
    }
    if (_dragAll && _startLatLng != null) {
      final now = mapState.offsetToLatLng(p);
      _ed.preview(translateShape(base, now.latitude - _startLatLng!.latitude, now.longitude - _startLatLng!.longitude));
      return;
    }
    final c = _centre;
    final sv = _startVec;
    if (c != null && sv != null && sv.distance > 1) {
      final cur = p - c;
      final centre = centroidOf(base);
      if (s.mode == EditMode.rotate) {
        final a = math.atan2(cur.dy, cur.dx) - math.atan2(sv.dy, sv.dx);
        _ed.preview(transformShape(base, centre, angle: a));
      } else {
        final k = (cur.distance / sv.distance).clamp(0.05, 20.0);
        _ed.preview(transformShape(base, centre, scale: k));
      }
    }
  }

  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) {
    final before = _snap;
    if (before != null) _ed.commit(before);
    _reset();
  }

  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    final s = _s;
    if (s == null) return;
    final p = details.localPosition;
    switch (s.mode) {
      case EditMode.vertex:
        final v = _hitVertex(s.geom, p, mapState, _vertexHit);
        if (v != null) {
          _ed.select(s.selected == v ? null : v);
          return;
        }
        final mid = _hitMid(s, p, mapState);
        if (mid != null) {
          final (r, i, ll) = mid;
          _ed.insertVertex(r, i, ll);
          _ed.select((r, i + 1));
          return;
        }
        _ed.select(null);
      case EditMode.move:
        // 点は押したところへ動かす
        if (s.kind == EditKind.point) _ed.apply([[mapState.offsetToLatLng(p)]], s.ids);
      case EditMode.extend:
        // 端点を押せばそちらから延ばす。それ以外は、押したところに近い端から続ける
        final line = s.geom.first;
        final v = _hitVertex(s.geom, p, mapState, _vertexHit);
        if (v != null && (v.$2 == 0 || v.$2 == line.length - 1)) {
          _ed.select(v);
          return;
        }
        final sel = s.selected;
        final fromEnd = sel != null && (sel == (0, 0) || sel == (0, line.length - 1));
        if (!fromEnd) {
          final dStart = (mapState.latLngToOffset(line.first) - p).distance;
          final dEnd = (mapState.latLngToOffset(line.last) - p).distance;
          _ed.select(dStart < dEnd ? (0, 0) : (0, line.length - 1));
        }
        _ed.extendLine(mapState.offsetToLatLng(p));
      case EditMode.rotate:
      case EditMode.scale:
      case EditMode.simplify:
      case EditMode.trim:
        break;
    }
  }
}
