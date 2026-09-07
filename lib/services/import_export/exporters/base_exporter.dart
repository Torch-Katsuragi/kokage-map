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
// Root Maps: Base Exporter
// エクスポーターの抽象基底クラス
import '../../../models/nodes/layer_node.dart';
import '../import_export_models.dart';

/// エクスポーターの抽象基底クラス
abstract class BaseExporter {
  /// サポートするファイル形式
  FileFormat get format;

  /// レイヤをファイルにエクスポート
  /// [layer] エクスポート対象のレイヤ
  /// [outputPath] 出力先ファイルパス
  /// [options] エクスポートオプション（CRS選択等）
  Future<ImportExportResult> export(
    LayerNode layer,
    String outputPath, {
    ExportOptions options = const ExportOptions(),
  });
}

