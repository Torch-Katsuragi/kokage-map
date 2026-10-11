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
// Z・M 付きレイヤへ書くときの頂点の Z・M の決め方（docs/technical/external-formats.md「Z・M 付きのレイヤの編集」）
//
// 編集の道具は緯度経度（2D）で動くので、書く前に頂点ごとの Z・M をここで付け直す。
// - 動かしていない頂点（元の形に同じ位置の頂点がある）: 元の Z・M
// - 動かした頂点・足した頂点・新しい地物: Z は標高タイル（3D 地形と同じ）、M は 0
// - 標高が引けない（オフラインでタイルが無い・範囲外）: Z は 0（ログに残す）
import 'package:geobase/geobase.dart' as geo;

import '../../utils/app_logger.dart';

/// （経度, 緯度）の並び → 標高（m）。引けない点は null
typedef ElevationLookup = Future<List<double?>> Function(List<(double lon, double lat)> points);

/// レイヤの次元（`gpkg_geometry_columns` の z・m）
class LayerDims {
  const LayerDims({this.z = 0, this.m = 0});

  /// 0: 禁止、1: 必須、2: 任意（GeoPackage 仕様）
  final int z;
  final int m;

  static const xy = LayerDims();

  /// Z を書くか。任意（2）も書く（元が Z 付きのレイヤを 2D に落とさない）
  bool get hasZ => z == 1 || z == 2;

  /// M を書くか。任意（2）は元の形に M があったときだけ
  bool hasMFor(geo.Geometry? original) => m == 1 || (m == 2 && original != null && _positions(original).any((p) => p.isMeasured));

  bool get isXY => !hasZ && m == 0;
}

/// Z・M の付け直し
class VertexZ {
  VertexZ._();

  /// 標高の引き方。アプリは地図の初期化で標高タイルの引き方を入れる（未設定なら Z は 0）。テストは差し替える
  static ElevationLookup? elevationLookup;

  /// 同じ位置とみなす差（度）。編集の道具を通っても動かしていない頂点は同じ値のまま来るので、ほぼ一致だけを見る
  static const epsilonDeg = 1e-9;

  /// [geom]（WGS84）の頂点に [dims] の Z・M を付ける。[original] は書き換える前の形（WGS84、Z・M 付き）。
  /// 2D のレイヤ（[LayerDims.isXY]）はそのまま返す
  static Future<geo.Geometry> apply(
    geo.Geometry geom,
    LayerDims dims, {
    geo.Geometry? original,
    ElevationLookup? elevation,
    String context = '',
  }) async {
    if (dims.isXY) return geom;
    final hasZ = dims.hasZ;
    final hasM = dims.hasMFor(original);
    if (!hasZ && !hasM) return geom;

    final index = original == null ? null : _PositionIndex(_positions(original).toList());
    final src = _positions(geom).toList();
    final zs = List<double?>.filled(src.length, null);
    final ms = List<double?>.filled(src.length, null);
    final needDem = <int>[];
    for (var i = 0; i < src.length; i++) {
      final p = src[i];
      final hit = index?.find(p.x, p.y);
      if (hasZ) {
        zs[i] = p.optZ ?? hit?.optZ;
        if (zs[i] == null) needDem.add(i);
      }
      if (hasM) ms[i] = p.optM ?? hit?.optM ?? 0;
    }

    if (needDem.isNotEmpty) {
      final lookup = elevation ?? elevationLookup;
      List<double?> found = const [];
      if (lookup != null) {
        try {
          found = await lookup([for (final i in needDem) (src[i].x, src[i].y)]).timeout(const Duration(seconds: 30));
        } catch (e) {
          AppLogger.debug('[VertexZ] 標高を引けない（$context）: $e');
        }
      }
      var missing = 0;
      for (var k = 0; k < needDem.length; k++) {
        final v = k < found.length ? found[k] : null;
        if (v == null || !v.isFinite) missing++;
        zs[needDem[k]] = (v == null || !v.isFinite) ? 0 : v;
      }
      if (missing > 0) {
        AppLogger.debug('[VertexZ] 標高が引けない頂点 $missing / ${needDem.length} 点の Z を 0 にした（$context）');
      }
    }

    var k = 0;
    return _mapPositions(geom, (p) {
      final i = k++;
      return geo.Geographic(lon: p.x, lat: p.y, elev: hasZ ? zs[i] : null, m: hasM ? ms[i] : null);
    });
  }
}

/// 位置で引く索引（格子で分けて近傍だけ見る）
class _PositionIndex {
  _PositionIndex(List<geo.Position> positions) {
    for (final p in positions) {
      _cells.putIfAbsent(_key(_cell(p.x), _cell(p.y)), () => []).add(p);
    }
  }

  static const _cellDeg = 1e-6;
  final Map<int, List<geo.Position>> _cells = {};

  static int _cell(double v) => (v / _cellDeg).floor();
  static int _key(int cx, int cy) => cx * 73856093 ^ cy * 19349663;

  geo.Position? find(double x, double y) {
    final cx = _cell(x), cy = _cell(y);
    geo.Position? best;
    var bestD = double.infinity;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final p in _cells[_key(cx + dx, cy + dy)] ?? const <geo.Position>[]) {
          final d = (p.x - x).abs() + (p.y - y).abs();
          if (d <= VertexZ.epsilonDeg && d < bestD) {
            best = p;
            bestD = d;
          }
        }
      }
    }
    return best;
  }
}

/// 全頂点（並びは [_mapPositions] と同じ）
Iterable<geo.Position> _positions(geo.Geometry geom) sync* {
  if (geom is geo.Point) {
    yield geom.position;
  } else if (geom is geo.MultiPoint) {
    yield* geom.positions;
  } else if (geom is geo.LineString) {
    yield* geom.chain.positions;
  } else if (geom is geo.MultiLineString) {
    for (final c in geom.chains) {
      yield* c.positions;
    }
  } else if (geom is geo.Polygon) {
    for (final r in geom.rings) {
      yield* r.positions;
    }
  } else if (geom is geo.MultiPolygon) {
    for (final poly in geom.polygons) {
      for (final r in poly.rings) {
        yield* r.positions;
      }
    }
  }
}

/// 形はそのままで頂点だけ [f] で置き換える（[_positions] の順に呼ぶ）
geo.Geometry _mapPositions(geo.Geometry geom, geo.Position Function(geo.Position) f) {
  geo.PositionSeries series(geo.PositionSeries s) => geo.PositionSeries.from([for (final p in s.positions) f(p)]);
  if (geom is geo.Point) return geo.Point(f(geom.position));
  if (geom is geo.MultiPoint) return geo.MultiPoint([for (final p in geom.positions) f(p)]);
  if (geom is geo.LineString) return geo.LineString(series(geom.chain));
  if (geom is geo.MultiLineString) return geo.MultiLineString([for (final c in geom.chains) series(c)]);
  if (geom is geo.Polygon) return geo.Polygon([for (final r in geom.rings) series(r)]);
  if (geom is geo.MultiPolygon) {
    return geo.MultiPolygon([
      for (final poly in geom.polygons) [for (final r in poly.rings) series(r)],
    ]);
  }
  return geom;
}
