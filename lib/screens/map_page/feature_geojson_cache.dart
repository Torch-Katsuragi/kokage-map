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
// 選択リストだけ作り直し、通常リストは据え置く（リストの同一性と [FeatureGeoJsonCache.contentRevision] が
// 変わらないので、3D 地図面は選択のたびに全件を組み直さない）。地図ページは `SceneSink.pushFeatures` 越しに呼ぶ。

import 'dart:ui' show Rect;

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../models/nodes/feature_node.dart';
import '../../models/nodes/image_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../utils/geo_converter.dart';

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
    this.drawRankOf,
    this.hidden = const {},
  });

  /// 地物の描く順の段（レイヤの並び。大きいほど手前）。面の塗りとオーバーレイ画像をこの順で重ねる。
  /// null なら全部 0（[FeatureGeoJsonCache.polygonRanks]）
  final int Function(FeatureNode f)? drawRankOf;

  /// 描かないもの（編集中の地物。写しを編集の重ね絵で描く）
  final Set<LayerTreeNode> hidden;

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

  /// ラベルを載せる属性名。3D 地図面のラベル（`TerrainSceneBuilder` の labelProp）に渡す
  static const labelPropKey = 'k-label';
}

class FeatureGeoJsonCache {
  List<geo.Feature<geo.Geometry>> polylines = const [];
  List<geo.Feature<geo.Geometry>> selectedPolylines = const [];
  List<geo.Feature<geo.Geometry>> polygons = const [];

  /// [polygons] と同じ並びの、描く順の段（[FeatureGeoJsonInput.drawRankOf]。大きいほど手前）。
  /// [polygons] は下の段から並ぶ（地図ページが下のレイヤから渡す）
  List<int> polygonRanks = const [];
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
  /// null は「全部」（最初の組み立て）。焼き直しはこの範囲に掛かるタイルだけでよい（記録中の GPS 軌跡は 30 秒ごとに伸びる）。
  /// 線の後ろに点を足しただけ（GPS 軌跡の統合）なら、足した区間の範囲だけ（2026-10-12。軌跡全体の範囲を毎回焼き直していた）
  Rect? lastChangeLonLat;

  /// 直近の [contentRevision] の進みに面（塗り）が含まれるか。false なら線・点だけが変わった。
  /// 寄った段のテクスチャは面の塗りしか焼かないので、false のときは寄った段を焼き直さなくてよい
  bool lastChangeHasFills = true;

  /// 直近の [contentRevision] の進みが、線の後ろに点を足しただけ（GPS 軌跡の統合）なら、その区間の範囲（経度・緯度。
  /// [lastChangeLonLat] と同じ）。それ以外（描いた・消した・形や属性を変えた・面）は null。
  /// 3D の焼き込みは、これが 1 texel に届かないタイルの焼き直しを見送る（`FeatureBakeLedger`）
  Rect? lastChangeExtension;

  /// フィーチャごとの署名と範囲（前回の全件組み立て）。キー = (レイヤの同一性, rowId)
  Map<(int, int), _Sig> _signatures = {};

  /// 線・面の変換結果の使い回し（フィーチャ → 前回の turf の形・属性・変換後・署名）。
  /// レイヤを読み直さない限り turf の形は同じオブジェクトなので、形と属性が同じなら変換も署名もやり直さない
  /// （GPS 軌跡の統合で 20 秒ごとに全件が組み直され、1.5 万面を毎回変換していた。2026-10-06）
  final Expando<_Conv> _conv = Expando('geojson.conv');

  /// 点（MultiPoint の点ごとの Feature）と写真の Feature の使い回し。中身が同じなら同じオブジェクトを返し、リストも前のまま保てるように
  final Expando<_PtConv> _ptConv = Expando('geojson.pt');
  final Expando<_PtConv> _photoConv = Expando('geojson.photo');

  /// 頂点の点（頂点の表示をオンにしているとき）。形が同じなら前と同じオブジェクトを返す（リストを前のまま保てるように）
  final Expando<(Object?, List<geo.Feature<geo.Point>>)> _vertexConv = Expando('geojson.vertex');
  List<geo.Feature<geo.Point>> _vertices(FeatureNode f, Object? turfGeom, Iterable<geo.Position> Function() positions) {
    final c = _vertexConv[f];
    if (c != null && identical(c.$1, turfGeom)) return c.$2;
    final vs = [for (final pt in positions()) geo.Feature<geo.Point>(geometry: geo.Point(pt))];
    _vertexConv[f] = (turfGeom, vs);
    return vs;
  }

