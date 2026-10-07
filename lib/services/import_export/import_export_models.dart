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
  shapefile,
  geojson,
  kml,
  csv,
  gpx,
  unknown;

  /// 各形式の表示名を取得
  String get value {
    switch (this) {
      case FileFormat.shapefile:
        return 'Shapefile';
      case FileFormat.geojson:
        return 'GeoJSON';
      case FileFormat.kml:
        return 'KML';
      case FileFormat.csv:
        return 'CSV';
      case FileFormat.gpx:
        return 'GPX';
      case FileFormat.unknown:
        return 'Unknown';
    }
  }

  /// ファイル拡張子から形式を判定
  static FileFormat fromExtension(String extension) {
    switch (extension.toLowerCase()) {
      case '.shp':
        return FileFormat.shapefile;
      case '.geojson':
      case '.json':
        return FileFormat.geojson;
      case '.kml':
        return FileFormat.kml;
      case '.csv':
        return FileFormat.csv;
      case '.gpx':
        return FileFormat.gpx;
      default:
        return FileFormat.unknown;
    }
  }

  /// 読み込み対応の判定
  bool get isImportSupported {
    switch (this) {
      case FileFormat.shapefile:
        return true;
      case FileFormat.geojson:
        return true;
      case FileFormat.kml:
      case FileFormat.csv:
      case FileFormat.gpx:
        return false; // 将来実装予定
      case FileFormat.unknown:
        return false;
    }
  }

  /// エクスポート対応の判定
  bool get isExportSupported {
    switch (this) {
      case FileFormat.shapefile:
        return true;
      case FileFormat.geojson:
        return true;
      case FileFormat.kml:
        return true;
      case FileFormat.csv:
        return true;
      case FileFormat.gpx:
        return false; // 将来実装予定
      case FileFormat.unknown:
        return false;
    }
  }

  /// 形式に対応する拡張子を取得
  String get extension {
    switch (this) {
      case FileFormat.shapefile:
        return '.shp';
      case FileFormat.geojson:
        return '.geojson';
      case FileFormat.kml:
        return '.kml';
      case FileFormat.csv:
        return '.csv';
      case FileFormat.gpx:
        return '.gpx';
      case FileFormat.unknown:
        return '';
    }
  }
}

/// Import/Export結果の情報
class ImportExportResult {
  final bool success;
  final String? errorMessage;
  final List<LayerNode>? createdLayers;
  final Map<String, dynamic>? metadata;

  /// 後方互換: 最初の作成レイヤを返す
  LayerNode? get createdLayer => createdLayers?.firstOrNull;

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
