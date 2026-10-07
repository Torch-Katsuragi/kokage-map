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
// こかげマップ: proj4dart の Projection を定義文字列ごとに 1 回だけ作る
// CRS の定義（proj4 文字列・WKT）から Projection を得るときは必ずここを通す

import 'package:proj4dart/proj4dart.dart';

import '../../utils/app_logger.dart';

abstract final class Projections {
  /// 定義文字列 → Projection。読めなかった定義も null で覚えて、2 度目は読み直さない
  static final Map<String, Projection?> _cache = {};

  /// WGS84（proj4dart の組み込み。Projection.add でも上書きされない）
  static Projection get wgs84 => Projection.WGS84;

  /// proj4 文字列か WKT から Projection を得る。読めなければ null
  static Projection? parse(String definition) {
    if (_cache.containsKey(definition)) return _cache[definition];
    Projection? projection;
    try {
      projection = Projection.parse(definition);
    } catch (e) {
      AppLogger.debug('[Projections] 定義を読めない: $e');
    }
    return _cache[definition] = projection;
  }
}