  /// 全件を組み直す
  void rebuildAll(FeatureGeoJsonInput input) => _build(input, full: true);

  /// 選択リストだけ組み直す。通常リストはそのまま
  void rebuildSelection(FeatureGeoJsonInput input) =>
      _build(input, full: false);

  /// [changed] の線・面だけ組み直す（ほかの地物の一覧は前回の全件組み立てと同じ前提）。
  /// GPS 軌跡の統合（20 秒ごとに今日の 1 本が伸びる）で、全件の組み直し（1.5 万面の署名を取り直す）をしないための口。
  /// 面のリストなど変わっていない一覧は前のまま（同一性で引く描画側のキャッシュが外れない）。
  ///
  /// できなければ何もせず false（呼び出し側が [rebuildAll] する）: 点・頂点の表示・前回の一覧に無い地物・描かない地物
  bool rebuildFeatures(FeatureGeoJsonInput input, Set<FeatureNode> changed) {
    if (changed.isEmpty) return true;
    if (_signatures.isEmpty || input.lineVertices || input.polygonVertices) return false;
    final linePos = <int, geo.Feature<geo.Geometry>>{};
    final polyPos = <int, geo.Feature<geo.Geometry>>{};
    final sigs = <(int, int), _Sig>{};
    for (final f in changed) {
      if (input.hidden.contains(f) || f is! LineFeatureNode && f is! PolygonFeatureNode) return false;
      final fill = f is PolygonFeatureNode;
      final list = fill ? polygons : polylines;
      final c = _conv[f];
      final key = _keyOf(f);
      if (c == null || !_signatures.containsKey(key)) return false;
      final at = list.indexWhere((e) => identical(e, c.feature));
      if (at < 0) return false;
      final turfGeom = f.turfFeature.geometry;
      final props = _props(input, f);
      final hit = _converted(f, turfGeom, props, () => fill ? turfPolygonToGeo(turfGeom) : turfLineToGeo(turfGeom));
      if (hit == null) return false;
      (fill ? polyPos : linePos)[at] = hit.$1;
      sigs[key] = _Sig.of(hit.$2, props, fill: fill, geom: hit.$1.geometry);
    }
    List<geo.Feature<geo.Geometry>> patched(List<geo.Feature<geo.Geometry>> list, Map<int, geo.Feature<geo.Geometry>> at) {
      if (at.isEmpty) return list;
      final out = List.of(list);
      at.forEach((i, f) => out[i] = f);
      return _keep(list, out);
    }

    polylines = patched(polylines, linePos);
    polygons = patched(polygons, polyPos);
    final prev = _signatures;
    _signatures = {...prev, ...sigs};
    _noteChanges(prev, sigs, removed: const []);
    if (changed.any(input.selected.contains)) _build(input, full: false);
    return true;
  }

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

  static (int, int) _keyOf(FeatureNode f) => (identityHashCode(f.parent), f.rowId);

  /// 変換済みを使い回す（形と属性が前回と同じとき）。無ければ変換して覚える
  (geo.Feature<geo.Geometry>, _GeomSig)? _converted(
    FeatureNode f,
    Object? turfGeom,
    Map<String, Object?>? props,
    geo.Geometry? Function() convert,
  ) {
    final c = _conv[f];
    if (c != null && identical(c.turfGeom, turfGeom) && _sameProps(c.props, props)) return (c.feature, c.sign);
    final geom = convert();
    if (geom == null) return null;
    final feature = geo.Feature<geo.Geometry>(geometry: geom, properties: props);
    final sg = _GeomSig.of(geom);
    _conv[f] = _Conv(turfGeom, props, feature, sg);
    return (feature, sg);
  }

