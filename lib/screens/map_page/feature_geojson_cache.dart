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
// こかげマップ: 地図に流す GeoJSON の組み立て
//
// 通常ソース（全件）と選択ソース（選択中だけを上乗せするオーバーレイ）を
// 同じ変換で作る。選択だけ変わったときは [FeatureGeoJsonCache.rebuildSelection] で
// 選択リストだけ作り直し、通常リストは据え置く（GeoJSON が同じなら
// MapSourceManager が送信を省くので、選択のたびに全件が再描画されない）。

import 'dart:ui' show Rect;

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../models/nodes/feature_node.dart';
import '../../models/nodes/image_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../utils/geo_converter.dart';
import '../../utils/turf_geo_convert.dart';

/// 組み立ての材料
class FeatureGeoJsonInput {
  const FeatureGeoJsonInput({
    required this.lines,
    required this.polygons,
    required this.points,
    required this.photos,
    required this.selected,
    required this.lineVertices,
    required this.polygonVertices,
    this.styleKeyOf,
    this.stylePropKey = 'k-style',
    this.labelOf,
  });

  final List<LineFeatureNode> lines;
  final List<PolygonFeatureNode> polygons;
  final List<PointFeatureNode> points;
  final List<ImageNode> photos;
  final Set<LayerTreeNode> selected;

  /// ライン／ポリゴンの頂点マーカーを作るか
  final bool lineVertices;
  final bool polygonVertices;

  /// フィーチャが属するスタイルグループのキー。
  ///
  /// ⚠ 固有スタイルが1つも無いときは null にすること。属性が増えると GeoJSON が
  ///   太るし、「View 導入前と完全に同じ」を保てなくなる
  final String Function(FeatureNode f)? styleKeyOf;

  /// [styleKeyOf] の値を載せる属性名
  final String stylePropKey;

  /// 地図に出すラベル文字列。null なら属性に載せない（＝ラベル無し）。
  /// テンプレートの解決は呼び出し側（`label_template.dart`）
  final String? Function(FeatureNode f)? labelOf;

  /// ラベルを載せる属性名。MapSourceManager のラベルレイヤと合わせる
  static const labelPropKey = 'k-label';
}

class FeatureGeoJsonCache {
  List<geo.Feature<geo.Geometry>> polylines = const [];
  List<geo.Feature<geo.Geometry>> selectedPolylines = const [];
  List<geo.Feature<geo.Geometry>> polygons = const [];
  List<geo.Feature<geo.Geometry>> selectedPolygons = const [];
  List<geo.Feature<geo.Point>> markers = const [];
  List<geo.Feature<geo.Point>> selectedMarkers = const [];
  List<geo.Feature<geo.Point>> images = const [];
  List<geo.Feature<geo.Point>> selectedImages = const [];
  List<geo.Feature<geo.Point>> lineVertices = const [];
  List<geo.Feature<geo.Point>> selectedLineVertices = const [];
  List<geo.Feature<geo.Point>> polygonVertices = const [];
  List<geo.Feature<geo.Point>> selectedPolygonVertices = const [];

  /// 通常リスト（線・面・点）の**中身**の世代。全件を組み直しても形・スタイル・ラベルが同じなら進まない。
  /// GPS 軌跡の統合などで数十秒ごとに全件が組み直されるが、そのたびに焼き込み済みのテクスチャ（3D の引いた段）を
  /// 全部作り直すと 1 回 2〜4 秒 UI が止まる（2026-09-13、Pixel 9 で 46 枚 × 40〜90ms）
  int contentRevision = 0;

  /// 直近の [contentRevision] の進みで変わったフィーチャ（足した・消した・形やスタイルが変わった）の範囲（経度・緯度）。
  /// null は「全部」（最初の組み立て）。焼き直しはこの範囲に掛かるタイルだけでよい（記録中の GPS 軌跡は 30 秒ごとに伸びる）
  Rect? lastChangeLonLat;

  /// フィーチャごとの署名と範囲（前回の全件組み立て）。キー = (レイヤの同一性, rowId)
  Map<(int, int), (int, Rect)> _signatures = {};

