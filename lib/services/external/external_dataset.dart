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
// gpkg 以外の形式を読み取り専用レイヤとして開くときの共通の形
// 設計は docs/technical/external-formats.md

import '../../models/geometry_type.dart';

/// 外部形式のファイルから読んだ 1 レイヤ分のデータ（座標は WGS84 に直してある）
class ExternalDataset {
  const ExternalDataset({
    required this.layerName,
    required this.geometryType,
    required this.columns,
    required this.features,
  });

  /// レイヤ名（shp・GeoJSON なら拡張子を除いたファイル名、KML/KMZ の複数フォルダなら `|layername=` に書く名前）
  final String layerName;

  final GeometryType geometryType;

  /// 列名 → SQLite の型（`TEXT` / `REAL` / `INTEGER`）。並びは元のファイルの列順
  final Map<String, String> columns;

  /// `GeoPackageFile.addPointsBatch` 等にそのまま渡せる形。
  /// 形は点なら `point`（`LatLng`）、線なら `line`（`List<LatLng>`）、面なら `rings`（`List<List<LatLng>>`）に持ち、
  /// 残りのキーが属性
  final List<Map<String, dynamic>> features;
}

/// 外部形式の読み手。ファイルは `fs`（KFileSystem）経由で読む（web でも動くこと。dart:io を使わない）
abstract class ExternalReader {
  /// この読み手が受け持つ拡張子（小文字・点つき。例 `.shp`）
  Set<String> get extensions;

  /// [path] のファイルと一緒に扱う付属ファイルの拡張子（shp の `.dbf` など。小文字・点つき）。
  /// 変換後の削除・更新時刻の判定・Drive 同期に使う。付属ファイルが無い形式は空
  Set<String> get sidecarExtensions => const {};

  /// 読めるかどうかを中身で判定（`.json` が GeoJSON か、`.csv` に座標列があるか等）。既定は true
  Future<bool> accepts(String path) async => true;

  /// [path] を読む。1 ファイルから複数レイヤ（KML のフォルダ・ジオメトリ型の混在）が出ることがある。
  /// 読めなければ例外
  Future<List<ExternalDataset>> read(String path);
}
