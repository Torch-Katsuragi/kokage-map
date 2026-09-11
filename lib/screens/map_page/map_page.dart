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
// Root Maps: Map and edit screen
// Main UI for map display and layer/feature editing
// maplibre移行: FlutterMap → MapLibreMap
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:path/path.dart' as p;

import '../../devices/base/device_tool.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../providers/device_tool_providers.dart';
import '../../providers/notification_providers.dart';
import '../../providers/party_providers.dart';
import '../../providers/project_providers.dart';
import '../../providers/selection_providers.dart';
import '../../providers/terrain_providers.dart';
import '../../providers/tool_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/map_source_manager.dart';
import '../../services/party/party_invite.dart';
import '../../tools/gps_tool.dart';
import '../../tools/overlay_transform_tool.dart';
import '../../tools/pen_tool.dart';
import '../../tools/select_tool.dart';
import '../../utils/app_logger.dart';
import '../../utils/feature_calc_utils.dart';
import '../../utils/geo_converter.dart';
import '../../utils/global_drawing_state.dart';
import '../../utils/keyboard_handler.dart';
import '../../utils/label_template.dart';
import '../../widgets/attribute_table/attribute_table_widget.dart';
import '../../widgets/compass_fan_painter.dart';
import '../../widgets/feature_detail_panel.dart';
import '../../widgets/feature_set_panel.dart';
// gps_track.dart は不要に（GpsHistoryRecorder に統合）
import '../../widgets/layer_drawer/layer_drawer.dart';
import '../../widgets/left_bottom_fab.dart';
import '../../widgets/map/r_map_widget.dart';
import '../../widgets/map_appbar_actions.dart';
import '../../widgets/map_toolbar.dart';
import '../../widgets/resizable_bottom_panel.dart';
import '../../widgets/resizable_side_panel.dart';
import '../layer_style_settings_screen.dart'
    show
        layerStyleSettings,
        labelEnabledDef,
        labelPropertyDef,
        lineVertexPointsEnabledDef,
        polygonVertexPointsEnabledDef;
// Mixins
import 'feature_geojson_cache.dart';
import 'map_page_state_base.dart';
import 'mixins/index.dart';
// Widgets
import 'widgets/index.dart';
import 'widgets/map_menu_button.dart';
import 'widgets/overlay_image_layers.dart';
import 'widgets/party_controls.dart';
import 'widgets/party_map_layers.dart';
import 'widgets/terrain_map_layer.dart';
import 'widgets/tool_name_flash.dart';

/// Map and edit screen (main structure)
class RootMapsHomePage extends ConsumerStatefulWidget {
  const RootMapsHomePage({super.key});
  @override
  ConsumerState<RootMapsHomePage> createState() => _RootMapsHomePageState();
}

/// Tool types
enum ToolType { pen, eraser, gps }

