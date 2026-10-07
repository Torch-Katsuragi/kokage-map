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
// Root Maps: WKT座標系解析
// WKT文字列（Shapefileの.prj等）からEPSGコードと座標系定義を推定する

import '../../utils/app_logger.dart';
import 'epsg_registry.dart';
import 'projections.dart';

abstract final class WktParser {
  /// WKT文字列からEPSGコードを抽出
  /// AUTHORITY["EPSG","XXXX"] または EPSG:XXXX 表記を検出、なければnull
  static String? extractEpsgCode(String wkt) {
    final authority = RegExp(r'AUTHORITY\["EPSG","(\d+)"\]').firstMatch(wkt);
    if (authority != null) return 'EPSG:${authority.group(1)}';

    final direct = RegExp(r'EPSG[:\s]*(\d+)').firstMatch(wkt);
    if (direct != null) return 'EPSG:${direct.group(1)}';

    return null;
  }

  /// WKT文字列から座標系定義を推定する
  ///
  /// 1. EPSGコードがありレジストリに載っていればその定義
  /// 2. proj4dart が WKT を読めれば WKT をそのまま定義にする
  /// 3. 投影法・測地系のキーワードから proj4 文字列を組み立てる
  /// 4. 日本の座標系らしければ JGD2000 VI系、それ以外は WGS84
  static EpsgDefinition toEpsgDefinition(String wkt) {
    final registry = EpsgRegistry.instance;
    final epsgCode = extractEpsgCode(wkt);
    if (epsgCode != null) {
      final known = registry.getByCode(epsgCode);
      if (known != null) return known;
    }

    if (Projections.parse(wkt) != null) {
      return EpsgDefinition(
        code: epsgCode ?? 'WKT',
        name: epsgCode ?? 'WKT Projection',
        proj4String: wkt,
      );
    }

    final proj4String = _toProj4String(wkt);
    if (proj4String != null && Projections.parse(proj4String) != null) {
      return EpsgDefinition(
        code: epsgCode ?? 'CONVERTED',
        name: epsgCode ?? 'Converted Projection',
        proj4String: proj4String,
      );
    }

    if (wkt.toUpperCase().contains('JAPAN')) {
      AppLogger.debug('[WktParser] 日本の座標系と推定: JGD2000 / VI系 (EPSG:2448)');
      return registry.getByCode('EPSG:2448')!;
    }
    AppLogger.debug('[WktParser] フォールバック: WGS 84 (EPSG:4326)');
    return registry.getByCode('EPSG:4326')!;
  }

  /// WKTのキーワードからproj4文字列を組み立てる（簡易版）
  static String? _toProj4String(String wkt) {
    final String projType;
    if (wkt.contains('Transverse_Mercator')) {
      projType = '+proj=tmerc';
    } else if (wkt.contains('Mercator')) {
      projType = '+proj=merc';
    } else if (wkt.contains('Lambert_Conformal_Conic')) {
      projType = '+proj=lcc';
    } else if (wkt.contains('Albers')) {
      projType = '+proj=aea';
    } else if (wkt.contains('UTM')) {
      final zone = RegExp(r'UTM.*zone.*(\d+)').firstMatch(wkt)?.group(1);
      if (zone == null) return null;
      return '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs';
    } else {
      projType = '+proj=longlat';
    }

    final parts = <String>[projType];
    if (wkt.contains('WGS_1984') || wkt.contains('WGS84')) {
      parts.add('+datum=WGS84');
    } else if (wkt.contains('GRS80') || wkt.contains('JGD')) {
      parts.add('+ellps=GRS80');
    }
    if (wkt.contains('metre') || wkt.contains('meter')) {
      parts.add('+units=m');
    }
    parts.add('+no_defs');
    return parts.join(' ');
  }
}