  /// 前回の署名 [prev] と今回の署名 [now]（と消えたキー [removed]）を比べ、変わっていれば世代を進めて範囲を記録する
  void _noteChanges(Map<(int, int), _Sig> prev, Map<(int, int), _Sig> now, {required Iterable<(int, int)> removed}) {
    Rect? changed;
    void dirty(Rect r) => changed = changed == null ? r : changed!.expandToInclude(r);
    var any = false;
    var fills = false;
    var extensionOnly = true;
    for (final e in now.entries) {
      final before = prev[e.key];
      if (before != null && before.hash == e.value.hash) continue;
      any = true;
      fills = fills || e.value.fill || (before?.fill ?? false);
      final (box, extension) = _changedBox(before, e.value);
      extensionOnly = extensionOnly && extension;
      dirty(box);
    }
    for (final k in removed) {
      final before = prev[k]!;
      any = true;
      extensionOnly = false;
      fills = fills || before.fill;
      dirty(before.box);
    }
    if (any || prev.isEmpty) {
      // 最初の組み立ては「全部」
      lastChangeLonLat = prev.isEmpty ? null : changed;
      lastChangeHasFills = prev.isEmpty || fills;
      lastChangeExtension = prev.isEmpty || fills || !extensionOnly ? null : changed;
      contentRevision++;
    }
  }

