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
// Root Maps: 座標変換サービス
// WGS84 の点を EpsgDefinition の XY に変換する（属性テーブルの XY 列）

import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';

import '../../utils/app_logger.dart';
import 'epsg_registry.dart';
import 'projections.dart';

class CoordinateService {
  static final CoordinateService instance = CoordinateService._internal();
  factory CoordinateService() => instance;
  CoordinateService._internal();

  /// WGS84からXY座標に変換
  /// 戻り値: {'x': double, 'y': double} または変換失敗時はnull
  /// 日本の平面直角座標系は X=Northing, Y=Easting、WGS84 系は x=経度, y=緯度 のまま
  Map<String, double>? transformToXY(LatLng point, EpsgDefinition epsg) {
    if (epsg.isWgs84) {
      return {'x': point.longitude, 'y': point.latitude};
    }
    final target = Projections.parse(epsg.proj4String);
    if (target == null) {
      AppLogger.debug('[CoordinateService] Projection作成失敗: ${epsg.code}');
      return null;
    }
    try {
      final result = Projections.wgs84.transform(
        target,
        Point(x: point.longitude, y: point.latitude),
      );
      if (EpsgRegistry.instance.needsAxisSwap(epsg.code)) {
        return {'x': result.y, 'y': result.x};
      }
      return {'x': result.x, 'y': result.y};
    } catch (e) {
      AppLogger.debug('[CoordinateService] 座標変換エラー: $e');
      return null;
    }
  }

  /// WGS84からXY座標に変換（フォーマット済み文字列）
  /// WGS84 系は小数点以下 6 桁
  Map<String, String> transformToXYFormatted(LatLng point, EpsgDefinition epsg, {int decimals = 3}) {
    final xy = transformToXY(point, epsg);
    if (xy == null) {
      return {'x': 'Error', 'y': 'Error'};
    }
    final d = epsg.isWgs84 ? 6 : decimals;
    return {
      'x': xy['x']!.toStringAsFixed(d),
      'y': xy['y']!.toStringAsFixed(d),
    };
  }
}
