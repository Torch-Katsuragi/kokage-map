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
// WKT文字列からEPSGコードを抽出
// Shapefileの.prjファイル読み込み等で使用

/// WKT座標系解析クラス
class WktParser {
  static final WktParser instance = WktParser._internal();
  factory WktParser() => instance;
  WktParser._internal();

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
}
