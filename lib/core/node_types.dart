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
// Root Maps: ノードタイプの型安全な定義
// 文字列による管理をenumに置き換え、型安全性と拡張性を向上

/// レイヤツリーノードの種別を表すenum
/// 
/// 各ノードタイプは以下のカテゴリに分類される：
/// - コンテナ系: folder, geopackage
/// - データ系: layer, feature
/// - 表現系: view（データではなく「見せ方」。[[docs/technical/project-format-design]]）
/// - メディア系: image
enum NodeType {
  /// フォルダノード（ファイルシステムのディレクトリに対応）
  folder('folder'),
  
  /// GeoPackageノード（.gpkgファイルに対応）
  geopackage('gpkg'),
  
  /// レイヤノード（GeoPackage内のフィーチャテーブルに対応）
  layer('layer'),
  
  /// Viewノード（レイヤに対する「フィルタ＋スタイル」。QGISのレイヤと1:1対応）
  view('view'),
  
  /// フィーチャノード（レイヤ内の個別フィーチャに対応）
  feature('feature'),
  
  /// 画像ノード（位置情報付き画像ファイルに対応）
  image('image');

  /// 文字列表現（後方互換性のため）
  final String value;
  
  const NodeType(this.value);
  
  /// 文字列からNodeTypeへの変換
  /// 不明な値の場合はnullを返す
  static NodeType? fromString(String value) {
    // 後方互換性: "photo" は "image" として扱う
    if (value == 'photo') {
      return NodeType.image;
    }
    
    for (final type in NodeType.values) {
      if (type.value == value) {
        return type;
      }
    }
    return null;
  }
  
  /// 表示用の名前（日本語）
  String get displayName {
    switch (this) {
      case NodeType.folder:
        return 'フォルダ';
      case NodeType.geopackage:
        return 'GeoPackage';
      case NodeType.layer:
        return 'レイヤ';
      case NodeType.view:
        return 'View';
      case NodeType.feature:
        return 'フィーチャ';
      case NodeType.image:
        return '画像';
    }
  }
  
  @override
  String toString() => value;
}
