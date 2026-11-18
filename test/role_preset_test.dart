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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/core/official/official_data_catalog.dart';
import 'package:root_maps/core/role_preset.dart';
import 'package:root_maps/core/terrain/terrain_appearance.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/basemap_layer.dart';
import 'package:root_maps/models/basemap_provider.dart';
import 'package:root_maps/models/gnss_quality.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/official_layer_node.dart';
import 'package:root_maps/models/nodes/sys_node.dart';
import 'package:root_maps/providers/gps_providers.dart';
import 'package:root_maps/providers/role_preset_providers.dart';
import 'package:root_maps/providers/tool_providers.dart';
import 'package:root_maps/providers/ui_state_providers.dart';
import 'package:root_maps/screens/basemap_settings/basemap_download_section.dart';
import 'package:root_maps/screens/terrain_settings_screen.dart';
import 'package:root_maps/services/basemap_service.dart';
import 'package:root_maps/services/official/official_layer_service.dart';
import 'package:root_maps/tutorial/tutorial.dart';
import 'package:root_maps/widgets/map_appbar_actions.dart';
import 'package:root_maps/widgets/map_toolbar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.ja);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await terrainSettings.load();
    await terrainSettings.setBool(terrainHighPrecisionDef, false);
    syncTerrainAppearance();
  });

  group('RolePreset recipes & state synchronization', () {
    test('applying each preset updates UI subtraction, basemap, official layers, terrain, and GPS settings', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final root = FolderNode('Root');
      container.read(folderTreeProvider.notifier).set(root);

      final official = OfficialLayerService.forTesting();
      final basemap = BaseMapService();

      // まずペンツールを握っている状態を作る
      container.read(currentToolProvider.notifier).set(container.read(penToolProvider));
      expect(container.read(currentToolProvider).name, 'Pen');

      // 1. 猟師プリセット（引き算 UI + 淡色/等高線 + 林班 + 軽量10m地形 + 徒歩軌跡）
      await container.read(rolePresetSettingProvider.notifier).apply(
            RolePreset.hunter,
            baseMapService: basemap,
            officialLayerService: official,
          );

      expect(container.read(rolePresetSettingProvider), RolePreset.hunter);
      final hunterUi = container.read(uiVisibilitySettingProvider);
      expect(hunterUi.showPenTool, isFalse);
      expect(hunterUi.showAttributeTableButton, isFalse);
      expect(hunterUi.showAdvancedSettings, isFalse);
      expect(hunterUi.showGpsTool, isTrue);
      expect(hunterUi.showMeasureTool, isTrue);
      // ペンツールが隠れたため自動で安全な Pan へ退避していること
      expect(container.read(currentToolProvider).name, 'Pan');

      expect(basemap.layers, const [
        BaseMapLayer(providerId: 'gsi_pale', opacity: 100),
        BaseMapLayer(providerId: 'contours', blend: BaseMapBlend.multiply, opacity: 100),
      ]);
      expect(official.enabledIds, ['rinya_forest_plan']);
      final sysAfterHunter = root.children.whereType<SysNode>().single;
      expect(
        sysAfterHunter.children.whereType<OfficialLayerNode>().map((n) => n.spec.id),
        ['rinya_forest_plan'],
      );
      expect(TerrainAppearance.highPrecision, isFalse);
      expect(container.read(trackRecordingSettingProvider).intervalSeconds, 2);
      expect(container.read(trackRecordingSettingProvider).minDistance, 2);
      expect(container.read(gnssQualityGateSettingProvider), GnssQualityGate.off);

      // 2. 林業プリセット（全ツール + 高精細オルソ/CS立体図/等高線 + 林班 + 高精度3D地形）
      await container.read(rolePresetSettingProvider.notifier).apply(
            RolePreset.forestry,
            baseMapService: basemap,
            officialLayerService: official,
          );
      expect(container.read(uiVisibilitySettingProvider), UiVisibilityConfig.allVisible);
      expect(basemap.layers.map((l) => l.providerId), ['ortho_cascade', 'cs_relief', 'contours']);
      expect(official.enabledIds, ['rinya_forest_plan']);
      expect(TerrainAppearance.highPrecision, isTrue);

      // 3. 土木・防災プリセット（林班が外れ、シームレス地質図へ入れ替わる＝不要データの引き算）
      await container.read(rolePresetSettingProvider.notifier).apply(
            RolePreset.civil,
            baseMapService: basemap,
            officialLayerService: official,
          );
      expect(basemap.layers.map((l) => l.providerId), ['ortho_cascade', 'cs_relief']);
      expect(official.enabledIds, ['gsj_seamless_geology']);
      expect(
        sysAfterHunter.children.whereType<OfficialLayerNode>().map((n) => n.spec.id),
        ['gsj_seamless_geology'],
      );
      expect(TerrainAppearance.highPrecision, isTrue);
      expect(container.read(gnssQualityGateSettingProvider).maxAccuracy, 3.0);

      // 4. 測量プリセット（公式データ0件・GNSS品質チェック ±1m / 6衛星）
      await container.read(rolePresetSettingProvider.notifier).apply(
            RolePreset.surveyor,
            baseMapService: basemap,
            officialLayerService: official,
          );
      expect(basemap.layers.map((l) => l.providerId), ['gsi_pale', 'contours']);
      expect(official.enabledIds, isEmpty);
      expect(sysAfterHunter.children.whereType<OfficialLayerNode>(), isEmpty);
      expect(TerrainAppearance.highPrecision, isTrue);
      final surveyorGate = container.read(gnssQualityGateSettingProvider);
      expect(surveyorGate.maxAccuracy, 1.0);
      expect(surveyorGate.minSatellites, 6);
      expect(surveyorGate.strict, isFalse);

      // 5. 標準プリセットへ戻す
      await container.read(rolePresetSettingProvider.notifier).apply(
            RolePreset.standard,
            baseMapService: basemap,
            officialLayerService: official,
          );
      expect(basemap.layers, const [BaseMapLayer(providerId: 'gsi_std')]);
      expect(official.enabledIds, isEmpty);
      expect(TerrainAppearance.highPrecision, isFalse);
      expect(container.read(gnssQualityGateSettingProvider), GnssQualityGate.off);
    });

    test('individual UI customization persists on top of preset and can be reset', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final official = OfficialLayerService.forTesting();
      final basemap = BaseMapService();

      await container.read(rolePresetSettingProvider.notifier).apply(
            RolePreset.hunter,
            baseMapService: basemap,
            officialLayerService: official,
          );
      expect(container.read(uiVisibilitySettingProvider).showPenTool, isFalse);

      // 猟師プリセットのまま「作図（ペン）ツール」だけ手動でONにする
      await container
          .read(uiVisibilitySettingProvider.notifier)
          .updateConfig((c) => c.copyWith(showPenTool: true));
      expect(container.read(rolePresetSettingProvider), RolePreset.hunter);
      expect(container.read(uiVisibilitySettingProvider).showPenTool, isTrue);
      expect(container.read(uiVisibilitySettingProvider), isNot(RolePreset.hunter.recipe.ui));

      // 新しいコンテナで SharedPreferences から復元しても維持されること
      final reloaded = ProviderContainer();
      addTearDown(reloaded.dispose);
      await reloaded.read(rolePresetSettingProvider.notifier).load();
      await reloaded.read(uiVisibilitySettingProvider.notifier).load();
      expect(reloaded.read(rolePresetSettingProvider), RolePreset.hunter);
      expect(reloaded.read(uiVisibilitySettingProvider).showPenTool, isTrue);
      expect(reloaded.read(uiVisibilitySettingProvider).showAttributeTableButton, isFalse);
    });
  });

  group('UI subtraction & tutorial safety widgets', () {
    testWidgets('hunter preset hides Pen & AttributeTable, but active Tutorial restores them', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(uiVisibilitySettingProvider.notifier).set(RolePreset.hunter.recipe.ui);

      Widget buildHarness() {
        return UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: Consumer(
              builder: (context, ref, _) {
                final ui = ref.watch(uiVisibilitySettingProvider);
                final inTutorial = ref.watch(tutorialProvider) != null;
                return MaterialApp(
                  home: Scaffold(
                    appBar: AppBar(
                      actions: buildMapAppBarActions(
                        showAttributeTable: false,
                        drawerOpen: false,
                        showAttributeTableAction: inTutorial || ui.showAttributeTableButton,
                        onAttributeTableToggle: () {},
                        onDrawerToggle: () {},
                      ),
                    ),
                    body: Stack(
                      children: [
                        MapToolbar(onToolChanged: () {}),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(buildHarness());

      // 通常時（猟師プリセット）: ペンと属性テーブルが隠れ、移動・選択・GPS・計測は残る
      expect(find.byIcon(Icons.pan_tool_alt), findsOneWidget);
      expect(find.byIcon(Icons.select_all), findsOneWidget);
      expect(find.byIcon(Icons.gps_fixed), findsOneWidget);
      expect(find.byIcon(Icons.straighten), findsOneWidget);
      expect(find.byIcon(Icons.edit), findsNothing);
      expect(find.byIcon(Icons.table_view), findsNothing);

      // チュートリアル開始中: 案内対象が詰まらないよう自動で両方とも表示される
      container.read(tutorialProvider.notifier).start();
      await tester.pump();

      expect(find.byIcon(Icons.edit), findsOneWidget);
      expect(find.byIcon(Icons.table_view), findsOneWidget);

      // チュートリアル終了後: 再び猟師プリセットの引き算状態へ戻る
      container.read(tutorialProvider.notifier).stop();
      await tester.pump();

      expect(find.byIcon(Icons.edit), findsNothing);
      expect(find.byIcon(Icons.table_view), findsNothing);
    });
  });

  group('Offline download layer narrowing & official vector tile calculation', () {
    test('tilesForArea clamps & deduplicates official MVT tiles across zoom levels', () {
      final service = OfficialLayerService.forTesting();
      const center = LatLng(33.94, 135.96); // 北山村付近

      // 最小表示ズーム未満（z8〜11）では公式林班タイルを1枚も要求しない
      final lowZoom = service.tilesForArea(
        OfficialLayerSpec.rinyaForestPlan,
        center: center,
        radiusMeters: 1000,
        minZoom: 8,
        maxZoom: 11,
      );
      expect(lowZoom, isEmpty);

      // z15〜18 を要求しても rinya_forest_plan の配信上限 z16 で頭打ち・重複除外される
      final z15to16 = service.tilesForArea(
        OfficialLayerSpec.rinyaForestPlan,
        center: center,
        radiusMeters: 1000,
        minZoom: 15,
        maxZoom: 16,
      );
      final z15to18 = service.tilesForArea(
        OfficialLayerSpec.rinyaForestPlan,
        center: center,
        radiusMeters: 1000,
        minZoom: 15,
        maxZoom: 18,
      );
      expect(z15to16, isNotEmpty);
      expect(z15to18, equals(z15to16));
    });

    testWidgets('BasemapDownloadSettingsDialog narrows layers and includes checked official vector tiles',
        (tester) async {
      final basemap = BaseMapService();
      final official = OfficialLayerService.forTesting();
      final pale = BaseMapProvider.getProviderById('gsi_pale')!;
      final contours = BaseMapProvider.getProviderById('contours')!;

      List<BaseMapProvider>? capturedProviders;
      List<Future<bool?> Function()>? capturedExtraTasks;

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: BasemapDownloadSettingsDialog(
                center: const LatLng(33.94, 135.96),
                providers: [pale, contours],
                officialSpecs: const [OfficialLayerSpec.rinyaForestPlan],
                activePreset: RolePreset.hunter,
                officialService: official,
                zoomMin: 12,
                zoomMax: 18,
                initialRadius: 1000,
                initialZoomRange: const RangeValues(14, 16),
                baseMapService: basemap,
                onStartDownload: (r, zMin, zMax, selectedProviders, extraTasks) {
                  capturedProviders = selectedProviders;
                  capturedExtraTasks = extraTasks;
                },
              ),
            ),
          ),
        ),
      );

      // 猟師プリセットでは背景2枚＋林班データの3つすべてに初期チェックが入っている
      final checkboxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      expect(checkboxes.length, 3);
      expect(checkboxes.every((c) => c.value == true), isTrue);

      // 「等高線」のチェックを外してダウンロード対象を絞る
      await tester.tap(find.widgetWithText(CheckboxListTile, contours.name));
      await tester.pump();

      await tester.tap(find.text(t.basemap.download.startDownload));
      await tester.pump();

      expect(capturedProviders?.map((p) => p.id), ['gsi_pale']);
      expect(capturedExtraTasks, isNotNull);
      expect(capturedExtraTasks, isNotEmpty);
    });
  });
}
