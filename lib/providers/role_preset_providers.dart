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

/// 用途プリセット（[RolePreset]）および UI 個別表示設定（[UiVisibilityConfig]）の Riverpod プロバイダ
library;

import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/role_preset.dart';
import '../screens/terrain_settings_screen.dart';
import '../services/basemap_service.dart';
import '../services/gps_history_recorder.dart';
import '../services/official/official_layer_service.dart';
import '../tutorial/tutorial.dart';
import 'gps_providers.dart';
import 'tool_providers.dart';
import 'ui_state_providers.dart';

part 'role_preset_providers.g.dart';

const String kRolePresetPrefsKey = 'role_preset';
const String kUiVisibilityPrefsKey = 'ui_visibility_config';

/// 画面の道具・メニュー表示フラグ（引き算の個別調整）
@Riverpod(keepAlive: true)
class UiVisibilitySetting extends _$UiVisibilitySetting {
  @override
  UiVisibilityConfig build() => UiVisibilityConfig.allVisible;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kUiVisibilityPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        state = UiVisibilityConfig.fromJson(jsonDecode(raw) as Map);
      }
    } catch (_) {
      state = UiVisibilityConfig.allVisible;
    }
  }

  Future<void> set(UiVisibilityConfig value) async {
    state = value;
    _ensureActiveToolVisible(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kUiVisibilityPrefsKey, jsonEncode(value.toJson()));
  }

  Future<void> updateConfig(UiVisibilityConfig Function(UiVisibilityConfig current) change) =>
      set(change(state));

  /// 非表示になった道具を握っていた場合は安全な移動ツール（Pan）へ戻す（チュートリアル中は除く）
  void _ensureActiveToolVisible(UiVisibilityConfig config) {
    if (ref.read(tutorialProvider) != null) return;
    final currentName = ref.read(currentToolProvider).name;
    final hidden = (currentName == 'Pen' && !config.showPenTool) ||
        (currentName == 'GPS' && !config.showGpsTool) ||
        (currentName == 'Measure' && !config.showMeasureTool);
    if (hidden) {
      ref.read(currentToolProvider.notifier).set(ref.read(panToolProvider));
    }
  }
}

/// 現在選ばれている用途プリセットとレシピ一括適用
@Riverpod(keepAlive: true)
class RolePresetSetting extends _$RolePresetSetting {
  @override
  RolePreset build() => RolePreset.standard;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = RolePreset.parse(prefs.getString(kRolePresetPrefsKey));
    } catch (_) {
      state = RolePreset.standard;
    }
  }

  /// [preset] のレシピ（UI 表示・背景地図・公式データ・3D 精度・GNSS/軌跡設定）を一括反映する
  Future<void> apply(
    RolePreset preset, {
    BaseMapService? baseMapService,
    OfficialLayerService? officialLayerService,
  }) async {
    state = preset;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kRolePresetPrefsKey, preset.code);

    final recipe = preset.recipe;

    // 1. UI 引き算設定（隠された道具を握っていれば Pan に戻す）
    await ref.read(uiVisibilitySettingProvider.notifier).set(recipe.ui);

    // 2. 3D 地形の高精度設定（10m 軽量 vs 0.25m〜1m 高精度）
    await terrainSettings.load();
    await terrainSettings.setBool(terrainHighPrecisionDef, recipe.highPrecisionTerrain);
    syncTerrainAppearance();

    // 3. GNSS 品質足切りと軌跡記録の間引き設定
    await ref.read(gnssQualityGateSettingProvider.notifier).set(recipe.gnssQualityGate);
    await ref.read(trackRecordingSettingProvider.notifier).set(recipe.trackRecording);
    GpsHistoryRecorder().filter.settings = recipe.trackRecording;

    // 4. 背景地図レイヤの積み重ね
    final bm = baseMapService ?? BaseMapService();
    await bm.reloadSettingsFromPrefs();
    await bm.setLayers(recipe.basemapLayers);

    // 5. System（sys）の公式データレイヤ（不要なレイヤは外して通信を抑える）
    final official = officialLayerService ?? OfficialLayerService.instance;
    final root = ref.read(folderTreeProvider);
    await official.setEnabledLayers(recipe.officialLayerIds, root: root);
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
  }
}