  void _build(FeatureGeoJsonInput input, {required bool full}) {
    // full のときだけ通常リストを作る。選択リストは常に作り直す
    // フィーチャの中身の署名: 形（座標の数と総和。1 点でも動けば変わる）とスタイル・ラベル・名前、および範囲。
    // ⚠ turf のオブジェクトの同一性は使えない（全件の組み直しのたびに DB から読み直されて別物になる）
    final sigs = full ? <(int, int), _Sig>{} : null;

    final lines = full ? <geo.Feature<geo.Geometry>>[] : null;
    final linesSel = <geo.Feature<geo.Geometry>>[];
    final lineVerts = full ? <geo.Feature<geo.Point>>[] : null;
    final lineVertsSel = <geo.Feature<geo.Point>>[];
    for (final f in input.lines) {
      if (input.hidden.contains(f)) continue;
      final sel = input.selected.contains(f);
      if (!full && !sel) continue;
      final turfGeom = f.turfFeature.geometry;
      final props = _props(input, f);
      final hit = _converted(f, turfGeom, props, () => turfLineToGeo(turfGeom));
      if (hit == null) continue;
      final feature = hit.$1;
      lines?.add(feature);
      sigs?[_keyOf(f)] = _Sig.of(hit.$2, props, fill: false, geom: feature.geometry);
      if (sel) linesSel.add(feature);
      if (input.lineVertices) {
        final vs = _vertices(f, turfGeom, () => turfLineVertices(turfGeom));
        lineVerts?.addAll(vs);
        if (sel) lineVertsSel.addAll(vs);
      }
    }

    final polys = full ? <geo.Feature<geo.Geometry>>[] : null;
    final polyRanks = full ? <int>[] : null;
    final polysSel = <geo.Feature<geo.Geometry>>[];
    final polyVerts = full ? <geo.Feature<geo.Point>>[] : null;
    final polyVertsSel = <geo.Feature<geo.Point>>[];
    for (final f in input.polygons) {
      if (input.hidden.contains(f)) continue;
      final sel = input.selected.contains(f);
      if (!full && !sel) continue;
      final turfGeom = f.turfFeature.geometry;
      final props = _props(input, f);
      final hit = _converted(f, turfGeom, props, () => turfPolygonToGeo(turfGeom));
      if (hit == null) continue;
      final feature = hit.$1;
      polys?.add(feature);
      polyRanks?.add(input.drawRankOf?.call(f) ?? 0);
      sigs?[_keyOf(f)] = _Sig.of(hit.$2, props, fill: true);
      if (sel) polysSel.add(feature);
      if (input.polygonVertices) {
        final vs = _vertices(f, turfGeom, () => turfPolygonVertices(turfGeom));
        polyVerts?.addAll(vs);
        if (sel) polyVertsSel.addAll(vs);
      }
    }

    final pts = full ? <geo.Feature<geo.Point>>[] : null;
    final ptsSel = <geo.Feature<geo.Point>>[];
    for (final f in input.points) {
      if (input.hidden.contains(f)) continue;
      final sel = input.selected.contains(f);
      if (!full && !sel) continue;
      final turfGeom = f.turfFeature.geometry;
      final props = _props(input, f, f.name);
      final cached = _ptConv[f];
      if (cached != null && identical(cached.ref, turfGeom) && _sameProps(cached.props, props)) {
        if (sigs != null) sigs[_keyOf(f)] = cached.sign!;
        pts?.addAll(cached.features);
        if (sel) ptsSel.addAll(cached.features);
        continue;
      }
      // 座標の一覧（List<LatLng>）は使い回せなかったときだけ作る
      final coords = f.geometry as List<LatLng>?;
      if (coords == null) continue;
      final pointsSig = _GeomSig.ofLatLngs(coords);
      final ptSign = _Sig.of(pointsSig, props, fill: false);
      if (sigs != null) sigs[_keyOf(f)] = ptSign;
      final made = <geo.Feature<geo.Point>>[
        for (final pt in coords)
          geo.Feature<geo.Point>(geometry: geo.Point(pt.toGeographic()), properties: props),
      ];
      _ptConv[f] = _PtConv(turfGeom, props, made, ptSign);
      pts?.addAll(made);
      if (sel) ptsSel.addAll(made);
    }

    final imgs = full ? <geo.Feature<geo.Point>>[] : null;
    final imgsSel = <geo.Feature<geo.Point>>[];
    for (final photo in input.photos) {
      if (!photo.hasLocation) continue;
      final sel = input.selected.contains(photo);
      if (!full && !sel) continue;
      final props = _photoProps(photo);
      final cachedPhoto = _photoConv[photo];
      if (cachedPhoto != null && cachedPhoto.ref == photo.location && _sameProps(cachedPhoto.props, props)) {
        imgs?.add(cachedPhoto.features.first);
        if (sel) imgsSel.add(cachedPhoto.features.first);
        continue;
      }
      final feature = geo.Feature<geo.Point>(
        geometry: geo.Point(photo.location!.toGeographic()),
        properties: props,
      );
      _photoConv[photo] = _PtConv(photo.location, props, [feature], null);
      imgs?.add(feature);
      if (sel) imgsSel.add(feature);
    }

    if (full) {
      // 変わったフィーチャの範囲を集める（足した・形やスタイルが変わった → 新しい範囲と前の範囲、消した → 前の範囲）
      final prev = _signatures;
      _noteChanges(prev, sigs!, removed: [for (final k in prev.keys) if (!sigs.containsKey(k)) k]);
      _signatures = sigs;
      // 中身が前回と同じなら前回のリストのまま（同一性で引く描画側のキャッシュ＝タイルごとのシーンが外れない）
      polylines = _keep(polylines, lines!);
      polygons = _keep(polygons, polys!);
      polygonRanks = _sameInts(polygonRanks, polyRanks!) ? polygonRanks : List.unmodifiable(polyRanks);
      markers = _keep(markers, pts!);
      images = _keep(images, imgs!);
      lineVertices = _keep(lineVertices, lineVerts!);
      polygonVertices = _keep(polygonVertices, polyVerts!);
    }
    selectedPolylines = _keep(selectedPolylines, linesSel);
    selectedPolygons = _keep(selectedPolygons, polysSel);
    selectedMarkers = _keep(selectedMarkers, ptsSel);
    selectedImages = _keep(selectedImages, imgsSel);
    selectedLineVertices = _keep(selectedLineVertices, lineVertsSel);
    selectedPolygonVertices = _keep(selectedPolygonVertices, polyVertsSel);
  }
}

/// 変わった地物の焼き直す範囲と、線の後ろに点を足しただけか。足しただけ（前の座標がそのまま先頭に並ぶ）なら、
/// 前の最後の点から足した点までの範囲。それ以外は前と今の範囲を合わせたもの。
/// 「足しただけ」は線（面でない）で、線の本数が変わらないときだけ（新しい本は離れた所に丸い点として現れるので）
(Rect, bool) _changedBox(_Sig? before, _Sig now) {
  if (before == null) return (now.box, false);
  final old = before.geom, cur = now.geom;
  if (old != null && cur != null && before.propsHash == now.propsHash && now.geomSig.n > before.geomSig.n && before.geomSig.n > 0) {
    final a = _flat(old), b = _flat(cur);
    var prefix = true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        prefix = false;
        break;
      }
    }
    if (prefix) {
      var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
      for (var i = a.length - 2; i < b.length; i += 2) {
        final x = b[i], y = b[i + 1];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
      final chains = _chainCount(cur);
      final extension = !now.fill && !before.fill && chains != null && chains == _chainCount(old);
      return (Rect.fromLTRB(minX, minY, maxX, maxY), extension);
    }
  }
  return (before.box.expandToInclude(now.box), false);
}

