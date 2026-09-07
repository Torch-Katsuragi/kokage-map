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
// Root Maps: Import/Export Service (Facade)
// インポート/エクスポート処理のファサード（軽量なエントリポイント）
import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';

import '../../i18n/strings.g.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_node.dart';
import 'exporters/base_exporter.dart';
import 'exporters/csv_exporter.dart';
import 'exporters/geojson_exporter.dart';
import 'exporters/kml_exporter.dart';
import 'exporters/shapefile_exporter.dart';
import 'import_export_models.dart';
import 'importers/base_importer.dart';
import 'importers/geojson_importer.dart';
import 'importers/shapefile_importer.dart';

export 'coordinate_system_manager.dart';
export 'exporters/base_exporter.dart';
export 'exporters/csv_exporter.dart';
export 'exporters/geojson_exporter.dart';
export 'exporters/kml_exporter.dart';
export 'exporters/shapefile_exporter.dart';
// モジュール全体を再エクスポート
export 'import_export_models.dart';
export 'importers/base_importer.dart';
export 'importers/geojson_importer.dart';
export 'importers/shapefile_importer.dart';
export 'parsers/dbf_reader.dart';
export 'parsers/prj_reader.dart';
export 'parsers/shapefile_binary_parser.dart';

/// インポート/エクスポートサービスのファサード
/// 各インポーター/エクスポーターを統合し、シンプルなAPIを提供
class ImportExportService {
  /// シングルトンインスタンス
  static final ImportExportService _instance = ImportExportService._internal();
  factory ImportExportService() => _instance;
  ImportExportService._internal();

  /// 利用可能なインポーター
  final List<BaseImporter> _importers = [
    ShapefileImporter(),
    GeoJSONImporter(),
  ];

  /// 利用可能なエクスポーター
  final List<BaseExporter> _exporters = [
    ShapefileExporter(),
    GeoJSONExporter(),
    CSVExporter(),
    KMLExporter(),
  ];

  /// ファイルパスからファイル形式を判定
  FileFormat detectFormat(String filePath) {
    final extension = p.extension(filePath).toLowerCase();
    return FileFormat.fromExtension(extension);
  }

  /// ファイルをインポート
  /// [filePath] インポート対象のファイルパス
  /// [targetGeoPackage] インポート先のGeoPackageNode
  /// [layerName] 作成するレイヤ名（省略時はファイル名から自動生成）
  Future<ImportExportResult> importFile(
    String filePath,
    GeoPackageNode targetGeoPackage, {
    String? layerName,
  }) async {
    try {
      AppLogger.debug('[ImportExportService] インポート開始: $filePath');

      final extension = p.extension(filePath).toLowerCase();
      
      // 適切なインポーターを検索
      final importer = _importers.firstWhere(
        (i) => i.canHandle(extension),
        orElse: () => throw UnsupportedError(
          t.importExport.unsupportedFormat(ext: extension),
        ),
      );

      AppLogger.debug('[ImportExportService] インポーター: ${importer.format.value}');
      
      return await importer.import(
        filePath,
        targetGeoPackage,
        layerName: layerName,
      );
    } catch (e) {
      AppLogger.debug('[ImportExportService] インポートエラー: $e');
      return ImportExportResult.error(t.importExport.importFailed(error: e.toString()));
    }
  }

  /// レイヤをエクスポート
  /// [layer] エクスポート対象のレイヤ
  /// [outputPath] 出力先ファイルパス
  /// [format] 出力形式（省略時はパスの拡張子から自動判定）
  /// [options] エクスポートオプション（CRS選択等）
  Future<ImportExportResult> exportLayer(
    LayerNode layer,
    String outputPath, {
    FileFormat? format,
    ExportOptions options = const ExportOptions(),
  }) async {
    try {
      final crsInfo = options.targetCrs?.code ?? 'WGS84';
      AppLogger.debug('[ImportExportService] エクスポート開始: ${layer.layerName} (CRS: $crsInfo)');

      // 出力形式を決定
      final targetFormat = format ?? detectFormat(outputPath);
      
      if (!targetFormat.isExportSupported) {
        return ImportExportResult.error(
          t.importExport.exportUnsupported(format: targetFormat.value),
        );
      }

      // 適切なエクスポーターを検索
      final exporter = _exporters.firstWhere(
        (e) => e.format == targetFormat,
        orElse: () => throw UnsupportedError(
          t.importExport.unsupportedExportFormat(format: targetFormat.value),
        ),
      );

      AppLogger.debug('[ImportExportService] エクスポーター: ${exporter.format.value}');
      
      return await exporter.export(layer, outputPath, options: options);
    } catch (e) {
      AppLogger.debug('[ImportExportService] エクスポートエラー: $e');
      return ImportExportResult.error(t.importExport.exportFailed(error: e.toString()));
    }
  }

  /// サポートされているインポート形式のリストを取得
  List<FileFormat> getSupportedImportFormats() {
    return _importers.map((i) => i.format).toList();
  }

  /// サポートされているエクスポート形式のリストを取得
  List<FileFormat> getSupportedExportFormats() {
    return _exporters.map((e) => e.format).toList();
  }

  /// 指定された形式がインポート可能か判定
  bool canImport(String extension) {
    return _importers.any((i) => i.canHandle(extension));
  }

  /// 指定された形式がエクスポート可能か判定
  bool canExport(FileFormat format) {
    return _exporters.any((e) => e.format == format);
  }

  // ============================================
  // 後方互換性のためのメソッド
  // ============================================

  /// サポートされているインポート拡張子のリストを取得
  /// 後方互換性のために維持
  List<String> getSupportedImportExtensions() {
    final extensions = <String>[];
    for (final importer in _importers) {
      extensions.add(importer.format.extension);
      // GeoJSONは.jsonもサポート
      if (importer.format == FileFormat.geojson) {
        extensions.add('.json');
      }
    }
    return extensions;
  }

  /// 現在のレイヤーからファイルをインポート
  /// 後方互換性のために維持（GeoPackageNodeが必要）
  /// [filePath] インポート対象のファイルパス
  /// [targetGeoPackage] インポート先のGeoPackageNode（nullの場合はエラー）
  Future<ImportExportResult> importFileFromCurrentLayer(
    String filePath,
    GeoPackageNode? targetGeoPackage,
  ) async {
    if (targetGeoPackage == null) {
      return ImportExportResult.error('GeoPackageNodeが指定されていません');
    }
    return importFile(filePath, targetGeoPackage);
  }
}

