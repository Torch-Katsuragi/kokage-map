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
    final lines = full ? <geo.Feature<geo.Geometry>>[] : null;
    final linesSel = <geo.Feature<geo.Geometry>>[];
    final lineVerts = full ? <geo.Feature<geo.Point>>[] : null;
    final lineVertsSel = <geo.Feature<geo.Point>>[];
    for (final f in input.lines) {
      final sel = input.selected.contains(f);
      if (!full && !sel) continue;
      final geom = turfLineToGeo(f.turfFeature.geometry);
      if (geom == null) continue;
      final feature = geo.Feature<geo.Geometry>(
        geometry: geom,
        properties: _props(input, f),
      );
      lines?.add(feature);
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
      final feature = geo.Feature<geo.Geometry>(
        geometry: geom,
        properties: _props(input, f),
      );
      polys?.add(feature);
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
