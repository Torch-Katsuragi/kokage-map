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

/// 用途プリセット（猟師・林業従事者・測量業者・土木現場・標準）と UI 引き算設定。
///
/// `MapLayout` と同じく「内部は細かな個別設定を自由に持て、プリセットは現場ごとの最適レシピを一括反映する」設計。
/// プリセット適用後も各ツールの表示／非表示・背景地図・公式データ・3D 精度を個別に変更できる。
library;

import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../models/basemap_layer.dart';
import '../models/gnss_quality.dart';
import '../models/track_recording_settings.dart';

/// 画面に出す道具・ボタン・詳細カテゴリーの個別表示フラグ（引き算の設定）
@immutable
class UiVisibilityConfig {
  const UiVisibilityConfig({
    this.showPenTool = true,
    this.showGpsTool = true,
    this.showMeasureTool = true,
    this.showAttributeTableButton = true,
    this.showAdvancedSettings = true,
  });

  /// すべての道具とカテゴリーを表示する既定値
  static const allVisible = UiVisibilityConfig();

  /// 作図（ペン）ツールを表示するか
  final bool showPenTool;

  /// GPS 記録ツールを表示するか
  final bool showGpsTool;

  /// 計測（距離・面積）ツールを表示するか
  final bool showMeasureTool;

  /// 上部 AppBar の属性テーブルボタンを表示するか
  final bool showAttributeTableButton;

  /// 設定画面の詳細カテゴリー（外部機器・レイヤスタイル）を最初から一覧に出すか
  final bool showAdvancedSettings;

  UiVisibilityConfig copyWith({
    bool? showPenTool,
    bool? showGpsTool,
    bool? showMeasureTool,
    bool? showAttributeTableButton,
    bool? showAdvancedSettings,
  }) =>
      UiVisibilityConfig(
        showPenTool: showPenTool ?? this.showPenTool,
        showGpsTool: showGpsTool ?? this.showGpsTool,
        showMeasureTool: showMeasureTool ?? this.showMeasureTool,
        showAttributeTableButton: showAttributeTableButton ?? this.showAttributeTableButton,
        showAdvancedSettings: showAdvancedSettings ?? this.showAdvancedSettings,
      );

  Map<String, Object?> toJson() => {
        'showPenTool': showPenTool,
        'showGpsTool': showGpsTool,
        'showMeasureTool': showMeasureTool,
        'showAttributeTableButton': showAttributeTableButton,
        'showAdvancedSettings': showAdvancedSettings,
      };