/// 線の本数（線・複数線のとき。それ以外は null）
int? _chainCount(geo.Geometry g) => switch (g) {
      geo.LineString() => 1,
      geo.MultiLineString(:final chains) => chains.length,
      _ => null,
    };

/// 形の座標を順に（線・面・その複数形と点）
void _eachPosition(geo.Geometry g, void Function(double x, double y) add) {
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
}

List<double> _flat(geo.Geometry g) {
  final out = <double>[];
  _eachPosition(g, (x, y) => out
    ..add(x)
    ..add(y));
  return out;
}

/// 同じ要素（同一のオブジェクト）が同じ順に並んでいれば前のリストを返す
List<T> _keep<T>(List<T> before, List<T> after) {
  if (before.length != after.length) return after;
  for (var i = 0; i < after.length; i++) {
    if (!identical(before[i], after[i])) return after;
  }
  return before;
}

bool _sameInts(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameProps(Map<String, Object?>? a, Map<String, Object?>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 形の署名: 座標の数・総和（1 点でも動けば変わる）と範囲
class _GeomSig {
  const _GeomSig(this.n, this.hash, this.box);

  factory _GeomSig.of(geo.Geometry g) {
    var n = 0;
    var sx = 0.0, sy = 0.0;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    _eachPosition(g, (x, y) {
      n++;
      sx += x;
      sy += y;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    });
    return _GeomSig(n, Object.hash(n, sx, sy), n == 0 ? Rect.zero : Rect.fromLTRB(minX, minY, maxX, maxY));
  }

  factory _GeomSig.ofLatLngs(List<LatLng> coords) {
    var sx = 0.0, sy = 0.0;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final pt in coords) {
      sx += pt.longitude;
      sy += pt.latitude;
      if (pt.longitude < minX) minX = pt.longitude;
      if (pt.longitude > maxX) maxX = pt.longitude;
      if (pt.latitude < minY) minY = pt.latitude;
      if (pt.latitude > maxY) maxY = pt.latitude;
    }
    return _GeomSig(
      coords.length,
      Object.hash(coords.length, sx, sy),
      coords.isEmpty ? Rect.zero : Rect.fromLTRB(minX, minY, maxX, maxY),
    );
  }

  final int n;
  final int hash;
  final Rect box;
}

/// 地物の署名: 形とスタイル・ラベル・名前。[fill] は面（寄った段のテクスチャにも塗りが焼かれる）。
/// [geom] は線の形（後ろに点を足しただけかを見る。[_changedBox]）
class _Sig {
  _Sig(this.geomSig, this.propsHash, {required this.fill, this.geom}) : hash = Object.hash(geomSig.hash, propsHash);

  factory _Sig.of(_GeomSig g, Map<String, Object?>? props, {required bool fill, geo.Geometry? geom}) =>
      _Sig(g, Object.hashAll(props?.values ?? const []), fill: fill, geom: geom);

  final _GeomSig geomSig;
  final int propsHash;
  final int hash;
  final bool fill;
  final geo.Geometry? geom;

  Rect get box => geomSig.box;
}

class _Conv {
  _Conv(this.turfGeom, this.props, this.feature, this.sign);
  final Object? turfGeom;
  final Map<String, Object?>? props;
  final geo.Feature<geo.Geometry> feature;
  final _GeomSig sign;
}

class _PtConv {
  _PtConv(this.ref, this.props, this.features, this.sign);

  /// 何から作ったか（点は turf の形の同一性、写真は位置の値で比べる）
  final Object? ref;
  final Map<String, Object?>? props;
  final List<geo.Feature<geo.Point>> features;
  final _Sig? sign;
}
