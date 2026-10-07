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
import 'package:flutter/foundation.dart' show protected;

import '../../../models/geometry_type.dart';
import '../../../models/nodes/geopackage_node.dart';
import '../../../models/nodes/layer_node.dart';
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

  /// 一度に GeoPackage へ書く地物の数
  @protected
  static const batchSize = 1000;

  /// [baseName] が空いていればそのまま、あれば `_1`, `_2`… を付けた名前
  @protected
  Future<String> uniqueLayerName(GeoPackageNode gpkg, String baseName) async {
    final existing = await gpkg.geoPackageFile.getLayerNames();
    if (!existing.contains(baseName)) return baseName;
    var counter = 1;
    while (existing.contains('${baseName}_$counter')) {
      counter++;
    }
    return '${baseName}_$counter';
  }

  /// 属性の値から列の型（SQLite）を決める。数は REAL、真偽は INTEGER、ほかは TEXT
  @protected
  static String sqliteTypeOf(Object? value) => switch (value) {
    num() => 'REAL',
    bool() => 'INTEGER',
    _ => 'TEXT',
  };

  /// 地物をまとめて書く。[batch] の各要素は形を `point` / `line` / `rings` に持つ
  @protected
  Future<void> addBatch(
    GeoPackageNode gpkg,
    String layerName,
    GeometryType geometryType,
    List<Map<String, dynamic>> batch,
  ) async {
    if (batch.isEmpty) return;
    final file = gpkg.geoPackageFile;
    switch (geometryType) {
      case GeometryType.point:
        await file.addPointsBatch(layerName, batch);
      case GeometryType.linestring:
        await file.addLinesBatch(layerName, batch);
      case GeometryType.polygon:
        await file.addPolygonsBatch(layerName, batch);
    }
  }

  /// ツリーを読み直し、[names] のレイヤを返す（gpkg の中の並び順）
  @protected
  Future<List<LayerNode>> reloadLayers(GeoPackageNode gpkg, Iterable<String> names) async {
    await gpkg.updateChildren();
    final wanted = names.toSet();
    return gpkg.children.whereType<LayerNode>().where((l) => wanted.contains(l.layerName)).toList();
  }
}
