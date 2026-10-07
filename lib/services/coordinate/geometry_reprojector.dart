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
// Root Maps: ジオメトリ座標 双方向変換ユーティリティ
// ソースCRS ⇔ WGS84 の座標変換を提供
// proj4dart を使用、Isolateセーフ（pure Dart）

import 'package:geobase/geobase.dart' as geo;
import 'package:proj4dart/proj4dart.dart';

import 'projections.dart';

/// ジオメトリ座標の双方向変換ユーティリティ
class GeometryReprojector {
  /// ソースCRS → WGS84 に変換（読み込み用）
  ///
  /// [geom] 変換元ジオメトリ（ソースCRSの座標値）
  /// [sourceProj] ソースCRSのProjection
  /// [needsAxisSwap] Projection の軸が北から並ぶ（`neu`）とき true（[GpkgCrsInfo.needsAxisSwap]）
  static geo.Geometry reprojectToWgs84(
    geo.Geometry geom,
    Projection sourceProj, {
    bool needsAxisSwap = false,
  }) {
    return _reprojectGeometry(
      geom,
      sourceProj,
      Projections.wgs84,
      needsAxisSwap: needsAxisSwap,
      toWgs84: true,
    );
  }

  /// WGS84 → ターゲットCRS に変換（書き込み用）
  ///
  /// [geom] 変換元ジオメトリ（WGS84のlon/lat）
  /// [targetProj] ターゲットCRSのProjection
  /// [needsAxisSwap] Projection の軸が北から並ぶ（`neu`）とき true（[GpkgCrsInfo.needsAxisSwap]）
  static geo.Geometry reprojectFromWgs84(
    geo.Geometry geom,
    Projection targetProj, {
    bool needsAxisSwap = false,
  }) {
    return _reprojectGeometry(
      geom,
      Projections.wgs84,
      targetProj,
      needsAxisSwap: needsAxisSwap,
      toWgs84: false,
    );
  }

  // ========== 内部実装 ==========

  /// ジオメトリの全座標を変換
  static geo.Geometry _reprojectGeometry(
    geo.Geometry geom,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    if (geom is geo.Point) {
      return _reprojectPoint(geom, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    }
    if (geom is geo.MultiPoint) {
      return _reprojectMultiPoint(geom, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    }
    if (geom is geo.LineString) {
      return _reprojectLineString(geom, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    }
    if (geom is geo.MultiLineString) {
      return _reprojectMultiLineString(geom, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    }
    if (geom is geo.Polygon) {
      return _reprojectPolygon(geom, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    }
    if (geom is geo.MultiPolygon) {
      return _reprojectMultiPolygon(geom, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    }
    // 未対応のジオメトリタイプはそのまま返す
    return geom;
  }

  /// 1つの座標を変換
  ///
  /// [toWgs84] = true の場合: ソースCRS → WGS84 (結果はlon/lat → Geographic)
  /// [toWgs84] = false の場合: WGS84 → ターゲットCRS (結果はメートル等 → Projected)
  ///
  /// 注意: geo.Geographic は lon を [-180,180) に正規化し lat を [-90,90] に
  /// クランプするため、投影座標（メートル値等）を格納してはいけない。
  static geo.Position _transformPosition(
    geo.Position pos,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    double srcX, srcY;

    if (toWgs84 && needsAxisSwap) {
      // 保存は (E, N)。北から並ぶ Projection には (N, E) で渡す
      srcX = pos.y; // Easting
      srcY = pos.x; // Northing
    } else {
      srcX = pos.x;
      srcY = pos.y;
    }

    final result = source.transform(target, Point(x: srcX, y: srcY));

    if (toWgs84) {
      // 結果は地理座標（lon/lat）→ Geographic が正しい
      return geo.Geographic(lon: result.x, lat: result.y);
    }

    // 結果は投影座標（メートル等）→ Projected を使う
    // Geographic に入れると正規化/クランプで値が破壊される
    if (needsAxisSwap) {
      // 北から並ぶ Projection の結果 (N, E) を保存の (E, N) に戻す
      return geo.Projected(x: result.y, y: result.x);
    }
    return geo.Projected(x: result.x, y: result.y);
  }

  /// Positionリストを一括変換
  static List<geo.Position> _transformPositions(
    Iterable<geo.Position> positions,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    return positions
        .map((p) => _transformPosition(p, source, target,
            needsAxisSwap: needsAxisSwap, toWgs84: toWgs84))
        .toList();
  }

  static geo.Point _reprojectPoint(
    geo.Point geom,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    final pos = _transformPosition(geom.position, source, target,
        needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    return geo.Point(pos);
  }

  static geo.MultiPoint _reprojectMultiPoint(
    geo.MultiPoint geom,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    final positions = _transformPositions(geom.positions, source, target,
        needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    // ⚠ Geographic に入れ直すと投影座標（m）が経度の正規化・緯度のクランプで潰れる
    return geo.MultiPoint.from(positions);
  }

  static geo.LineString _reprojectLineString(
    geo.LineString geom,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    final positions = _transformPositions(
        geom.chain.positions, source, target,
        needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    return geo.LineString(geo.PositionSeries.from(positions));
  }

  static geo.MultiLineString _reprojectMultiLineString(
    geo.MultiLineString geom,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    final chains = geom.chains.map((chain) {
      final positions = _transformPositions(chain.positions, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
      return geo.PositionSeries.from(positions);
    }).toList();
    return geo.MultiLineString(chains);
  }

  static geo.Polygon _reprojectPolygon(
    geo.Polygon geom,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    final rings = geom.rings.map((ring) {
      final positions = _transformPositions(ring.positions, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
      return geo.PositionSeries.from(positions);
    }).toList();
    return geo.Polygon(rings);
  }

  static geo.MultiPolygon _reprojectMultiPolygon(
    geo.MultiPolygon geom,
    Projection source,
    Projection target, {
    required bool needsAxisSwap,
    required bool toWgs84,
  }) {
    final reprojectedPolygons = geom.polygons.map((polygon) {
      return _reprojectPolygon(polygon, source, target,
          needsAxisSwap: needsAxisSwap, toWgs84: toWgs84);
    }).toList();
    // ⚠ 座標は Geographic に入れ直さない（投影座標の m が経度の正規化・緯度のクランプで潰れる）
    return geo.MultiPolygon([for (final poly in reprojectedPolygons) poly.rings]);
  }
}
