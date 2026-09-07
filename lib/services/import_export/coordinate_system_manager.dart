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
// Root Maps: Coordinate System Manager
// PRJ(WKT)文字列をEpsgDefinitionに解決する（EPSG定義の正はEpsgRegistry）
import 'package:proj4dart/proj4dart.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../coordinate/epsg_registry.dart';
import '../coordinate/wkt_parser.dart';

/// WKT座標系定義の解析クラス
/// EPSGコードが特定できればEpsgRegistryの定義を返し、
/// できなければWKT/proj4文字列をそのまま保持した定義を返す
class SmartCoordinateSystemManager {
  /// シングルトンインスタンス
  static final SmartCoordinateSystemManager _instance =
      SmartCoordinateSystemManager._internal();
  factory SmartCoordinateSystemManager() => _instance;
  SmartCoordinateSystemManager._internal();

  /// Projectionキャッシュ（EPSGコード / proj4文字列 / WKT文字列がキー）
  final Map<String, Projection> _projectionCache = {};

  /// EPSGレジストリへの参照
  EpsgRegistry get _registry => EpsgRegistry.instance;

  /// WKT文字列から座標系を解析
  Future<EpsgDefinition?> parseWktToCoordinateSystem(String wkt) async {
    try {
      AppLogger.debug('[SmartCRS] WKT座標系解析開始');
      AppLogger.debug('[SmartCRS] WKT文字列長: ${wkt.length}文字');

      // Step 1: WKT文字列からEPSGコードを直接抽出し、レジストリの定義を使用
      final epsgCode = WktParser.extractEpsgCode(wkt);
      if (epsgCode != null) {
        AppLogger.debug('[SmartCRS] WKTからEPSGコード抽出成功: $epsgCode');
        final known = _registry.getByCode(epsgCode);
        if (known != null) {
          AppLogger.debug('[SmartCRS] 既知のEPSG定義を使用: $epsgCode');
          return known;
        }
      }

      // Step 2: proj4dartのWKT解析機能を使用（WKT文字列をそのまま定義として保持）
      try {
        AppLogger.debug('[SmartCRS] proj4dartでWKT直接解析を試行');
        Projection.parse(wkt);
        AppLogger.debug('[SmartCRS] proj4dartWKT解析成功');

        return EpsgDefinition(
          code: epsgCode ?? 'WKT',
          name: epsgCode ?? 'WKT Projection',
          proj4String: wkt,
        );
      } catch (e) {
        AppLogger.debug('[SmartCRS] proj4dartでのWKT解析失敗: $e');
      }

      // Step 3: WKTからProj4文字列への変換を試行（フォールバック）
      final proj4String = _convertWktToProj4String(wkt);
      if (proj4String != null) {
        AppLogger.debug('[SmartCRS] WKT→Proj4変換成功');

        try {
          Projection.parse(proj4String);
          return EpsgDefinition(
            code: epsgCode ?? 'CONVERTED',
            name: epsgCode ?? 'Converted Projection',
            proj4String: proj4String,
          );
        } catch (e) {
          AppLogger.debug('[SmartCRS] 変換されたProj4文字列の解析失敗: $e');
        }
      }

      // Step 4: 最後の手段として投影法タイプから推定
      AppLogger.debug('[SmartCRS] 投影法推定による座標系生成');
      return _inferProjectionFromWkt(wkt);
    } catch (e, stack) {
      AppLogger.debug('[SmartCRS] WKT解析エラー: $e');
      AppLogger.debug('[SmartCRS] スタックトレース: $stack');
      return null;
    }
  }

  /// WKTをProj4文字列に変換（簡易版）
  String? _convertWktToProj4String(String wkt) {
    try {
      // 投影法を抽出
      String? projType;
      if (wkt.contains('Transverse_Mercator')) {
        projType = '+proj=tmerc';
      } else if (wkt.contains('Mercator')) {
        projType = '+proj=merc';
      } else if (wkt.contains('Lambert_Conformal_Conic')) {
        projType = '+proj=lcc';
      } else if (wkt.contains('Albers')) {
        projType = '+proj=aea';
      } else if (wkt.contains('UTM')) {
        // UTMゾーンを抽出
        final utmMatch = RegExp(r'UTM.*zone.*(\d+)').firstMatch(wkt);
        if (utmMatch != null) {
          final zone = utmMatch.group(1);
          return '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs';
        }
      } else {
        // 地理座標系（緯度経度）
        projType = '+proj=longlat';
      }

      if (projType == null) return null;

      // 基本パラメータの構築
      final parts = <String>[projType];

      // 測地系の判定
      if (wkt.contains('WGS_1984') || wkt.contains('WGS84')) {
        parts.add('+datum=WGS84');
      } else if (wkt.contains('GRS80') || wkt.contains('JGD')) {
        parts.add('+ellps=GRS80');
      }

      // 単位
      if (wkt.contains('metre') || wkt.contains('meter')) {
        parts.add('+units=m');
      }

      parts.add('+no_defs');

      return parts.join(' ');
    } catch (e) {
      AppLogger.debug('[SmartCRS] WKT→Proj4変換エラー: $e');
      return null;
    }
  }

  /// WKTから投影法を推定
  /// 日本の座標系らしければJGD2000 VI系、それ以外はWGS84にフォールバック
  EpsgDefinition _inferProjectionFromWkt(String wkt) {
    if (wkt.toUpperCase().contains('JAPAN')) {
      AppLogger.debug('[SmartCRS] 日本の座標系と推定: JGD2000 / VI系 (EPSG:2448)');
      return _registry.getByCode('EPSG:2448')!;
    }
    AppLogger.debug('[SmartCRS] フォールバック: WGS 84 (EPSG:4326)');
    return _registry.getByCode('EPSG:4326')!;
  }

  /// Proj4dartの投影オブジェクトを取得（キャッシュ付き）
  /// [epsgCodeOrProj4String] レジストリ登録済みのEPSGコード、proj4文字列、またはWKT文字列
  Projection? getProjection(String epsgCodeOrProj4String) {
    final cached = _projectionCache[epsgCodeOrProj4String];
    if (cached != null) return cached;

    try {
      // EPSGコードの場合はレジストリの定義を使用
      final registryProj4 = epsgCodeOrProj4String.startsWith('EPSG:')
          ? _registry.getByCode(epsgCodeOrProj4String)?.proj4String
          : null;
      final projection = Projection.parse(registryProj4 ?? epsgCodeOrProj4String);
      _projectionCache[epsgCodeOrProj4String] = projection;
      return projection;
    } catch (e) {
      AppLogger.debug('[SmartCRS] 投影作成エラー: $e');
      return null;
    }
  }

  /// 座標系情報の詳細表示
  void printCoordinateSystemInfo(EpsgDefinition coordinateSystem) {
    AppLogger.debug('[SmartCRS] =====================================');
    AppLogger.debug('[SmartCRS] 座標系情報:');
    AppLogger.debug('[SmartCRS]   名前: ${coordinateSystem.name}');
    AppLogger.debug('[SmartCRS]   EPSGコード: ${coordinateSystem.code}');
    AppLogger.debug('[SmartCRS]   Proj4文字列: ${coordinateSystem.proj4String}');
    AppLogger.debug('[SmartCRS] =====================================');
  }
}

