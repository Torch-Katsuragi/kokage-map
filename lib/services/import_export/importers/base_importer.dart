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
// Root Maps: Base Importer
// インポーターの抽象基底クラス
import '../../../models/nodes/geopackage_node.dart';
import '../import_export_models.dart';

/// インポーターの抽象基底クラス
abstract class BaseImporter {
  /// この形式のファイルを処理できるか判定
  bool canHandle(String extension);

  /// サポートするファイル形式
  FileFormat get format;

  /// ファイルをインポート
  /// [filePath] インポート対象のファイルパス
  /// [targetGeoPackage] インポート先のGeoPackageNode
  /// [layerName] 作成するレイヤ名（省略時はファイル名から自動生成）
  Future<ImportExportResult> import(
    String filePath,
    GeoPackageNode targetGeoPackage, {
    String? layerName,
  });
}

