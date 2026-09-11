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
// こかげマップ: レイヤスタイル設定（グローバル＋View 固有）を MapSourceManager に落とす

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/map_style_group.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../providers/ui_state_providers.dart';
import '../../layer_style_settings_screen.dart'
    show
        layerStyleSettings,
        pointSizeDef,
        pointColorDef,
        lineWidthDef,
        lineColorDef,
        polygonBorderWidthDef,
        polygonBorderColorDef,
        polygonFillColorDef,
        polygonFillOpacityDef,
        polygonBorderOpacityDef;
import '../map_page_state_base.dart';

mixin MapStyleMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  /// View（とレイヤ）に固有のスタイルを、描画用のグループに落とす。
  ///
  /// > [!IMPORTANT] 「グローバル設定にKMetaを重ねる」規則はここにしか無い
  /// > `SettingsStore.resolveXxx(def, kmeta)` が合成を担当する。
  /// > `MapSourceManager` には解決済みの値だけを渡し、設定の知識を持ち込まない。
  ///
  /// 固有スタイルが1つも無ければ空リストを返す。そのとき描画は
  /// View 導入前とまったく同じになる。
  List<MapStyleGroup> buildStyleGroups() {
    final style = layerStyleSettings;
    final groups = <MapStyleGroup>[];
    final seen = <String>{};

    // 可視レイヤを、ツリーの並び（＝z順の根拠）で辿る
    final tree = ref.read(folderTreeProvider);
    final layers = tree == null
        ? const <LayerNode>[]
        : tree.getVisibleLayerNodes().whereType<LayerNode>();

    for (final layer in layers) {
      for (final entry in layer.styleGroups.entries) {
        if (!seen.add(entry.key)) continue;
        final kmeta = entry.value;
        groups.add(
          MapStyleGroup(
            key: entry.key,
            fillHex: colorToHex(
              style.resolveColor(polygonFillColorDef, kmeta),
            ),
            fillOpacity: style.resolveDouble(polygonFillOpacityDef, kmeta),
            outlineHex: colorToHex(
              style.resolveColor(polygonBorderColorDef, kmeta),
            ),
            outlineOpacity: style.resolveDouble(polygonBorderOpacityDef, kmeta),
            borderWidth: style.resolveDouble(polygonBorderWidthDef, kmeta),
            lineHex: colorToHex(
              style.resolveColor(lineColorDef, kmeta),
            ),
            lineWidth: style.resolveDouble(lineWidthDef, kmeta),
            pointHex: colorToHex(
              style.resolveColor(pointColorDef, kmeta),
            ),
            pointSize: style.resolveDouble(pointSizeDef, kmeta),
          ),
        );
      }
    }
    return groups;
  }

  /// レイヤスタイル設定をMapSourceManagerに反映
  ///
  /// [groups] を渡せば View 固有スタイルの再計算を省く（`_syncFeatureSources` が
  /// 直前に組んだものをそのまま使う）
  void applyLayerStyles({List<MapStyleGroup>? groups}) {
    // View 固有スタイルの束を持ち直す。全体設定の値は 3D 地図面（TerrainMapLayer）が layerStyleSettings から直接読む
    setStyleGroups(groups ?? buildStyleGroups());
    terrainSceneRevision.value++;
  }
}
