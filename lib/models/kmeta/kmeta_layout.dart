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
// こかげマップ: フォルダ設定のレイアウト（並び順・展開状態）と画像オーバーレイ変換パラメータ

/// レイアウト設定
class KMetaLayout {
  /// 子の並び（上から）。フォルダの子は名前、gpkg の中のレイヤは `gpkg名/レイヤ名`。
  /// レイヤ一覧の並びで、描く順でもある（上ほど手前）。QGIS で保存された `.qgs` のレイヤツリーから読み戻す
  final List<String>? sortOrder;

  /// 展開状態
  final bool? expanded;

  const KMetaLayout({this.sortOrder, this.expanded});

  /// JSONからパース
  factory KMetaLayout.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaLayout();
    return KMetaLayout(
      sortOrder: (json['sortOrder'] as List<dynamic>?)?.cast<String>(),
      expanded: json['expanded'] as bool?,
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (sortOrder != null) json['sortOrder'] = sortOrder;
    if (expanded != null) json['expanded'] = expanded;
    return json;
  }

  /// 空かどうか
  bool get isEmpty => sortOrder == null && expanded == null;
}

/// 画像オーバーレイの変換パラメータ
class KMetaImageOverlay {
  /// 画像の中心座標（経度）
  final double centerLng;

  /// 画像の中心座標（緯度）
  final double centerLat;

  /// スケール（メートル/ピクセル）
  final double scale;

  /// 回転角度（度、時計回り）
  final double rotation;

  /// 画像幅（ピクセル）
  final int imageWidth;

  /// 画像高さ（ピクセル）
  final int imageHeight;

  const KMetaImageOverlay({
    required this.centerLng,
    required this.centerLat,
    this.scale = 1.0,
    this.rotation = 0.0,
    required this.imageWidth,
    required this.imageHeight,
  });

  /// JSONからパース
  factory KMetaImageOverlay.fromJson(Map<String, dynamic> json) {
    return KMetaImageOverlay(
      centerLng: (json['centerLng'] as num).toDouble(),
      centerLat: (json['centerLat'] as num).toDouble(),
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      imageWidth: json['imageWidth'] as int,
      imageHeight: json['imageHeight'] as int,
    );
  }

  /// JSONへシリアライズ
  Map<String, dynamic> toJson() {
    return {
      'centerLng': centerLng,
      'centerLat': centerLat,
      'scale': scale,
      'rotation': rotation,
      'imageWidth': imageWidth,
      'imageHeight': imageHeight,
    };
  }

  /// コピーを作成
  KMetaImageOverlay copyWith({
    double? centerLng,
    double? centerLat,
    double? scale,
    double? rotation,
    int? imageWidth,
    int? imageHeight,
  }) {
    return KMetaImageOverlay(
      centerLng: centerLng ?? this.centerLng,
      centerLat: centerLat ?? this.centerLat,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      imageWidth: imageWidth ?? this.imageWidth,
      imageHeight: imageHeight ?? this.imageHeight,
    );
  }
}
