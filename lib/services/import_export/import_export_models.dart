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
// Root Maps: Import/Export Models
// ファイル形式定義とインポート/エクスポート結果クラス
import '../../../models/nodes/layer_node.dart';
import '../coordinate/epsg_registry.dart';

/// ファイル形式の種類
enum FileFormat {
  shapefile('Shapefile', '.shp', isImportSupported: true, isExportSupported: true),
  geojson('GeoJSON', '.geojson', isImportSupported: true, isExportSupported: true),
  kml('KML', '.kml', isExportSupported: true),
  csv('CSV', '.csv', isExportSupported: true),
  gpx('GPX', '.gpx'), // 将来実装予定
  unknown('Unknown', '');

  const FileFormat(this.value, this.extension, {this.isImportSupported = false, this.isExportSupported = false});

  /// 表示名
  final String value;

  /// 形式に対応する拡張子（`.` 付き）
  final String extension;

  /// 読み込み対応か
  final bool isImportSupported;

  /// 書き出し対応か
  final bool isExportSupported;

  /// ファイル拡張子（`.` 付き・大小は問わない）から形式を判定。`.json` も GeoJSON
  static FileFormat fromExtension(String extension) {
    final ext = extension.toLowerCase();
    if (ext == '.json') return FileFormat.geojson;
    return FileFormat.values.firstWhere(
      (f) => f != FileFormat.unknown && f.extension == ext,
      orElse: () => FileFormat.unknown,
    );
  }
}

/// Import/Export結果の情報
class ImportExportResult {
  final bool success;
  final String? errorMessage;
  final List<LayerNode>? createdLayers;
  final Map<String, dynamic>? metadata;

  ImportExportResult({
    required this.success,
    this.errorMessage,
    this.createdLayers,
    this.metadata,
  });

  factory ImportExportResult.success({
    LayerNode? createdLayer,
    List<LayerNode>? createdLayers,
    Map<String, dynamic>? metadata,
  }) {
    final layers = createdLayers ?? (createdLayer != null ? [createdLayer] : null);
    return ImportExportResult(
      success: true,
      createdLayers: layers,
      metadata: metadata,
    );
  }

  factory ImportExportResult.error(String message) {
    return ImportExportResult(success: false, errorMessage: message);
  }
}

/// エクスポートオプション
/// CRS選択やその他のエクスポート設定を保持
class ExportOptions {
  /// 出力先のCRS（nullの場合はWGS84）
  final EpsgDefinition? targetCrs;

  /// ポイントクラウドに変換するか（Shapefile用）
  final bool convertToPointCloud;

  /// 行番号を出力カラムに含めるか（属性テーブルの仮想カラム# に相当）
  final bool includeRowNumber;

  const ExportOptions({
    this.targetCrs,
    this.convertToPointCloud = false,
    this.includeRowNumber = false,
  });

  /// WGS84かどうか判定
  bool get isWgs84 => targetCrs == null || targetCrs!.code == 'EPSG:4326';
}