class _RootMapsHomePageState extends ConsumerState<RootMapsHomePage>
    with
        TickerProviderStateMixin,
        MapPageStateBase,
        MapJumpMixin,
        MapInitializationMixin,
        MapBasemapMixin,
        MapOverlayMixin,
        MapStyleMixin,
        MapGpsTrackingMixin,
        MapGpsSurveyMixin,
        MapFeatureCacheMixin,
        MapDrawingMixin,
        WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    AppLogger.debug('[MapPage] initState start');
    WidgetsBinding.instance.addObserver(this);
    initializeAllServices();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mapControllerHolderProvider.notifier).set(mapController);
      // 招待URL（web の `?room=CODE`）経由の起動なら、参加ダイアログを
      // コード充填済みで開く（「ルーム参加がURLで済む」の受け側）。
      final inviteCode = consumePendingRoomCode();
      if (inviteCode != null && mounted) {
        showPartyEntry(context, ref, initialCode: inviteCode);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disposeAllServices();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // バックグラウンド復帰時にオーバーレイを再同期
      // AndroidでMapLibreのImageSourceが消失する問題への対策
      AppLogger.debug('[MapPage] app resumed, re-syncing overlays');
      activeOverlaySourceIds.clear(); // 強制的に全再追加
      syncOverlayImages();
    }
  }

  // =============================================
  // 抽象メソッド実装（MapPageStateBaseより）
  // =============================================

  @override
  void onGpsManagerUpdate() {
    if (mounted) {
      updateCurrentGpsInfo();
    }
  }

  /// dirtyフラグ設定と同時にフィーチャソースを再同期
  /// build()からの毎フレーム呼び出しを排除し、データ変更時のみ同期する
  @override
  void invalidateLayerCache() {
    super.invalidateLayerCache();
    _syncFeatureSources();
  }

  @override
  void onBaseMapServiceUpdate() {
    if (mounted) {
      replaceBasemapSource();
      triggerSetState(() {});
    }
  }

  @override
  void onLayerStyleChanged() {
    if (mounted) {
      applyLayerStyles();
      invalidateLayerCache(); // dirty設定 + _syncFeatureSources() 呼び出し
      triggerSetState(() {});
    }
  }

  @override
  void updateCurrentGpsInfo() {
    triggerSetState(() {
      currentGpsInfo = gpsManager.getCurrentGpsInfo();
    });
  }

  @override
  Future<void> updateFeatures() async {
    await updateFeaturesImpl();
  }

  // =============================================
  // 属性テーブル管理
  // =============================================

  /// 属性テーブルを開く
  Future<void> _openAttributeTable([LayerNode? targetLayer]) async {
    try {
      final layer = targetLayer ?? ref.read(selectedLayerNodeProvider);

      if (layer == null) {
        ref
            .read(notificationCenterProvider.notifier)
            .add(title: t.editor.noLayerSelected, level: NotificationLevel.warning);
        return;
      }

      AppLogger.debug('[MAP] 属性テーブルを開く: ${layer.name}');

      triggerSetState(() {
        attributeTableLayer = layer;
        showAttributeTable = true;
      });
    } catch (e) {
      AppLogger.debug('[MAP] 属性テーブル表示エラー: $e');
      ref
          .read(notificationCenterProvider.notifier)
          .add(
            title: t.attributeTable.error,
            detail: '$e',
            level: NotificationLevel.error,
          );
    }
  }

  /// 属性テーブルを閉じる
  void _closeAttributeTable() {
    triggerSetState(() {
      showAttributeTable = false;
      attributeTableLayer = null;
    });
    AppLogger.debug('[MAP] 属性テーブル表示終了');
  }

  /// 属性テーブルでフィーチャが選択されたときの処理
  void _onAttributeTableFeatureSelected(FeatureNode feature) {
    try {
      AppLogger.debug('[MAP] 属性テーブルでフィーチャ選択: ${feature.rowId}');
      ref.read(selectedFeaturesProvider.notifier).set([feature]);
      triggerSetState(() {});
      jumpTo(feature.centroid);
    } catch (e) {
      AppLogger.debug('[MAP] フィーチャ選択処理エラー: $e');
    }
  }

  // =============================================
  // コンパス方向付きの現在位置マーカー
  // =============================================

  /// コンパス方向付きの現在位置マーカー
  ///
  /// heading（磁気センサ）と mapBearing（地図回転角）の両方を監視し、
  /// どちらが変わっても即座に扇の角度を更新する。
  Widget _buildLocationMarkerWithCompass() {
    final child = Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
    );

    return ListenableBuilder(
      listenable: Listenable.merge([headingNotifier, mapBearingNotifier]),
      builder: (_, _) {
        final heading = headingNotifier.value;
        final mapBearing = mapBearingNotifier.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            if (heading != null)
              Transform.rotate(
                angle: ((heading - mapBearing) * pi / 180) - (pi / 2),
                child: SizedBox(
                  width: 60,
                  height: 60,
                  child: CustomPaint(painter: CompassFanPainter()),
                ),
              ),
            child,
          ],
        );
      },
    );
  }

  // =============================================
  // AppBar: タイトル
  // =============================================

  Widget _buildAppBarTitle(LayerTreeNode? rootNode) {
    return Text(p.basename(ref.watch(projectRootDirProvider) ?? t.common.appName));
  }

  // =============================================
  // ビルドメソッド
  // =============================================

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(featureRefreshTriggerProvider, (prev, next) {
      if (prev != null && prev != next) {
        updateFeaturesImpl();
      }
    });

    // DeviceTool の内部状態変更で地図オーバーレイを再描画
    ref.listen<int>(deviceToolOverlayRefreshProvider, (prev, next) {
      if (prev != null && prev != next) {
        triggerSetState(() {});
      }
    });

    // 選択状態の変更をリッスンしてフィーチャソースを再同期
    ref.listen<List<LayerTreeNode>>(selectedFeaturesProvider, (_, _) {
      _syncFeatureSources();
    });

    // 選択レイヤー変更 → 属性テーブルが開いていれば自動で切り替え
    ref.listen<LayerNode?>(selectedLayerNodeProvider, (prev, next) {
      if (showAttributeTable && next != null &&
          next.layerName != attributeTableLayer?.layerName) {
        triggerSetState(() {
          attributeTableLayer = next;
        });
      }
    });

    // 選択状態を監視（変更時に自動rebuild）
    final selectedFeatures = ref.watch(selectedFeaturesProvider);

    // パーティ位置共有: peers/接続状態の変化で地図マーカーを再描画
    ref.watch(partySessionProvider);

    final folderTree = ref.watch(folderTreeProvider);
    currentNode ??= folderTree;

    final currentTool = ref.watch(currentToolProvider);
    final isPanTool = currentTool.name == 'Pan';
    final terrain3d = ref.watch(terrain3dModeProvider);
    ref.listen(terrain3dModeProvider, (_, on) => _onTerrain3dChanged(on));

    return KeyboardShortcutWrapper(
      mapState: this,
      child: Scaffold(
        appBar: AppBar(
          title: _buildAppBarTitle(folderTree),
          actions: [
            ...buildMapAppBarActions(
              context: context,
              showAttributeTable: showAttributeTable,
              drawerOpen: drawerOpen,
              onAttributeTableToggle: () {
                if (showAttributeTable) {
                  _closeAttributeTable();
                } else {
                  _openAttributeTable();
                }
              },
              onDrawerToggle: () {
                triggerSetState(() {
                  if (drawerOpen) {
                    drawerOpen = false;
                  } else {
                    drawerOpen = true;
                    drawerWidth = 320;
                  }
                });
              },
              // ≡ メニュー（パーティ・水準器・設定を集約）はレイヤ一覧の左
              beforeLayerButton: const [MapMenuButton()],
            ),
          ],
        ),
        body: Column(
          children: [
            // 地図エリア（ボトムパネル表示時に縮む）
            Expanded(
              child: Stack(
                children: [
                  // 左側ツールバー
                  MapToolbar(onToolChanged: () => triggerSetState(() {})),
                  // 地図本体
                  Positioned.fill(
                    left: 44,
                    child: Stack(
                      children: [
                        // 3D 中も MapLibre は下に置いたまま、スタイルを空にしてタイルとソースを手放す
                        // （組み立て直すと maplibre_android がネイティブの地図を捨てず、往復ごとに 170MB 漏れた）
                        _buildMapLibreMap(isPanTool),
                        _buildGestureLayer(),
                        // 3D 地形モード: 地図面を上に重ね、ジェスチャもここで受ける
                        if (terrain3d && basemapStyleUri != null)
                          Positioned.fill(
                            child: TerrainMapLayer(
                              mapState: this,
                              baseMapService: baseMapService,
                              geoJson: geoJson,
                              sceneRevision: terrainSceneRevision,
                              styleGroups: () => sourceManager.styleGroups,
                              currentLocation: currentLocation,
                              gpsTrack: () => gpsHistoryRecorder.todayPoints,
                              onProjectionChanged: (p) {
                                terrainProjection = p;
                                // レイヤのダブルタップなど、ホルダー経由の「寄せる」「移動」も 3D に流す
                                // （fit → jump の順。jumpOverride を置いた瞬間に attach 前の保留分が流れる）
                                mapControllerInstance.fitOverride =
                                    p == null ? null : (c, pad) => p.fitCoordinates(c, padding: pad);
                                mapControllerInstance.jumpOverride = p == null
                                    ? null
                                    : (c, z, _, {required animate}) => unawaited(p.jumpTo(c, z, animate: animate));
                              },
                              mapBearingNotifier: mapBearingNotifier,
                              cameraTickNotifier: cameraTickNotifier,
                              heading: headingNotifier,
                            ),
                          ),
                        _buildDrawingPreviewInfo(),
                        _buildOffscreenLocationIndicator(),
                        const ToolNameFlash(),
                      ],
                    ),
                  ),
                  // Layer Drawer Panel（右サイド — 属性テーブルとは独立）
                  if (drawerOpen) _buildLayerDrawerPanel(),
                  // Feature detail panel
                  if (selectedFeatures.length == 1)
                    Positioned(
                      left: 60,
                      top: 20,
                      child: FeatureDetailPanel(feature: selectedFeatures.first),
                    )
                  else if (selectedFeatures.length > 1)
                    Positioned(
                      left: 60,
                      top: 20,
                      child: FeatureSetPanel(features: selectedFeatures),
                    ),
                  // 外部機器ツールのステータスパネル（DeviceTool抽象経由）
                  if (currentTool is DeviceTool)
                    ListenableBuilder(
                      listenable: currentTool,
                      builder: (ctx, _) => currentTool.buildStatusPanel(ctx),
                    ),
                  // Left bottom floating buttons
                  Positioned(
                    left: 56,
                    bottom: 24,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (currentTool.name == 'GPS')
                          GpsSurveyButtons(
                            isLongPressing: isLongPressing,
                            longPressGpsCount: longPressGpsCount,
                            onRecordGpsPosition: recordGpsPosition,
                            onStartLongPressGpsSurvey: startLongPressGpsSurvey,
                            onStopLongPressGpsSurvey: stopLongPressGpsSurvey,
                            onOpenTrackExtraction: openTrackExtractionDialog,
                          ),
                        const LeftBottomFab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 属性テーブル（ボトムパネル — レイヤードロワーとは独立）
            if (showAttributeTable && attributeTableLayer != null)
              _buildAttributeTablePanel(),
          ],
        ),
        floatingActionButton: DrawingActionButtons(
          onConfirmDrawing: onConfirmDrawing,
          onConfirmGpsSurvey: onConfirmGpsSurvey,
          onTriggerSetState: () => triggerSetState(() {}),
          getGpsTool:
              () =>
                  ref.read(currentToolProvider) is GpsTool
                      ? ref.read(currentToolProvider) as GpsTool
                      : null,
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
    );
  }

  /// MapLibreMap構築
  /// フィーチャ系レイヤはMapSourceManager経由で管理（OOM防止）
  /// layersには描画プレビューと投げ縄のみ（超軽量）
  Widget _buildMapLibreMap(bool isPanTool) {
    // TileServer 起動 + ローカルスタイル生成待ち
    if (basemapStyleUri == null) {
      return const SizedBox.expand();
    }

    final selectedSet = ref.read(selectedFeaturesProvider).toSet();
    final drawingState = GlobalDrawingState.instance;
    final currentTool = ref.read(currentToolProvider);

    return RMapWidget(
      onDispose: _onMapLibreDisposed,
      options: ml.MapOptions(
        // 3D が既定の間は空のスタイルで組む（タイルもソースも持たない。抜けるときに基図のスタイルを読む）
        initStyle: ref.read(terrain3dModeProvider) ? kEmptyMapStyle : basemapStyleUri!,
        initCenter: (mapController.lastCenter ?? defaultCenter).toGeographic(),
        initZoom: mapController.lastZoom,
        initBearing: mapController.lastBearing,
        gestures: const ml.MapGestures(
          pan: false,
          zoom: false,
          rotate: false,
          pitch: false,
        ),
      ),
      onMapCreated: (controller) {
        mapControllerInstance.attach(controller.raw!);
      },
      onStyleLoaded: (_, style) => _onMapStyleLoaded(style),
      onEvent: _onMapEvent,
      // 描画プレビューと投げ縄のみ（数点、超軽量）
      layers: [
        // 描画プレビュー: ポリゴン（GPSツール）
        if (currentTool is GpsTool && drawingState.drawingPolygon.length >= 3)
          ml.PolygonLayer(
            polygons: [
              geo.Feature(
                geometry: geo.Polygon.from([
                  closeRing(drawingState.drawingPolygon).toGeographics(),
                ]),
              ),
            ],
            color: Colors.purple.withValues(alpha: 0.4),
            outlineColor: Colors.purple,
          ),
        // 描画プレビュー: ポリゴン（ペンツール）
        if (currentTool is PenTool && drawingState.drawingPolygon.length >= 3)
          ml.PolygonLayer(
            polygons: [
              geo.Feature(
                geometry: geo.Polygon.from([
                  closeRing(drawingState.drawingPolygon).toGeographics(),
                ]),
              ),
            ],
            color: Colors.orange.withValues(alpha: 0.4),
            outlineColor: Colors.orange,
          ),
        // 投げ縄選択ポリゴン
        if (currentTool case SelectTool(
          :final lassoPoints,
        ) when lassoPoints.length >= 3)
          ml.PolygonLayer(
            polygons: [
              geo.Feature(
                geometry: geo.Polygon.from([
                  closeRing(
                    lassoPoints
                        .map(offsetToLatLng)
                        .toList(),
                  ).toGeographics(),
                ]),
              ),
            ],
            color: Colors.white.withValues(alpha: 0.2),
            outlineColor: Colors.black,
          ),
        // 描画プレビュー: ライン
        ..._buildDrawingPreviewPolylines(currentTool, drawingState),
        // パーティ位置共有: 仲間の圏外区間軌跡（gap backfill）
        ...buildPartyTrackPolylines(ref.read(partySessionProvider)),
        // 外部機器ツールのオーバーレイ（DeviceTool抽象経由）
        if (currentTool is DeviceTool)
          ...currentTool.buildOverlayLayers(),
        // 選択中オーバーレイの枠線 + 変形ハンドル接続線
        ...buildOverlaySelectionLayers(selectedSet, currentTool),
      ],
      children: [
        // Widgetマーカー（現在位置、測量ポイント等）
        ml.WidgetLayer(markers: [
          ..._buildOverlayWidgetMarkers(selectedSet),
          if (currentTool is DeviceTool)
            ...currentTool.buildOverlayMarkers(),
        ]),
        // オーバーレイ変形ハンドル（transformNotifier経由で局所rebuild）
        if (currentTool is OverlayTransformTool)
          ListenableBuilder(
            listenable: currentTool.transformNotifier,
            builder: (_, _) {
              return ml.WidgetLayer(
                markers: buildTransformHandleMarkers(currentTool),
              );
            },
          ),
      ],
    );
  }

  /// MapLibre のウィジェットが外れた（画面を閉じた）。コントローラ・スタイル・登録済みソースの記録を捨てる
  void _onMapLibreDisposed() {
    AppLogger.debug('[MAP] MapLibre disposed');
    mapControllerInstance.detach();
    _forgetStyle();
  }

  /// スタイル側の記録を捨てる。次の onStyleLoaded で基図・フィーチャ・オーバーレイを全部登録し直す
  void _forgetStyle() {
    sourceManager.detachStyle();
    activeBasemapLayerIds.clear();
    activeBasemapSourceIds.clear();
    activeOverlaySourceIds.clear();
  }

  /// 3D の出入り。入るときは MapLibre を空のスタイルにしてタイルとソースを手放し（メモリ）、
  /// 抜けるときは基図のスタイルを読み直す（onStyleLoaded から全部やり直す）
  void _onTerrain3dChanged(bool on) {
    final raw = mapControllerInstance.raw;
    if (raw == null) return;
    if (on) {
      mapControllerInstance.detachStyle();
      _forgetStyle();
      raw.setStyle(kEmptyMapStyle);
    } else if (basemapStyleUri != null) {
      raw.setStyle(basemapStyleUri!);
    }
  }

  Future<void> _onMapStyleLoaded(ml.StyleController style) async {
    // 3D 中に来るのは空のスタイル。何も載せない（抜けるときに基図のスタイルを読み直して、そのときに載せる）
    if (ref.read(terrain3dModeProvider)) {
      AppLogger.debug('[MAP] onStyleLoaded (empty, 3D)');
      return;
    }
    AppLogger.debug('[MAP] onStyleLoaded fired');
    mapControllerInstance.attachStyle(style);
    await addBasemapSources(style);
    await sourceManager.initialize(style);

    // 現在のスタイル設定を反映
    applyLayerStyles();

    // ソース初期化完了 → dirty フラグを強制セットして確実にフィーチャを送信
    invalidateLayerCache();
  }

  /// マップイベント処理
  void _onMapEvent(ml.MapEvent event) {
    // カメラ移動中: bearing変化時のみコンパス扇を更新（低コスト）
    if (event is ml.MapEventMoveCamera) {
      final b = event.camera.bearing;
      if (b != mapBearingNotifier.value) {
        mapBearingNotifier.value = b;
      }
      cameraTickNotifier.value++;
    }
    // カメラ停止: クラスタ再計算
    if (event is ml.MapEventCameraIdle || event is ml.MapEventIdle) {
      cameraTickNotifier.value++;
      _refreshPointClusters();
    }
  }

  /// 描画プレビュー用ポリラインレイヤのリスト生成
  List<ml.PolylineLayer> _buildDrawingPreviewPolylines(
    dynamic currentTool,
    GlobalDrawingState drawingState,
  ) {
    final layers = <ml.PolylineLayer>[];
    // GPSツールの線プレビュー（LineStringは最低2点必要）
    if (currentTool is GpsTool && drawingState.drawingLine.length >= 2) {
      layers.add(
        ml.PolylineLayer(
          polylines: [
            geo.Feature(
              geometry: geo.LineString.from(
                drawingState.drawingLine.toGeographics(),
              ),
            ),
          ],
          color: Colors.purple,
          width: 2,
        ),
      );
    }
    // ペンツールの線プレビュー（LineStringは最低2点必要）
    if (currentTool is PenTool && drawingState.drawingLine.length >= 2) {
      layers.add(
        ml.PolylineLayer(
          polylines: [
            geo.Feature(
              geometry: geo.LineString.from(
                drawingState.drawingLine.toGeographics(),
              ),
            ),
          ],
          color: Colors.orange,
          width: 2,
        ),
      );
    }
    // GPSツールのポリゴン辺プレビュー（2点時）
    if (currentTool is GpsTool && drawingState.drawingPolygon.length == 2) {
      layers.add(
        ml.PolylineLayer(
          polylines: [
            geo.Feature(
              geometry: geo.LineString.from(
                drawingState.drawingPolygon.toGeographics(),
              ),
            ),
          ],
          color: Colors.purple,
          width: 2,
        ),
      );
    }
    // ペンツールのポリゴン辺プレビュー（2点時）
    if (currentTool is PenTool && drawingState.drawingPolygon.length == 2) {
      layers.add(
        ml.PolylineLayer(
          polylines: [
            geo.Feature(
              geometry: geo.LineString.from(
                drawingState.drawingPolygon.toGeographics(),
              ),
            ),
          ],
          color: Colors.orange,
          width: 2,
        ),
      );
    }
    return layers;
  }

  /// フィーチャキャッシュを再構築し、MapSourceManager経由でGeoJSONソースを更新
  /// オーバーレイ方式: 通常ソースは常に全フィーチャ、選択ソースは選択分だけ上乗せ
  /// → 選択変更時に通常ソースのGeoJSONが不変のため送信スキップされ、チラつきが解消
  void _syncFeatureSources() {
    final currentSelection = ref.read(selectedFeaturesProvider);
    final selectionChanged = !identical(lastCacheSelection, currentSelection);

    if (!layerCacheDirty && !selectionChanged) return;
    final dataChanged = layerCacheDirty;
    layerCacheDirty = false;
    lastCacheSelection = currentSelection;

    // View / レイヤのスタイル指定が変わっていたらレイヤを積み直す。
    // ⚠ フィーチャを組み立てる**前**に済ませること。`k-style` を載せるかどうかの
    //   判断が `sourceManager.styleGroups` を見ているため。
    final groups = buildStyleGroups();
    if (sourceManager.setStyleGroups(groups)) {
      applyLayerStyles(groups: groups);
    }

    final input = FeatureGeoJsonInput(
      lines: lineFeatures,
      polygons: polygonFeatures,
      points: pointFeatures,
      photos: photoNodes,
      selected: currentSelection.toSet(),
      // 固有スタイルが1つでもあれば、フィーチャに「どのグループのものか」を載せる
      styleKeyOf: sourceManager.styleGroups.isEmpty
          ? null
          : (f) => f.parent.styleKeyOf(f.rowId),
      stylePropKey: MapSourceManager.kStyleProp,
      labelOf: _labelFor,
      lineVertices: layerStyleSettings.getBool(lineVertexPointsEnabledDef),
      polygonVertices: layerStyleSettings.getBool(polygonVertexPointsEnabledDef),
    );

    if (!dataChanged) {
      // 選択のみ変更: 選択ソースだけ再構築（通常ソースは不変→送信スキップ）
      geoJson.rebuildSelection(input);
      _pushFeaturesToSources();
      return;
    }

    geoJson.rebuildAll(input);
    _pushFeaturesToSources();
    syncOverlayImages();
  }

  /// フィーチャに出すラベル。View 固有 → レイヤ固有 → 全体設定の順で解決する
  String? _labelFor(FeatureNode f) {
    final layer = f.parent;
    final kmeta =
        layer.styleGroups[layer.styleKeyOf(f.rowId)] ?? layer.kmetaStyleIfLoaded;
    if (!layerStyleSettings.resolveBool(labelEnabledDef, kmeta)) return null;
    return renderLabelTemplate(
      layerStyleSettings.resolveString(labelPropertyDef, kmeta),
      f.turfFeature.properties,
    );
  }

  /// 組み立て済みのGeoJSONをMapSourceManagerに送る（変わったソースだけ送信される）
  void _pushFeaturesToSources() {
    // 3D 地図面には先に流す（3D が既定の間、MapLibre のソースは初期化されない）
    terrainSceneRevision.value++;
    if (!sourceManager.isInitialized) {
      // ソース未初期化 → dirty フラグを復元して次回リトライ
      layerCacheDirty = true;
      return;
    }
    final g = geoJson;
    sourceManager
      ..updateFeatures(MapSourceManager.kPolygons, g.polygons)
      ..updateFeatures(MapSourceManager.kPolygonsSel, g.selectedPolygons)
      ..updateFeatures(MapSourceManager.kLines, g.polylines)
      ..updateFeatures(MapSourceManager.kLinesSel, g.selectedPolylines)
      ..updateFeatures(MapSourceManager.kPoints, g.markers)
      ..updateFeatures(MapSourceManager.kPointsSel, g.selectedMarkers)
      ..updateFeatures(MapSourceManager.kImages, g.images)
      ..updateFeatures(MapSourceManager.kImagesSel, g.selectedImages)
      ..updateFeatures(MapSourceManager.kLineVertices, g.lineVertices)
      ..updateFeatures(
        MapSourceManager.kLineVerticesSel,
        g.selectedLineVertices,
      )
      ..updateFeatures(MapSourceManager.kPolyVertices, g.polygonVertices)
      ..updateFeatures(
        MapSourceManager.kPolyVerticesSel,
        g.selectedPolygonVertices,
      );
    // クラスタリング: 現在のズームでクラスタ表示を更新
    _refreshPointClusters();
  }

  /// 現在のズームレベルでクラスタ表示を更新
  void _refreshPointClusters() {
    if (!sourceManager.isInitialized) return;
    final zoom = mapController.raw != null ? mapController.camera.zoom : 16.0;
    sourceManager.refreshClusters(zoom);
  }

  /// オーバーレイWidgetマーカーを構築（現在位置、測量ポイント等の少数マーカーのみ）
  /// 頂点マーカーはCircleStyleLayerでGPU描画（_syncFeatureSources経由）
  List<ml.Marker> _buildOverlayWidgetMarkers(Set<LayerTreeNode> selectedSet) {
    final drawingState = GlobalDrawingState.instance;
    final currentTool = ref.read(currentToolProvider);
    return [
      // ペンツール: 線/ポリゴン描画中の1点目インジケータ
      if (currentTool is PenTool && drawingState.drawingLine.length == 1)
        _buildFirstPointIndicator(drawingState.drawingLine.first),
      if (currentTool is PenTool && drawingState.drawingPolygon.length == 1)
        _buildFirstPointIndicator(drawingState.drawingPolygon.first),
      // GPS測量ポイント
      if (currentTool is GpsTool) ...[
        for (int i = 0; i < drawingState.drawingLine.length; i++)
          _buildSurveyPointMarker(drawingState.drawingLine[i], i, true),
        for (int i = 0; i < drawingState.drawingPolygon.length; i++)
          _buildSurveyPointMarker(drawingState.drawingPolygon[i], i, false),
      ],
      // パーティ位置共有: 他メンバーのマーカー
      ...buildPartyPeerMarkers(ref.read(partySessionProvider)),
      // 現在位置マーカー — 最上位（常に見える）
      if (currentLocation != null)
        ml.Marker(
          point: currentLocation!.toGeographic(),
          size: const Size.square(64),
          child: _buildLocationMarkerWithCompass(),
        ),
    ];
  }

  /// 描画開始の1点目インジケータ（十字マーク）
  ml.Marker _buildFirstPointIndicator(LatLng point) {
    return ml.Marker(
      point: point.toGeographic(),
      size: const Size.square(18),
      child: const CustomPaint(painter: _CrosshairPainter()),
    );
  }

  /// GPS測量ポイントマーカー構築（maplibre Marker型）
  ml.Marker _buildSurveyPointMarker(LatLng point, int index, bool isLine) {
    final drawingState = GlobalDrawingState.instance;
    final metadataList =
        isLine ? drawingState.lineMetadata : drawingState.polygonMetadata;

    int pointCount = 1;
    try {
      if (index < metadataList.length) {
        final metadata = metadataList[index];
        if (metadata != null) {
          if (metadata.containsKey('point_count')) {
            pointCount = metadata['point_count'] as int? ?? 1;
          } else if (metadata.containsKey('collected_points') &&
              metadata['collected_points'] is List) {
            pointCount = (metadata['collected_points'] as List).length;
          }
        }
      }
    } catch (e) {
      pointCount = index + 1;
    }

    return ml.Marker(
      point: point.toGeographic(),
      size: const Size.square(32),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.purple,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Center(
          child: Text(
            '$pointCount',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  /// ジェスチャーレイヤー構築
  Widget _buildGestureLayer() {
    return Positioned.fill(
      child: Listener(
        onPointerMove: (event) {
          if (event.buttons == kMiddleMouseButton) {
            ref.read(currentToolProvider).onMiddleButtonMove(event, this);
          } else {
            ref
                .read(currentToolProvider)
                .addPointerToBuffer(event.localPosition);
          }
        },
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) {
            ref.read(currentToolProvider).onMiddleButtonDown(event, this);
          } else {
            ref
                .read(currentToolProvider)
                .addPointerToBuffer(event.localPosition);
          }
        },
        onPointerUp: (event) {
          if (event.buttons == 0) {
            ref.read(currentToolProvider).onMiddleButtonUp(event, this);
          }
          ref.read(currentToolProvider).clearPointerBuffer();
        },
        onPointerSignal: (event) {
          ref.read(currentToolProvider).onPointerSignal(event, this);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            ref.read(currentToolProvider).onTap(details, this);
          },
          onScaleStart: (details) {
            ref.read(currentToolProvider).onScaleStart(details, this);
          },
          onScaleUpdate: (details) {
            ref.read(currentToolProvider).onScaleUpdate(details, this);
          },
          onScaleEnd: (details) {
            ref.read(currentToolProvider).onScaleEnd(details, this);
          },
          child: Container(color: Colors.transparent),
        ),
      ),
    );
  }

  /// 描画プレビュー情報構築
  Widget _buildDrawingPreviewInfo() {
    if (ref.read(currentToolProvider) is! PenTool) {
      return const SizedBox.shrink();
    }

    final selected = ref.read(selectedLayerNodeProvider);
    final penTool = ref.read(currentToolProvider) as PenTool;
    final drawingState = GlobalDrawingState.instance;
    String? previewText;
    Offset? previewOffset;

    if (selected is PointLayerNode && penTool.pointPreview != null) {
      final pt = penTool.pointPreview!;
      previewText =
          'Coordinates: (${pt.latitude.toStringAsFixed(6)}, ${pt.longitude.toStringAsFixed(6)})';
      previewOffset = latLngToOffset(pt);
    } else if (selected is LineLayerNode &&
        drawingState.drawingLine.length >= 2) {
      final len = GeometryCalc.calcLineLength(drawingState.drawingLine);
      final centroid = GeometryCalc.calcLineCentroid(drawingState.drawingLine);
      previewText =
          len >= 10000
              ? 'Length: ${(len / 1000).toStringAsFixed(1)} km'
              : 'Length: ${len.toStringAsFixed(2)} m';
      previewOffset = latLngToOffset(centroid);
    } else if (selected is PolygonLayerNode &&
        drawingState.drawingPolygon.length >= 3) {
      final closed = closeRing(drawingState.drawingPolygon);
      final areaDeg2 = GeometryCalc.calcPolygonArea([closed]);
      final centroid = GeometryCalc.calcPolygonCentroid([closed]);
      final areaM2 = DegreeMeterConverter.convertAreaToMeters2(
        areaDeg2,
        centroid.latitude,
      );
      previewText =
          areaM2 >= 10000
              ? 'Area: ${(areaM2 / 10000).toStringAsFixed(3)} ha'
              : 'Area: ${areaM2.toStringAsFixed(3)} m²';
      previewOffset = latLngToOffset(centroid);
    }

    if (previewText != null && previewOffset != null) {
      return Positioned(
        left: previewOffset.dx + 10,
        top: previewOffset.dy - 30,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            previewText,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /// サイドパネル・ボトムパネルの背景色。
  ///
  /// > [!NOTE] 2026-08-26 に不透明にした
  /// > もとは `alpha: 0.9` で、地図がうっすら透けるようにしてあった。
  /// > 背景地図を航空写真にすると文字が読めなくなるほど目立つので、透過をやめた。
  /// > （「web版でドロワーに地図が透ける」として上がっていたが、web固有の
  /// > 合成バグではなくこの指定が原因だった。Android でも同じに見えていたはず）
  static const _panelBackgroundColor = Colors.white;

  /// ジャンプの着地点をドロワーの手前（見える範囲の中心）に寄せる
  @override
  EdgeInsets get jumpObscuredInsets => EdgeInsets.only(right: _effectiveDrawerWidth);

  /// ドロワーが実際に占めている幅（閉じていれば 0）
  double get _effectiveDrawerWidth {
    if (!drawerOpen) return 0;
    final maxWidth = MediaQuery.of(context).size.width * 0.67;
    return drawerWidth.clamp(minDrawerWidth, maxWidth);
  }

  /// 左下のフローティングボタン列（GPS測量ボタン・LeftBottomFab）が占める高さ。
  /// 矢印がこの下に潜るとタップがボタンに取られる（2026-09-06 実機で確認）ので、
  /// 縁インジケータの「見える範囲」からは除外する
  static const double _bottomButtonsInset = 96;

  /// 画面外にある現在位置の方向を示す矢印（タップで現在位置へ）
  ///
  /// ドロワーに隠れている部分は「見えていない」扱いにして、矢印はドロワーの手前に出す。
  Widget _buildOffscreenLocationIndicator() {
    return Positioned.fill(
      child: OffscreenLocationIndicator(
        location: currentLocation,
        mapController: mapController,
        project: (l) => terrainProjection?.project(l),
        repaint: cameraTickNotifier,
        obscured: EdgeInsets.only(
          right: _effectiveDrawerWidth,
          bottom: _bottomButtonsInset,
        ),
        semanticsLabel: t.map.jump.toCurrentLocation,
        onTap: jumpToCurrentLocation,
      ),
    );
  }

  /// レイヤードロワーパネル構築
  Widget _buildLayerDrawerPanel() {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxWidth = screenWidth * 0.67;
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: drawerWidth.clamp(minDrawerWidth, maxWidth),
      child: ResizableSidePanel(
        initialWidth: drawerWidth,
        minWidth: minDrawerWidth,
        maxWidth: maxWidth,
        backgroundColor: _panelBackgroundColor,
        handleColor: Colors.black.withValues(alpha: 0.08),
        onOpenChanged: (isOpen) {
          triggerSetState(() {
            drawerOpen = isOpen;
          });
        },
        onWidthChanged: (width) {
          triggerSetState(() {
            drawerWidth = width;
          });
        },
        child: LayerDrawer(
          currentNode: currentNode,
          onDirChanged: (node) {
            triggerSetState(() {
              currentNode = node;
            });
          },
          onJumpTo: jumpTo,
          onStartAppendMode: startAppendMode,
        ),
      ),
    );
  }

  /// 属性テーブルパネル構築（ボトムパネル）
  Widget _buildAttributeTablePanel() {
    final screenHeight = MediaQuery.of(context).size.height;
    final maxHeight = screenHeight * 0.7;
    return ResizableBottomPanel(
      initialHeight: attributeTableHeight.clamp(120.0, maxHeight),
      minHeight: 120,
      maxHeight: maxHeight,
      backgroundColor: _panelBackgroundColor,
      handleColor: Colors.black.withValues(alpha: 0.08),
      onOpenChanged: (isOpen) {
        if (!isOpen) {
          _closeAttributeTable();
        }
      },
      onHeightChanged: (height) {
        triggerSetState(() {
          attributeTableHeight = height;
        });
      },
      child: AttributeTableWidget(
        layer: attributeTableLayer!,
        onFeatureSelected: _onAttributeTableFeatureSelected,
        onAddFeature: () {
          ref
              .read(notificationCenterProvider.notifier)
              .add(title: t.editor.addFeatureWip, level: NotificationLevel.info);
        },
      ),
    );
  }
}

/// 描画開始地点を示す十字マーク（ポイントフィーチャと差別化）
class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    // 白アウトライン → オレンジ本体の順で描画
    final outline =
        Paint()
          ..color = Colors.white
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
    final fill =
        Paint()
          ..color = Colors.orange
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

    for (final p in [outline, fill]) {
      canvas.drawLine(Offset(cx - r, cy), Offset(cx + r, cy), p);
      canvas.drawLine(Offset(cx, cy - r), Offset(cx, cy + r), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
