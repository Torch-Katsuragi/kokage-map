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
import 'dart:ui' as ui;

import 'basemap_provider.dart';

/// 背景地図レイヤの合成モード（お絵描きソフトのレイヤと同じ語彙。3D のテクスチャ合成では `ui.BlendMode` そのまま）
///
/// web の 2D（feature_editor の MapLibre）はラスタに合成モードが無いので不透明度だけ効く
enum BaseMapBlend {
  normal(ui.BlendMode.srcOver),
  multiply(ui.BlendMode.multiply),
  screen(ui.BlendMode.screen),
  overlay(ui.BlendMode.overlay),
  darken(ui.BlendMode.darken),
  lighten(ui.BlendMode.lighten),
  softLight(ui.BlendMode.softLight),
  hardLight(ui.BlendMode.hardLight),
  difference(ui.BlendMode.difference);

  const BaseMapBlend(this.mode);
  final ui.BlendMode mode;

  static BaseMapBlend parse(String? name) => values.firstWhere((b) => b.name == name, orElse: () => normal);
}

/// 背景地図の 1 レイヤ（松本 2026-09-13「イメージはお絵描きソフトのレイヤ。順番・可視・透明度・合成モード」）
///
/// 並びは [BaseMapService.layers] が持つ（先頭が一番下）。同じプロバイダは 1 枚まで
class BaseMapLayer {
  const BaseMapLayer({
    required this.providerId,
    this.visible = true,
    this.opacity = 100,
    this.blend = BaseMapBlend.normal,
  });

  final String providerId;
  final bool visible;

  /// 0〜100
  final int opacity;
  final BaseMapBlend blend;

  BaseMapProvider? get provider => BaseMapProvider.getProviderById(providerId);

  /// 絵に効くか（見えていて透けきっていない）
  bool get effective => visible && opacity > 0;

  BaseMapLayer copyWith({bool? visible, int? opacity, BaseMapBlend? blend}) => BaseMapLayer(
        providerId: providerId,
        visible: visible ?? this.visible,
        opacity: (opacity ?? this.opacity).clamp(0, 100),
        blend: blend ?? this.blend,
      );

  Map<String, Object?> toJson() => {
        'provider': providerId,
        'visible': visible,
        'opacity': opacity,
        'blend': blend.name,
      };

  static BaseMapLayer? fromJson(Map<String, Object?> j) {
    final id = j['provider'];
    if (id is! String || BaseMapProvider.getProviderById(id) == null) return null;
    return BaseMapLayer(
      providerId: id,
      visible: j['visible'] as bool? ?? true,
      opacity: (j['opacity'] as num? ?? 100).round().clamp(0, 100),
      blend: BaseMapBlend.parse(j['blend'] as String?),
    );
  }

  /// 旧設定（プロバイダ → 重み 0〜100。重みの比で混ぜていた）からの読み替え。
  /// 旧式の実効不透明度 α_i = w_i / (w_1 + … + w_i) をそのまま各レイヤの不透明度にすると同じ絵になる。
  /// 並びはプロバイダ一覧の順（下から）。`contours_vN` は `contours`
  static List<BaseMapLayer> fromLegacyWeights(Map<String, int> weights) {
    final w = <String, int>{};
    for (final e in weights.entries) {
      final id = RegExp(r'^contours_v\d+$').hasMatch(e.key) ? 'contours' : e.key;
      if (e.value > 0 && BaseMapProvider.getProviderById(id) != null) w.putIfAbsent(id, () => e.value);
    }
    final layers = <BaseMapLayer>[];
    var cum = 0;
    for (final p in BaseMapProvider.availableProviders) {
      final v = w[p.id];
      if (v == null) continue;
      cum += v;
      layers.add(BaseMapLayer(providerId: p.id, opacity: (v * 100 / cum).round()));
    }
    return layers;
  }

  @override
  bool operator ==(Object other) =>
      other is BaseMapLayer &&
      other.providerId == providerId &&
      other.visible == visible &&
      other.opacity == opacity &&
      other.blend == blend;

  @override
  int get hashCode => Object.hash(providerId, visible, opacity, blend);

  @override
  String toString() => '$providerId${visible ? '' : '(hidden)'} $opacity% ${blend.name}';
}
