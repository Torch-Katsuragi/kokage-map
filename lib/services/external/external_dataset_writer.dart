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
// 外部形式から読んだデータ（ExternalDataset）を GeoPackage に書く
// 読み取り専用レイヤのキャッシュ作りと、旧来の「取り込み」の両方が使う

import '../../models/geometry_type.dart';
import '../../models/geopackage/geopackage_file.dart';
import 'external_dataset.dart';

/// 属性の値から列の型（SQLite）を決める。数は REAL、真偽は INTEGER、ほかは TEXT
String sqliteTypeOf(Object? value) => switch (value) {
  num() => 'REAL',
  bool() => 'INTEGER',
  _ => 'TEXT',
};

/// GeoPackage 側で使えない列名（主キー・形の列。[FeatureRepository.addGeometries] が黙って捨てる名前）
const _reservedColumns = {'fid', 'geom', 'id', 'rowid', 'geometry'};

/// 列名を GeoPackage に書ける名前にする（予約名なら後ろに `_` を足す）
String externalColumnName(String name) => _reservedColumns.contains(name.toLowerCase()) ? '${name}_' : name;

/// 一度に GeoPackage へ書く地物の数
const _batchSize = 1000;

/// [dataset] を [gpkg] の [layerName]（省略時は [ExternalDataset.layerName]）へ書く。
/// レイヤは新しく作る（同名があってはいけない）。書けた地物の数を返す
Future<int> writeExternalDataset(GeoPackageFile gpkg, ExternalDataset dataset, {String? layerName}) async {
  final name = layerName ?? dataset.layerName;
  await gpkg.addLayer(name, dataset.geometryType);

  final renamed = {for (final c in dataset.columns.keys) c: externalColumnName(c)};
  final schema = {for (final e in dataset.columns.entries) renamed[e.key]!: e.value};
  if (schema.isNotEmpty) await gpkg.addAttributeColumns(name, schema);

  final geometryKey = switch (dataset.geometryType) {
    GeometryType.point => 'point',
    GeometryType.linestring => 'line',
    GeometryType.polygon => 'rings',
  };

  var written = 0;
  final batch = <Map<String, dynamic>>[];
  Future<void> flush() async {
    if (batch.isEmpty) return;
    final ids = switch (dataset.geometryType) {
      GeometryType.point => await gpkg.addPointsBatch(name, batch),
      GeometryType.linestring => await gpkg.addLinesBatch(name, batch),
      GeometryType.polygon => await gpkg.addPolygonsBatch(name, batch),
    };
    written += ids.length;
    batch.clear();
  }

  for (final feature in dataset.features) {
    final row = <String, dynamic>{};
    for (final MapEntry(:key, :value) in feature.entries) {
      if (key == geometryKey) {
        row[key] = value;
      } else {
        // 真偽は 0/1 で書く（列の型は INTEGER）
        row[renamed[key] ?? externalColumnName(key)] = value is bool ? (value ? 1 : 0) : value;
      }
    }
    batch.add(row);
    if (batch.length >= _batchSize) await flush();
  }
  await flush();
  return written;
}