  /// 全件を組み直す
  void rebuildAll(FeatureGeoJsonInput input) => _build(input, full: true);

  /// 選択リストだけ組み直す。通常リストはそのまま
  void rebuildSelection(FeatureGeoJsonInput input) =>
      _build(input, full: false);

  Map<String, Object?>? _props(
    FeatureGeoJsonInput input,
    FeatureNode f, [
    String? name,
  ]) {
    final key = input.styleKeyOf?.call(f);
    final label = input.labelOf?.call(f);
    if (key == null && label == null) {
      return name == null ? null : {'name': name};
    }
    return {
      'name': ?name,
      input.stylePropKey: ?key,
      FeatureGeoJsonInput.labelPropKey: ?label,
    };
  }

  static Map<String, Object?> _photoProps(ImageNode photo) => {
        'name': photo.name,
        'has_direction': photo.direction != null,
        if (photo.direction != null) 'direction': photo.direction,
        if (photo.takenAt != null)
          'taken_at': photo.takenAt!.millisecondsSinceEpoch,
      };

  void _build(FeatureGeoJsonInput input, {required bool full}) {
    // full のときだけ通常リストを作る。選択リストは常に作り直す
    // フィーチャの中身の署名: 形（座標の数と総和。1 点でも動けば変わる）とスタイル・ラベル・名前、および範囲。
    // ⚠ turf のオブジェクトの同一性は使えない（全件の組み直しのたびに DB から読み直されて別物になる）
    final sigs = full ? <(int, int), (int, Rect)>{} : null;
    (int, Rect) geomSign(geo.Geometry g) {
      var n = 0;
      var sx = 0.0, sy = 0.0;
      var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
      void add(double x, double y) {
        n++;
        sx += x;
        sy += y;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
      void series(geo.PositionSeries s) {
        final c = s.positionCount;
        for (var i = 0; i < c; i++) {
          add(s.x(i), s.y(i));
        }
      }
      if (g is geo.Point) {
        add(g.position.x, g.position.y);
      } else if (g is geo.LineString) {
        series(g.chain);
      } else if (g is geo.Polygon) {
        g.rings.forEach(series);
      } else if (g is geo.MultiLineString) {
        g.chains.forEach(series);
      } else if (g is geo.MultiPolygon) {
        for (final rings in g.ringArrays) {
          rings.forEach(series);
        }
      } else if (g is geo.MultiPoint) {
        for (final p in g.positions) {
          add(p.x, p.y);
        }
      }
      return (Object.hash(n, sx, sy), n == 0 ? Rect.zero : Rect.fromLTRB(minX, minY, maxX, maxY));
    }
    void sign(FeatureNode f, (int, Rect) geom, Map<String, Object?>? props) {
      sigs![(identityHashCode(f.parent), f.rowId)] = (Object.hash(geom.$1, Object.hashAll(props?.values ?? const [])), geom.$2);
    }
    final lines = full ? <geo.Feature<geo.Geometry>>[] : null;
    final linesSel = <geo.Feature<geo.Geometry>>[];
    final lineVerts = full ? <geo.Feature<geo.Point>>[] : null;
    final lineVertsSel = <geo.Feature<geo.Point>>[];
    for (final f in input.lines) {
      final sel = input.selected.contains(f);
      if (!full && !sel) continue;
      final geom = turfLineToGeo(f.turfFeature.geometry);
      if (geom == null) continue;
      final props = _props(input, f);
      final feature = geo.Feature<geo.Geometry>(
        geometry: geom,
        properties: props,
      );
      lines?.add(feature);
      if (sigs != null) sign(f, geomSign(geom), props);
      if (sel) linesSel.add(feature);
      if (input.lineVertices) {
        for (final pt in turfLineVertices(f.turfFeature.geometry)) {
          final v = geo.Feature<geo.Point>(geometry: geo.Point(pt));
          lineVerts?.add(v);
          if (sel) lineVertsSel.add(v);
        }
      }
    }

    final polys = full ? <geo.Feature<geo.Geometry>>[] : null;
    final polysSel = <geo.Feature<geo.Geometry>>[];
    final polyVerts = full ? <geo.Feature<geo.Point>>[] : null;
    final polyVertsSel = <geo.Feature<geo.Point>>[];
    for (final f in input.polygons) {
      final sel = input.selected.contains(f);
      if (!full && !sel) continue;
      final geom = turfPolygonToGeo(f.turfFeature.geometry);
      if (geom == null) continue;
      final props = _props(input, f);
      final feature = geo.Feature<geo.Geometry>(
        geometry: geom,
        properties: props,
      );
      polys?.add(feature);
      if (sigs != null) sign(f, geomSign(geom), props);
      if (sel) polysSel.add(feature);
      if (input.polygonVertices) {
        for (final pt in turfPolygonVertices(f.turfFeature.geometry)) {
          final v = geo.Feature<geo.Point>(geometry: geo.Point(pt));
          polyVerts?.add(v);
          if (sel) polyVertsSel.add(v);
        }
      }
    }

    final pts = full ? <geo.Feature<geo.Point>>[] : null;
    final ptsSel = <geo.Feature<geo.Point>>[];
    for (final f in input.points) {
      final sel = input.selected.contains(f);
      if (!full && !sel) continue;
      final coords = f.geometry;
      if (coords == null) continue;
      if (sigs != null) {
        var sx = 0.0, sy = 0.0;
        var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
        for (final pt in coords as List<LatLng>) {
          sx += pt.longitude;
          sy += pt.latitude;
          if (pt.longitude < minX) minX = pt.longitude;
          if (pt.longitude > maxX) maxX = pt.longitude;
          if (pt.latitude < minY) minY = pt.latitude;
          if (pt.latitude > maxY) maxY = pt.latitude;
        }
        final box = coords.isEmpty ? Rect.zero : Rect.fromLTRB(minX, minY, maxX, maxY);
        sign(f, (Object.hash(coords.length, sx, sy), box), _props(input, f, f.name));
      }
      for (final pt in coords as List<LatLng>) {
        final feature = geo.Feature<geo.Point>(
          geometry: geo.Point(pt.toGeographic()),
          properties: _props(input, f, f.name),
        );
        pts?.add(feature);
        if (sel) ptsSel.add(feature);
      }
    }

    final imgs = full ? <geo.Feature<geo.Point>>[] : null;
    final imgsSel = <geo.Feature<geo.Point>>[];
    for (final photo in input.photos) {
      if (!photo.hasLocation) continue;
      final sel = input.selected.contains(photo);
      if (!full && !sel) continue;
      final feature = geo.Feature<geo.Point>(
        geometry: geo.Point(photo.location!.toGeographic()),
        properties: _photoProps(photo),
      );
      imgs?.add(feature);
      if (sel) imgsSel.add(feature);
    }

    if (full) {
      // 変わったフィーチャの範囲を集める（足した・形やスタイルが変わった → 新しい範囲と前の範囲、消した → 前の範囲）
      final prev = _signatures;
      Rect? changed;
      void dirty(Rect r) => changed = changed == null ? r : changed!.expandToInclude(r);
      var any = false;
      for (final e in sigs!.entries) {
        final before = prev[e.key];
        if (before == null || before.$1 != e.value.$1) {
          any = true;
          dirty(e.value.$2);
          if (before != null) dirty(before.$2);
        }
      }
      for (final e in prev.entries) {
        if (!sigs.containsKey(e.key)) {
          any = true;
          dirty(e.value.$2);
        }
      }
      if (any || prev.isEmpty) {
        // 最初の組み立ては「全部」
        lastChangeLonLat = prev.isEmpty ? null : changed;
        contentRevision++;
      }
      _signatures = sigs;
      polylines = lines!;
      polygons = polys!;
      markers = pts!;
      images = imgs!;
      lineVertices = lineVerts!;
      polygonVertices = polyVerts!;
    }
    selectedPolylines = linesSel;
    selectedPolygons = polysSel;
    selectedMarkers = ptsSel;
    selectedImages = imgsSel;
    selectedLineVertices = lineVertsSel;
    selectedPolygonVertices = polyVertsSel;
  }
}