  static UiVisibilityConfig fromJson(Map<dynamic, dynamic> j) => UiVisibilityConfig(
        showPenTool: j['showPenTool'] as bool? ?? true,
        showGpsTool: j['showGpsTool'] as bool? ?? true,
        showMeasureTool: j['showMeasureTool'] as bool? ?? true,
        showAttributeTableButton: j['showAttributeTableButton'] as bool? ?? true,
        showAdvancedSettings: j['showAdvancedSettings'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      other is UiVisibilityConfig &&
      other.showPenTool == showPenTool &&
      other.showGpsTool == showGpsTool &&
      other.showMeasureTool == showMeasureTool &&
      other.showAttributeTableButton == showAttributeTableButton &&
      other.showAdvancedSettings == showAdvancedSettings;

  @override
  int get hashCode => Object.hash(
        showPenTool,
        showGpsTool,
        showMeasureTool,
        showAttributeTableButton,
        showAdvancedSettings,
      );
}

/// オフライン一括ダウンロード画面の既定値レシピ
@immutable
class OfflineDownloadRecipe {
  const OfflineDownloadRecipe({
    required this.defaultRadiusMeters,
    required this.recommendedMaxZoom,
    required this.includeOfficialVectorsByDefault,
  });

  /// 初期半径（m）
  final double defaultRadiusMeters;

  /// 初期スライダーの上限ズーム（不要な高ズーム大量取得を避ける目安。手動で引き上げ可能）
  final int recommendedMaxZoom;

  /// 有効化済みの公式ベクトルタイル（林班界など）を既定でチェックONにするか
  final bool includeOfficialVectorsByDefault;
}

/// 1 つの用途プリセットが一括適用する設定レシピ
@immutable
class RolePresetRecipe {
  const RolePresetRecipe({
    required this.ui,
    required this.basemapLayers,
    required this.officialLayerIds,
    required this.highPrecisionTerrain,
    required this.gnssQualityGate,
    required this.trackRecording,
    required this.download,
  });

  final UiVisibilityConfig ui;
  final List<BaseMapLayer> basemapLayers;
  final List<String> officialLayerIds;
  final bool highPrecisionTerrain;
  final GnssQualityGate gnssQualityGate;
  final TrackRecordingSettings trackRecording;
  final OfflineDownloadRecipe download;
}

/// 現場ごとの用途プリセット
enum RolePreset {
  /// 標準（すべて表示）
  standard('standard'),

  /// 猟師・狩猟向け（誤操作防止UI＋淡色/等高線＋林班界＋軽量10m地形）
  hunter('hunter'),

  /// 林業従事者向け（最新オルソ＋CS立体図＋等高線＋林班界＋高精度LiDAR地形）
  forestry('forestry'),

  /// 測量業者向け（淡色＋等高線＋高精度地形＋GNSS品質チェック＋外部機器フル表示）
  surveyor('surveyor'),

  /// 土木・防災現場向け（最新オルソ＋CS立体図＋シームレス地質図＋高精度地形）
  civil('civil');

  const RolePreset(this.code);

  final String code;

  static RolePreset parse(String? code) =>
      RolePreset.values.firstWhere((p) => p.code == code, orElse: () => RolePreset.standard);

  IconData get icon => switch (this) {
        RolePreset.standard => Icons.tune,
        RolePreset.hunter => Icons.hiking,
        RolePreset.forestry => Icons.park_outlined,
        RolePreset.surveyor => Icons.straighten,
        RolePreset.civil => Icons.engineering_outlined,
      };

  Color get color => switch (this) {
        RolePreset.standard => const Color(0xFF546E7A),
        RolePreset.hunter => const Color(0xFF6D4C41),
        RolePreset.forestry => const Color(0xFF2E7D32),
        RolePreset.surveyor => const Color(0xFF1565C0),
        RolePreset.civil => const Color(0xFFEF6C00),
      };

  String get title => switch (this) {
        RolePreset.standard => t.rolePreset.standardName,
        RolePreset.hunter => t.rolePreset.hunterName,
        RolePreset.forestry => t.rolePreset.forestryName,
        RolePreset.surveyor => t.rolePreset.surveyorName,
        RolePreset.civil => t.rolePreset.civilName,
      };

  String get description => switch (this) {
        RolePreset.standard => t.rolePreset.standardDesc,
        RolePreset.hunter => t.rolePreset.hunterDesc,
        RolePreset.forestry => t.rolePreset.forestryDesc,
        RolePreset.surveyor => t.rolePreset.surveyorDesc,
        RolePreset.civil => t.rolePreset.civilDesc,
      };

  String get summary => switch (this) {
        RolePreset.standard => t.rolePreset.standardSummary,
        RolePreset.hunter => t.rolePreset.hunterSummary,
        RolePreset.forestry => t.rolePreset.forestrySummary,
        RolePreset.surveyor => t.rolePreset.surveyorSummary,
        RolePreset.civil => t.rolePreset.civilSummary,
      };

  RolePresetRecipe get recipe => switch (this) {
        RolePreset.standard => const RolePresetRecipe(
            ui: UiVisibilityConfig.allVisible,
            basemapLayers: [
              BaseMapLayer(providerId: 'gsi_std'),
            ],
            officialLayerIds: [],
            highPrecisionTerrain: false,
            gnssQualityGate: GnssQualityGate.off,
            trackRecording: TrackRecordingSettings.defaults,
            download: OfflineDownloadRecipe(
              defaultRadiusMeters: 1000,
              recommendedMaxZoom: 17,
              includeOfficialVectorsByDefault: false,
            ),
          ),
        RolePreset.hunter => const RolePresetRecipe(
            ui: UiVisibilityConfig(
              showPenTool: false,
              showGpsTool: true,
              showMeasureTool: true,
              showAttributeTableButton: false,
              showAdvancedSettings: false,
            ),
            basemapLayers: [
              BaseMapLayer(providerId: 'gsi_pale', opacity: 100),
              BaseMapLayer(providerId: 'contours', blend: BaseMapBlend.multiply, opacity: 100),
            ],
            officialLayerIds: ['rinya_forest_plan'],
            highPrecisionTerrain: false,
            gnssQualityGate: GnssQualityGate.off,
            trackRecording: TrackRecordingSettings(
              intervalSeconds: 2,
              minDistance: 2,
              maxSpeedKmh: 100,
              maxAccuracy: 50,
            ),
            download: OfflineDownloadRecipe(
              defaultRadiusMeters: 2000,
              recommendedMaxZoom: 16,
              includeOfficialVectorsByDefault: true,
            ),
          ),
        RolePreset.forestry => const RolePresetRecipe(
            ui: UiVisibilityConfig.allVisible,
            basemapLayers: [
              BaseMapLayer(providerId: 'ortho_cascade', opacity: 100),
              BaseMapLayer(providerId: 'cs_relief', blend: BaseMapBlend.multiply, opacity: 65),
              BaseMapLayer(providerId: 'contours', blend: BaseMapBlend.multiply, opacity: 75),
            ],
            officialLayerIds: ['rinya_forest_plan'],
            highPrecisionTerrain: true,
            gnssQualityGate: GnssQualityGate.off,
            trackRecording: TrackRecordingSettings(
              intervalSeconds: 2,
              minDistance: 2,
              maxSpeedKmh: 100,
              maxAccuracy: 50,
            ),
            download: OfflineDownloadRecipe(
              defaultRadiusMeters: 1500,
              recommendedMaxZoom: 17,
              includeOfficialVectorsByDefault: true,
            ),
          ),
        RolePreset.surveyor => const RolePresetRecipe(
            ui: UiVisibilityConfig.allVisible,
            basemapLayers: [
              BaseMapLayer(providerId: 'gsi_pale', opacity: 100),
              BaseMapLayer(providerId: 'contours', blend: BaseMapBlend.multiply, opacity: 80),
            ],
            officialLayerIds: [],
            highPrecisionTerrain: true,
            gnssQualityGate: GnssQualityGate(
              maxAccuracy: 1.0,
              minSatellites: 6,
              strict: false,
            ),
            trackRecording: TrackRecordingSettings(
              intervalSeconds: 1,
              minDistance: 1,
              maxSpeedKmh: 200,
              maxAccuracy: 20,
            ),
            download: OfflineDownloadRecipe(
              defaultRadiusMeters: 1000,
              recommendedMaxZoom: 18,
              includeOfficialVectorsByDefault: false,
            ),
          ),
        RolePreset.civil => const RolePresetRecipe(
            ui: UiVisibilityConfig.allVisible,
            basemapLayers: [
              BaseMapLayer(providerId: 'ortho_cascade', opacity: 100),
              BaseMapLayer(providerId: 'cs_relief', blend: BaseMapBlend.multiply, opacity: 55),
            ],
            officialLayerIds: ['gsj_seamless_geology'],
            highPrecisionTerrain: true,
            gnssQualityGate: GnssQualityGate(
              maxAccuracy: 3.0,
              strict: false,
            ),
            trackRecording: TrackRecordingSettings.defaults,
            download: OfflineDownloadRecipe(
              defaultRadiusMeters: 1000,
              recommendedMaxZoom: 18,
              includeOfficialVectorsByDefault: false,
            ),
          ),
      };
}
