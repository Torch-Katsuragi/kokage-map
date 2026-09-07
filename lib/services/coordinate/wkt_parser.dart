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
// Root Maps: WKT座標系解析クラス
// WKT文字列からEPSGコードとProj4定義を解析
// Shapefileの.prjファイル読み込み等で使用

import '../../utils/app_logger.dart';
import 'epsg_registry.dart';

/// WKT座標系解析クラス
class WktParser {
  static final WktParser instance = WktParser._internal();
  factory WktParser() => instance;
  WktParser._internal();

  /// EPSGレジストリへの参照
  EpsgRegistry get registry => EpsgRegistry.instance;

  /// WKT文字列から座標系定義を解析
  EpsgDefinition? parseWkt(String wkt) {
    try {
      AppLogger.debug('[WktParser] WKT解析開始: ${wkt.length}文字');

      // Step 1: WKTからEPSGコードを直接抽出
      final epsgCode = extractEpsgCode(wkt);
      if (epsgCode != null) {
        AppLogger.debug('[WktParser] EPSGコード抽出成功: $epsgCode');
        final definition = registry.getByCode(epsgCode);
        if (definition != null) {
          return definition;
        }
      }

      // Step 2: 投影法パラメータから推定
      final inferredDefinition = _inferProjectionFromWkt(wkt);
      if (inferredDefinition != null) {
        AppLogger.debug('[WktParser] 投影法推定成功: ${inferredDefinition.code}');
        return inferredDefinition;
      }

      // Step 3: フォールバック（WGS84）
      AppLogger.debug('[WktParser] フォールバック: WGS84');
      return registry.getByCode('EPSG:4326');
    } catch (e) {
      AppLogger.debug('[WktParser] WKT解析エラー: $e');
      return null;
    }
  }

  /// WKT文字列からEPSGコードを抽出
  /// AUTHORITY["EPSG","XXXX"] または EPSG:XXXX 表記を検出、なければnull
  static String? extractEpsgCode(String wkt) {
    // AUTHORITY["EPSG","XXXX"] パターン
    final authorityPattern = RegExp(r'AUTHORITY\["EPSG","(\d+)"\]');
    final match = authorityPattern.firstMatch(wkt);
    if (match != null) {
      return 'EPSG:${match.group(1)}';
    }

    // EPSG:XXXX 直接パターン
    final directPattern = RegExp(r'EPSG[:\s]*(\d+)');
    final directMatch = directPattern.firstMatch(wkt);
    if (directMatch != null) {
      return 'EPSG:${directMatch.group(1)}';
    }

    return null;
  }

  /// WKTから投影法を推定
  EpsgDefinition? _inferProjectionFromWkt(String wkt) {
    final wktUpper = wkt.toUpperCase();

    // UTMゾーンを検出
    final utmMatch = RegExp(r'UTM.*ZONE.*(\d+)').firstMatch(wktUpper);
    if (utmMatch != null) {
      final zone = int.tryParse(utmMatch.group(1) ?? '');
      if (zone != null && zone >= 1 && zone <= 60) {
        return registry.getUtmZoneDefinition(zone);
      }
    }

    // 日本の平面直角座標系を検出
    if (wktUpper.contains('JAPAN') || wktUpper.contains('JGD')) {
      // 中心経度から系を推定
      final lonMatch = RegExp(r'Central_Meridian[",\s]+(\d+\.?\d*)').firstMatch(wkt);
      if (lonMatch != null) {
        final centralMeridian = double.tryParse(lonMatch.group(1) ?? '');
        if (centralMeridian != null) {
          final definition = _getJgdFromCentralMeridian(centralMeridian);
          if (definition != null) return definition;
        }
      }

      // デフォルトでVI系（近畿圏）を返す
      return registry.getByCode('EPSG:6674');
    }

    // Web Mercator
    if (wktUpper.contains('PSEUDO') && wktUpper.contains('MERCATOR')) {
      return registry.getByCode('EPSG:3857');
    }

    // 地理座標系（WGS84）
    if (wktUpper.contains('WGS') && wktUpper.contains('84')) {
      return registry.getByCode('EPSG:4326');
    }

    return null;
  }

  /// 中心経度からJGD2011座標系を取得
  EpsgDefinition? _getJgdFromCentralMeridian(double lon) {
    // 中心経度とEPSGコードのマッピング（リスト形式）
    const meridianMappings = [
      (129.5, 'EPSG:6669'),   // I系
      (131.0, 'EPSG:6670'),   // II系
      (132.167, 'EPSG:6671'), // III系
      (133.5, 'EPSG:6672'),   // IV系
      (134.333, 'EPSG:6673'), // V系
      (136.0, 'EPSG:6674'),   // VI系
      (137.167, 'EPSG:6675'), // VII系
      (138.5, 'EPSG:6676'),   // VIII系
      (139.833, 'EPSG:6677'), // IX系
      (140.833, 'EPSG:6678'), // X系
      (140.25, 'EPSG:6679'),  // XI系
      (142.25, 'EPSG:6680'),  // XII系
      (144.25, 'EPSG:6681'),  // XIII系
      (142.0, 'EPSG:6682'),   // XIV系
      (127.5, 'EPSG:6683'),   // XV系
      (124.0, 'EPSG:6684'),   // XVI系
      (154.0, 'EPSG:6687'),   // XIX系
    ];

    // 最も近い経度を探す
    double minDiff = double.infinity;
    String? bestCode;
    
    for (final (meridian, code) in meridianMappings) {
      final diff = (meridian - lon).abs();
      if (diff < minDiff) {
        minDiff = diff;
        bestCode = code;
      }
    }

    if (bestCode != null && minDiff < 1.0) {
      return registry.getByCode(bestCode);
    }

    return null;
  }
}
