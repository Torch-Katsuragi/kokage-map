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
/// sub_table属性の読み書き
///
/// ライン/ポリゴンフィーチャの sub_table（頂点ごとの記録。GeoJSON FeatureCollection / 旧2D配列）を
/// 文字列のまま読み書きする。頂点の並びに合わせる処理は editing/edit_session.dart の `remapSubTable`。
library;

import '../../../models/nodes/feature_node.dart';
import '../../../utils/app_logger.dart';

/// sub_table を読み書きするヘルパー
class SubTableHelper {
  /// フィーチャからsub_table JSON文字列を取得する。
  /// 存在しない場合はnullを返す。
  static Future<String?> getSubTableJson(FeatureNode feature) async {
    try {
      final value = await feature.getAttributeValue('sub_table');
      if (value is String && value.isNotEmpty) {
        return value;
      }
    } catch (e) {
      AppLogger.debug('[SubTableHelper] getSubTableJson error: $e');
    }
    return null;
  }

  /// フィーチャのsub_table属性を更新する。
  static Future<void> setSubTableJson(
    FeatureNode feature,
    String subTableJson,
  ) async {
    try {
      await feature.setAttributeValue('sub_table', subTableJson);
      AppLogger.debug('[SubTableHelper] sub_table更新完了');
    } catch (e) {
      AppLogger.debug('[SubTableHelper] setSubTableJson error: $e');
    }
  }
}
