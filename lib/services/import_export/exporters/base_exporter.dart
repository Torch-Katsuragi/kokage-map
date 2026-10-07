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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show protected;
import 'package:latlong2/latlong.dart';

import '../../../models/geometry_type.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../utils/app_logger.dart';
import '../../coordinate/gpkg_crs_resolver.dart';
import '../import_export_models.dart';
import 'feature_parts.dart';

/// 書き出すレイヤの中身。地物は GeoPackage の行そのまま（`geom` 列は [parts] で形にする）
class ExportSource {
  ExportSource(this.layer, this.features, this.geometryType, this.crs);

  final LayerNode layer;
  final List<Map<String, dynamic>> features;
  final GeometryType? geometryType;

  /// レイヤの CRS（形は WGS84 に直して取り出す）
  final GpkgCrsInfo crs;

  /// [feature] の形（[featureParts]）。種類の分からないレイヤでは null
  List<List<LatLng>>? parts(Map<String, dynamic> feature) =>
      geometryType == null ? null : featureParts(feature, geometryType!, crs);
}

/// エクスポーターの抽象基底クラス。
///
/// 地物の読み込み・空のレイヤの扱い・失敗の結果は共通で、形式ごとの書き方だけを [write] に持つ
abstract class BaseExporter {
  /// サポートするファイル形式
  FileFormat get format;

  String get _tag => '[${format.value}Exporter]';

  /// レイヤをファイルにエクスポート
  /// [layer] エクスポート対象のレイヤ
  /// [outputPath] 出力先ファイルパス
  /// [options] エクスポートオプション（CRS選択等）
  Future<ImportExportResult> export(
    LayerNode layer,
    String outputPath, {
    ExportOptions options = const ExportOptions(),
  }) async {
    try {
      AppLogger.debug('$_tag エクスポート開始: ${layer.layerName}');
      final file = layer.geoPackageNode.geoPackageFile;
      final features = await file.getFeatures(layer.layerName);
      final geometryType = await file.getGeometryType(layer.layerName);
      final crs = await layerCrs(layer);
      if (features.isEmpty) {
        return ImportExportResult.error('No features found in layer: ${layer.layerName}');
      }
      return await write(ExportSource(layer, features, geometryType, crs), outputPath, options);
    } catch (e, stackTrace) {
      AppLogger.debug('$_tag エクスポートエラー: $e');
      AppLogger.debug('$_tag スタックトレース: $stackTrace');
      return ImportExportResult.error('${format.value} export failed: $e');
    }
  }

  /// [source] を [outputPath] に書く。地物は 1 件以上ある
  @protected
  Future<ImportExportResult> write(ExportSource source, String outputPath, ExportOptions options);

  /// 1 本のファイルに書く形式の結果（書いたバイト数も添える）
  @protected
  Future<ImportExportResult> writeSingleFile(
    ExportSource source,
    String outputPath,
    List<int> bytes, {
    required int featureCount,
  }) async {
    await File(outputPath).writeAsBytes(bytes);
    AppLogger.debug('$_tag エクスポート完了: $featureCount個のフィーチャ');
    return ImportExportResult.success(
      metadata: {
        'outputPath': outputPath,
        'featureCount': featureCount,
        'geometryType': source.geometryType?.value,
        'format': format.value,
        'fileSize': bytes.length,
      },
    );
  }

  /// 文字の形式を UTF-8 で書く
  @protected
  Future<ImportExportResult> writeText(
    ExportSource source,
    String outputPath,
    String text, {
    required int featureCount,
  }) => writeSingleFile(source, outputPath, utf8.encode(text), featureCount: featureCount);
}
