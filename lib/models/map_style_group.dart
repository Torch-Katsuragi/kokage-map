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
import 'dart:ui' show Color;

/// フィーチャの GeoJSON に載せるプロパティ名（MapSourceManager から移した。2026-09-11 MapLibre 撤去）
///
/// [kStyleProp] はスタイルグループのキー（View のキー）、[kLabelProp] は解決済みのラベル文字列。
/// 3D 描画系（`TerrainSceneBuilder`）はこれを見て見た目とラベルを決める
const kStyleProp = 'k-style';
const kLabelProp = 'k-label';

/// スタイルグループ 1 つぶんの、解決済みの見た目。
///
/// View（またはレイヤ）に固有のスタイルが付いているぶんだけ作られる。
/// グローバル設定との合成は呼び出し側（`map_page`）が済ませてから渡す。
/// 色は `#RRGGBB` の 16 進（`TerrainFeatureStyle.fromHex` で Flutter の色にする）
class MapStyleGroup {
  const MapStyleGroup({
    required this.key,
    required this.fillHex,
    required this.fillOpacity,
    required this.outlineHex,
    required this.outlineOpacity,
    required this.borderWidth,
    required this.lineHex,
    required this.lineWidth,
    required this.pointHex,
    required this.pointSize,
  });

  /// フィーチャの `k-style` 属性と突き合わせるキー（View のキー）
  final String key;
  final String fillHex;
  final double fillOpacity;
  final String outlineHex;
  final double outlineOpacity;
  final double borderWidth;
  final String lineHex;
  final double lineWidth;
  final String pointHex;
  final double pointSize;

  @override
  bool operator ==(Object other) =>
      other is MapStyleGroup &&
      other.key == key &&
      other.fillHex == fillHex &&
      other.fillOpacity == fillOpacity &&
      other.outlineHex == outlineHex &&
      other.outlineOpacity == outlineOpacity &&
      other.borderWidth == borderWidth &&
      other.lineHex == lineHex &&
      other.lineWidth == lineWidth &&
      other.pointHex == pointHex &&
      other.pointSize == pointSize;

  @override
  int get hashCode => Object.hash(key, fillHex, fillOpacity, outlineHex,
      outlineOpacity, borderWidth, lineHex, lineWidth, pointHex, pointSize);
}

/// Flutter の色を `#RRGGBB`（不透明度は別フィールド）に
String colorToHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// 2 つのリストが同じ並びか
bool styleGroupsEqual(List<MapStyleGroup> a, List<MapStyleGroup> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
