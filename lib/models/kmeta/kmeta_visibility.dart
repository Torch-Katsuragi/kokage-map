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
// こかげマップ: フォルダ設定の可視性モデル

/// 可視性設定
class KMetaVisibility {
  /// レイヤーキー（gpkgName/layerName形式） → 可視状態
  final Map<String, bool> layers;

  /// GeoPackageファイル名 → 可視状態
  final Map<String, bool> geopackages;

  /// フォルダ名 → 可視状態
  final Map<String, bool> folders;

  /// 画像ファイル名 → 可視状態
  final Map<String, bool> images;

  /// Viewキー（gpkgName/layerName/viewName形式） → 可視状態
  final Map<String, bool> views;

  const KMetaVisibility({
    this.layers = const {},
    this.geopackages = const {},
    this.folders = const {},
    this.images = const {},
    this.views = const {},
  });

  KMetaVisibility copyWith({
    Map<String, bool>? layers,
    Map<String, bool>? geopackages,
    Map<String, bool>? folders,
    Map<String, bool>? images,
    Map<String, bool>? views,
  }) =>
      KMetaVisibility(
        layers: layers ?? this.layers,
        geopackages: geopackages ?? this.geopackages,
        folders: folders ?? this.folders,
        images: images ?? this.images,
        views: views ?? this.views,
      );

  /// JSONからパース
  factory KMetaVisibility.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaVisibility();
    return KMetaVisibility(
      layers: _parseBoolMap(json['layers']),
      geopackages: _parseBoolMap(json['geopackages']),
      folders: _parseBoolMap(json['folders']),
      images: _parseBoolMap(json['images']),
      views: _parseBoolMap(json['views']),
    );
  }

  static Map<String, bool> _parseBoolMap(dynamic value) {
    if (value is! Map<String, dynamic>) return {};
    return value.map((k, v) => MapEntry(k, v as bool));
  }

  /// JSONへシリアライズ（空の項目は書かない）
  Map<String, dynamic> toJson() => {
    if (layers.isNotEmpty) 'layers': layers,
    if (geopackages.isNotEmpty) 'geopackages': geopackages,
    if (folders.isNotEmpty) 'folders': folders,
    if (images.isNotEmpty) 'images': images,
    if (views.isNotEmpty) 'views': views,
  };

  /// 空かどうか
  bool get isEmpty =>
      layers.isEmpty &&
      geopackages.isEmpty &&
      folders.isEmpty &&
      images.isEmpty &&
      views.isEmpty;
}
