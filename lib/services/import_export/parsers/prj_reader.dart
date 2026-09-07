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
// Root Maps: PRJ Reader
// PRJファイル（座標系定義）の読み込みクラス
import 'dart:io';
import 'package:root_maps/utils/app_logger.dart';
import '../../coordinate/epsg_registry.dart';
import '../coordinate_system_manager.dart';

/// PRJファイルを読み込んで座標系情報を取得するクラス
class PrjReader {
  static final SmartCoordinateSystemManager _crsManager =
      SmartCoordinateSystemManager();

  /// PRJファイルから座標系情報を読み取り
  static Future<EpsgDefinition?> read(String prjFilePath) async {
    try {
      final prjFile = File(prjFilePath);
      if (!prjFile.existsSync()) {
        AppLogger.debug('[PrjReader] PRJファイルが見つかりません: $prjFilePath');
        return null;
      }

      final prjContent = await prjFile.readAsString();
      AppLogger.debug('[PrjReader] PRJファイル読み込み成功');
      AppLogger.debug('[PrjReader] ファイルパス: $prjFilePath');
      AppLogger.debug('[PrjReader] 文字数: ${prjContent.length}文字');

      // スマート座標系マネージャーを使用してWKTを解析
      final coordinateSystem = await _crsManager
          .parseWktToCoordinateSystem(prjContent);

      if (coordinateSystem != null) {
        _crsManager.printCoordinateSystemInfo(coordinateSystem);
        return coordinateSystem;
      } else {
        AppLogger.debug('[PrjReader] スマート座標系解析に失敗');
        return null;
      }
    } catch (e) {
      AppLogger.debug('[PrjReader] PRJファイル読み取りエラー: $e');
      return null;
    }
  }
}

