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
import 'package:flutter/material.dart';
import '../../i18n/strings.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:turf/turf.dart' as turf;
import '../../services/basemap_style_json.dart';
import '../../services/map_source_manager.dart';
import '../../core/platform_capabilities.dart';
import 'package:path/path.dart' as p;
import '../../utils/geo_converter.dart';
import '../../providers/project_providers.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/feature_node.dart';
// gps_track.dart は不要に（GpsHistoryRecorder に統合）
import '../../widgets/layer_drawer/layer_drawer.dart';
import '../../widgets/resizable_side_panel.dart';
import '../../widgets/resizable_bottom_panel.dart';
import '../../widgets/attribute_table/attribute_table_widget.dart';
import '../../widgets/compass_fan_painter.dart';
import '../../widgets/feature_detail_panel.dart';
import '../../widgets/left_bottom_fab.dart';
import '../../widgets/map/r_map_widget.dart';
import '../../widgets/map_toolbar.dart';
import '../../widgets/map_appbar_actions.dart';
import '../../utils/app_logger.dart';
import '../../utils/feature_calc_utils.dart';
import '../../utils/keyboard_handler.dart';
import '../../tools/pen_tool.dart';
import '../../tools/select_tool.dart';
import '../../tools/gps_tool.dart';
import '../../tools/overlay_transform_tool.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../devices/base/device_tool.dart';
import '../../providers/selection_providers.dart';
import '../../providers/tool_providers.dart';
import '../../utils/global_drawing_state.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../providers/device_tool_providers.dart';
import '../../providers/party_providers.dart';
import '../../models/party/peer_position.dart';
import '../../models/party/party_room.dart';
import '../../services/party/party_invite.dart';
import 'widgets/map_menu_button.dart';
import 'widgets/party_controls.dart';
import '../layer_style_settings_screen.dart'
    show
        layerStyleSettings,
        pointSizeDef,
        pointColorDef,
        lineWidthDef,
        lineColorDef,
        lineVertexPointsEnabledDef,
        lineVertexPointSizeFactorDef,
        polygonBorderWidthDef,
        polygonBorderColorDef,
        polygonFillColorDef,
        polygonFillOpacityDef,
        polygonBorderOpacityDef,
        polygonVertexPointsEnabledDef,
        polygonVertexPointSizeFactorDef,
        selectedColorDef,
        selectedMultiplierDef,
        clusteringEnabledDef,
        clusteringDisableZoomDef;

// Mixins
import 'map_page_state_base.dart';
import 'mixins/index.dart';

// Widgets
import 'widgets/index.dart';

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
      _syncOverlayImages();
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
      _applyLayerStyles();
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

  @override
  void updateOverlayTransform(OverlayImageNode node) {
    if (!sourceManager.isInitialized) return;
    final corners = node.cornerCoordinates;
    sourceManager.updateOverlayCoordinates(
      node.overlaySourceId,
      ml.LngLatQuad(
        topLeft: corners[0].toGeographic(),
        topRight: corners[1].toGeographic(),
        bottomRight: corners[2].toGeographic(),
        bottomLeft: corners[3].toGeographic(),
      ),
      imageUrl: node.imageUrl,
      layerId: node.overlayLayerId,
    );
    // triggerSetStateは呼ばない—ハンドルマーカーは​transformNotifier経由で局所rebuild
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
            ),
            // ≡ メニュー（パーティ・水準器・設定を集約）
            const MapMenuButton(),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(36),
            child: GpsInfoBar(
              gpsInfo: currentGpsInfo,
              headingNotifier: headingNotifier,
            ),
          ),
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
                        _buildMapLibreMap(isPanTool),
                        _buildGestureLayer(),
                        _buildDrawingPreviewInfo(),
                        _buildOffscreenLocationIndicator(),
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
      options: ml.MapOptions(
        initStyle: basemapStyleUri!,
        initCenter: defaultCenter.toGeographic(),
        initZoom: 16.0,
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
                        .map((offset) => offsetToLatLng(offset))
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
        ..._buildPartyTrackPolylines(),
        // 外部機器ツールのオーバーレイ（DeviceTool抽象経由）
        if (currentTool is DeviceTool)
          ...currentTool.buildOverlayLayers(),
        // 選択中オーバーレイの枠線 + 変形ハンドル接続線
        ..._buildOverlaySelectionLayers(selectedSet, currentTool),
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
                markers: _buildTransformHandleMarkers(currentTool),
              );
            },
          ),
      ],
    );
  }

  /// アクティブなbasemapレイヤIDのトラッキング（削除用）
  final List<String> _activeBasemapLayerIds = [];
  final List<String> _activeBasemapSourceIds = [];

  Future<void> _onMapStyleLoaded(ml.StyleController style) async {
    AppLogger.debug('[MAP] onStyleLoaded fired');
    mapControllerInstance.attachStyle(style);
    await _addBasemapSources(style);
    await sourceManager.initialize(style);

    // 現在のスタイル設定を反映
    _applyLayerStyles();

    // ソース初期化完了 → dirty フラグを強制セットして確実にフィーチャを送信
    invalidateLayerCache();
  }

  /// ベースマップソース追加（複数プロバイダ対応）
  /// activeLayerConfigで有効なプロバイダを取得し、各プロバイダにRasterSource + RasterStyleLayerを登録
  /// [belowLayerId] 指定時はそのレイヤの下に挿入（replaceBasemapSources用）
  Future<void> _addBasemapSources(
    ml.StyleController style, {
    String? belowLayerId,
  }) async {
    final layers = baseMapService.activeLayerConfig;
    if (layers.isEmpty) return;

    // web は `StyleController.addSource()` で RasterSource を登録できない
    // （maplibre_web 0.3.5 のバグ。詳細は basemap_style_json.dart）。
    // ソースは初期スタイルJSONに全プロバイダぶん焼き込んであるので、
    // ここではレイヤを積むだけでよい（`addLayer` は web でも正常に動く）。
    if (PlatformCapabilities.isWeb) {
      for (final (provider, opacity) in layers) {
        final layerId = basemapLayerId(provider.id);
        try {
          await style.addLayer(
            ml.RasterStyleLayer(
              id: layerId,
              sourceId: basemapSourceId(provider.id),
              paint: {'raster-opacity': opacity},
            ),
            belowLayerId: belowLayerId,
          );
          _activeBasemapLayerIds.add(layerId);
          AppLogger.debug(
            '[MAP] addBasemapLayer(web): ${provider.id} '
            'opacity=${opacity.toStringAsFixed(2)}',
          );
        } catch (e) {
          AppLogger.debug('[MAP] addBasemapLayer error (${provider.id}): $e');
        }
      }
      return;
    }

    for (final (provider, opacity) in layers) {
      final sourceId = basemapSourceId(provider.id);
      final layerId = basemapLayerId(provider.id);

      ml.RasterSource source;

      // Android + オフライン → mbtiles:// 直接読み込み
      if (PlatformCapabilities.supportsOfflineMBTiles &&
          !baseMapService.isNetworkAvailable) {
        final mbtilesPath = baseMapService.getMBTilesPath(provider.id);
        if (mbtilesPath != null) {
          source = ml.RasterSource(
            id: sourceId,
            url: 'mbtiles://$mbtilesPath',
            maxZoom: provider.maxZoom.toDouble(),
            tileSize: 256,
          );
        } else {
          final url = tileServer.isRunning
              ? tileServer.urlTemplate(provider.id)
              : provider.urlTemplate;
          source = ml.RasterSource(
            id: sourceId,
            tiles: [url],
            maxZoom: provider.maxZoom.toDouble(),
            tileSize: 256,
            attribution: provider.attribution,
          );
        }
      } else {
        // オンライン → TileServer経由（キャッシュ+フォールバック機能付き）
        final url = tileServer.isRunning
            ? tileServer.urlTemplate(provider.id)
            : provider.urlTemplate;
        source = ml.RasterSource(
          id: sourceId,
          tiles: [url],
          maxZoom: provider.maxZoom.toDouble(),
          tileSize: 256,
          attribution: provider.attribution,
        );
      }

      try {
        await style.addSource(source);
        await style.addLayer(
          ml.RasterStyleLayer(
            id: layerId,
            sourceId: sourceId,
            paint: {'raster-opacity': opacity},
          ),
          belowLayerId: belowLayerId,
        );
        _activeBasemapSourceIds.add(sourceId);
        _activeBasemapLayerIds.add(layerId);
        AppLogger.debug(
          '[MAP] addBasemapSource: ${provider.id} opacity=${opacity.toStringAsFixed(2)}',
        );
      } catch (e) {
        AppLogger.debug('[MAP] addBasemapSource error (${provider.id}): $e');
      }
    }
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

  /// ベースマップ切替（旧ソース全削除→新ソース追加）
  Future<void> replaceBasemapSource() async {
    final style = mapControllerInstance.style;
    if (style == null) return;

    // 既存の全basemapレイヤを削除
    for (final layerId in _activeBasemapLayerIds.reversed) {
      try { await style.removeLayer(layerId); } catch (_) {}
    }
    _activeBasemapLayerIds.clear();

    // ⚠ web のソースは初期スタイルJSONに焼き込んだもので、消すと二度と足せない
    // （`addSource` が壊れているのがそもそもの発端）。消すのは native だけ。
    if (!PlatformCapabilities.isWeb) {
      for (final sourceId in _activeBasemapSourceIds.reversed) {
        try { await style.removeSource(sourceId); } catch (_) {}
      }
      _activeBasemapSourceIds.clear();
    }

    await _addBasemapSources(
      style,
      belowLayerId: MapSourceManager.kPolygonsFill,
    );
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
    if (sourceManager.setStyleGroups(_buildStyleGroups())) {
      _applyLayerStyles();
    }

    final selectedSet = currentSelection.toSet();

    // 選択のみ変更: 選択ソースだけ再構築（通常ソースは不変→送信スキップ）
    if (!dataChanged && selectionChanged) {
      _rebuildSelectionOnly(selectedSet);
      _pushFeaturesToSources();
      return;
    }

    // 固有スタイルが1つでもあれば、フィーチャに「どのグループのものか」を載せる。
    //
    // ⚠ グループが無いときは載せない。属性が増えるとGeoJSONが太るし、
    //   何より「View 導入前と完全に同じ」を保てなくなる。
    final hasStyleGroups = sourceManager.styleGroups.isNotEmpty;
    Map<String, Object?>? styleProps(FeatureNode f, [String? name]) {
      if (!hasStyleGroups) return name == null ? null : {'name': name};
      final key = f.parent.styleKeyOf(f.rowId);
      return {
        if (name != null) 'name': name,
        MapSourceManager.kStyleProp: key,
      };
    }

    // ポリラインをmaplibre Feature型に変換（通常=全件、選択=追加オーバーレイ）
    cachedPolylines = [];
    cachedSelectedPolylines = [];
    for (final f in lineFeatures) {
      final geoGeom = _turfLineToGeo(f.turfFeature.geometry);
      if (geoGeom == null) continue;
      final feature = geo.Feature<geo.Geometry>(
        geometry: geoGeom,
        properties: styleProps(f),
      );
      cachedPolylines.add(feature);
      if (selectedSet.contains(f)) {
        cachedSelectedPolylines.add(feature);
      }
    }

    // ポリゴンをmaplibre Feature型に変換（通常=全件、選択=追加オーバーレイ）
    cachedPolygons = [];
    cachedSelectedPolygons = [];
    for (final f in polygonFeatures) {
      final geoGeom = _turfPolyToGeo(f.turfFeature.geometry);
      if (geoGeom == null) continue;
      final feature = geo.Feature<geo.Geometry>(
        geometry: geoGeom,
        properties: styleProps(f),
      );
      cachedPolygons.add(feature);
      if (selectedSet.contains(f)) {
        cachedSelectedPolygons.add(feature);
      }
    }

    // ポイントをmaplibre Feature型に変換（通常=全件、選択=追加オーバーレイ）
    cachedMarkers = [];
    cachedSelectedMarkers = [];
    for (final f in pointFeatures) {
      if (f.geometry == null) continue;
      for (final pt in f.geometry as List<LatLng>) {
        final feature = geo.Feature(
          geometry: geo.Point(pt.toGeographic()),
          properties: styleProps(f, f.name),
        );
        cachedMarkers.add(feature);
        if (selectedSet.contains(f)) {
          cachedSelectedMarkers.add(feature);
        }
      }
    }

    // ImageNodeをGeoJSON Feature化（通常=全件、選択=追加オーバーレイ）
    cachedImageFeatures = [];
    cachedSelectedImageFeatures = [];
    for (final photo in photoNodes.where((p) => p.hasLocation)) {
      final props = <String, Object?>{
        'name': photo.name,
        'has_direction': photo.direction != null,
        if (photo.direction != null) 'direction': photo.direction,
        if (photo.takenAt != null)
          'taken_at': photo.takenAt!.millisecondsSinceEpoch,
      };
      final feature = geo.Feature(
        geometry: geo.Point(photo.location!.toGeographic()),
        properties: props,
      );
      cachedImageFeatures.add(feature);
      if (selectedSet.contains(photo)) {
        cachedSelectedImageFeatures.add(feature);
      }
    }

    // ライン頂点データ生成（通常=全件、選択=追加オーバーレイ）
    cachedLineVertices = [];
    cachedLineVerticesSel = [];
    if (layerStyleSettings.getBool(lineVertexPointsEnabledDef)) {
      for (final f in lineFeatures) {
        final allPts = _extractAllLineVertices(f.turfFeature.geometry);
        for (final pt in allPts) {
          cachedLineVertices.add(geo.Feature(geometry: geo.Point(pt)));
        }
        if (selectedSet.contains(f)) {
          for (final pt in allPts) {
            cachedLineVerticesSel.add(geo.Feature(geometry: geo.Point(pt)));
          }
        }
      }
    }

    // ポリゴン頂点データ生成（通常=全件、選択=追加オーバーレイ）
    cachedPolyVertices = [];
    cachedPolyVerticesSel = [];
    if (layerStyleSettings.getBool(polygonVertexPointsEnabledDef)) {
      for (final f in polygonFeatures) {
        final allPts = _extractAllPolyVertices(f.turfFeature.geometry);
        for (final pt in allPts) {
          cachedPolyVertices.add(geo.Feature(geometry: geo.Point(pt)));
        }
        if (selectedSet.contains(f)) {
          for (final pt in allPts) {
            cachedPolyVerticesSel.add(geo.Feature(geometry: geo.Point(pt)));
          }
        }
      }
    }

    // MapSourceManager経由でGeoJSONソースを更新（変更時のみ送信）
    _pushFeaturesToSources();

    // オーバーレイ画像の同期
    _syncOverlayImages();
  }

  /// 選択変更のみの場合の軽量パス: 選択リストだけを再構築
  /// 通常リスト（cachedPolylines等）は前回のまま保持 → GeoJSON不変 → 送信スキップ
  void _rebuildSelectionOnly(Set<LayerTreeNode> selectedSet) {
    // ポリライン選択
    cachedSelectedPolylines = [];
    for (final f in lineFeatures) {
      if (!selectedSet.contains(f)) continue;
      final geoGeom = _turfLineToGeo(f.turfFeature.geometry);
      if (geoGeom == null) continue;
      cachedSelectedPolylines.add(geo.Feature<geo.Geometry>(geometry: geoGeom));
    }

    // ポリゴン選択
    cachedSelectedPolygons = [];
    for (final f in polygonFeatures) {
      if (!selectedSet.contains(f)) continue;
      final geoGeom = _turfPolyToGeo(f.turfFeature.geometry);
      if (geoGeom == null) continue;
      cachedSelectedPolygons.add(geo.Feature<geo.Geometry>(geometry: geoGeom));
    }

    // ポイント選択
    cachedSelectedMarkers = [];
    for (final f in pointFeatures) {
      if (!selectedSet.contains(f) || f.geometry == null) continue;
      for (final pt in f.geometry as List<LatLng>) {
        cachedSelectedMarkers.add(geo.Feature(
          geometry: geo.Point(pt.toGeographic()),
          properties: {'name': f.name},
        ));
      }
    }

    // ImageNode選択
    cachedSelectedImageFeatures = [];
    for (final photo in photoNodes.where((p) => p.hasLocation)) {
      if (!selectedSet.contains(photo)) continue;
      cachedSelectedImageFeatures.add(geo.Feature(
        geometry: geo.Point(photo.location!.toGeographic()),
        properties: <String, Object?>{
          'name': photo.name,
          'has_direction': photo.direction != null,
          if (photo.direction != null) 'direction': photo.direction,
          if (photo.takenAt != null)
            'taken_at': photo.takenAt!.millisecondsSinceEpoch,
        },
      ));
    }

    // ライン頂点選択
    cachedLineVerticesSel = [];
    if (layerStyleSettings.getBool(lineVertexPointsEnabledDef)) {
      for (final f in lineFeatures) {
        if (!selectedSet.contains(f)) continue;
        for (final pt in _extractAllLineVertices(f.turfFeature.geometry)) {
          cachedLineVerticesSel.add(geo.Feature(geometry: geo.Point(pt)));
        }
      }
    }

    // ポリゴン頂点選択
    cachedPolyVerticesSel = [];
    if (layerStyleSettings.getBool(polygonVertexPointsEnabledDef)) {
      for (final f in polygonFeatures) {
        if (!selectedSet.contains(f)) continue;
        for (final pt in _extractAllPolyVertices(f.turfFeature.geometry)) {
          cachedPolyVerticesSel.add(geo.Feature(geometry: geo.Point(pt)));
        }
      }
    }
  }

  // ============================================================
  // turf → geobase 変換ヘルパー（_syncFeatureSources用）
  // ============================================================

  geo.Geometry? _turfLineToGeo(turf.GeometryObject? geom) {
    if (geom is turf.MultiLineString) {
      return geo.MultiLineString.from(
        geom.coordinates.map(
          (line) => line.map(
            (p) => geo.Geographic(lon: p.lng.toDouble(), lat: p.lat.toDouble()),
          ),
        ),
      );
    }
    if (geom is turf.LineString) {
      return geo.LineString.from(
        geom.coordinates.map(
          (p) => geo.Geographic(lon: p.lng.toDouble(), lat: p.lat.toDouble()),
        ),
      );
    }
    return null;
  }

  geo.Geometry? _turfPolyToGeo(turf.GeometryObject? geom) {
    if (geom is turf.MultiPolygon) {
      return geo.MultiPolygon.from(
        geom.coordinates.map(
          (rings) => rings.map(
            (ring) => ring.map(
              (p) => geo.Geographic(
                lon: p.lng.toDouble(),
                lat: p.lat.toDouble(),
              ),
            ),
          ),
        ),
      );
    }
    if (geom is turf.Polygon) {
      return geo.Polygon.from(
        geom.coordinates.map(
          (ring) => ring.map(
            (p) => geo.Geographic(lon: p.lng.toDouble(), lat: p.lat.toDouble()),
          ),
        ),
      );
    }
    return null;
  }

  List<geo.Geographic> _extractAllLineVertices(turf.GeometryObject? geom) {
    final pts = <geo.Geographic>[];
    if (geom is turf.MultiLineString) {
      for (final line in geom.coordinates) {
        for (final p in line) {
          pts.add(geo.Geographic(
            lon: p.lng.toDouble(),
            lat: p.lat.toDouble(),
          ));
        }
      }
    } else if (geom is turf.LineString) {
      for (final p in geom.coordinates) {
        pts.add(geo.Geographic(
          lon: p.lng.toDouble(),
          lat: p.lat.toDouble(),
        ));
      }
    }
    return pts;
  }

  List<geo.Geographic> _extractAllPolyVertices(turf.GeometryObject? geom) {
    final pts = <geo.Geographic>[];
    void addRingVertices(List<turf.Position> ring) {
      final positions = List<turf.Position>.from(ring);
      if (positions.length >= 2 &&
          positions.first.lat == positions.last.lat &&
          positions.first.lng == positions.last.lng) {
        positions.removeLast();
      }
      for (final p in positions) {
        pts.add(geo.Geographic(
          lon: p.lng.toDouble(),
          lat: p.lat.toDouble(),
        ));
      }
    }

    if (geom is turf.MultiPolygon) {
      for (final rings in geom.coordinates) {
        for (final ring in rings) {
          addRingVertices(ring);
        }
      }
    } else if (geom is turf.Polygon) {
      for (final ring in geom.coordinates) {
        addRingVertices(ring);
      }
    }
    return pts;
  }

  /// キャッシュ済みフィーチャをMapSourceManagerに送信
  void _pushFeaturesToSources() {
    if (!sourceManager.isInitialized) {
      // ソース未初期化 → dirty フラグを復元して次回リトライ
      layerCacheDirty = true;
      return;
    }
    sourceManager.updateFeatures(MapSourceManager.kPolygons, cachedPolygons);
    sourceManager.updateFeatures(
      MapSourceManager.kPolygonsSel,
      cachedSelectedPolygons,
    );
    sourceManager.updateFeatures(MapSourceManager.kLines, cachedPolylines);
    sourceManager.updateFeatures(
      MapSourceManager.kLinesSel,
      cachedSelectedPolylines,
    );
    sourceManager.updateFeatures(MapSourceManager.kPoints, cachedMarkers);
    sourceManager.updateFeatures(
      MapSourceManager.kPointsSel,
      cachedSelectedMarkers,
    );
    sourceManager.updateFeatures(MapSourceManager.kImages, cachedImageFeatures);
    sourceManager.updateFeatures(
      MapSourceManager.kImagesSel,
      cachedSelectedImageFeatures,
    );
    sourceManager.updateFeatures(
      MapSourceManager.kLineVertices,
      cachedLineVertices,
    );
    sourceManager.updateFeatures(
      MapSourceManager.kLineVerticesSel,
      cachedLineVerticesSel,
    );
    sourceManager.updateFeatures(
      MapSourceManager.kPolyVertices,
      cachedPolyVertices,
    );
    sourceManager.updateFeatures(
      MapSourceManager.kPolyVerticesSel,
      cachedPolyVerticesSel,
    );
    // クラスタリング: 現在のズームでクラスタ表示を更新
    _refreshPointClusters();
  }

  /// オーバーレイ画像をMapLibre ImageSourceとして同期
  /// 追加・削除の差分管理を行う
  void _syncOverlayImages() {
    if (!sourceManager.isInitialized) return;

    final currentIds = <String>{};
    for (final node in overlayImageNodes) {
      currentIds.add(node.overlaySourceId);
    }

    // 削除: 前回あったが今回ないソースを削除
    final toRemove = activeOverlaySourceIds.difference(currentIds);
    for (final id in toRemove) {
      final layerId = id.replaceFirst('overlay-src-', 'overlay-lyr-');
      sourceManager.removeOverlayImage(id, layerId);
    }

    // 追加: 今回あるが前回なかったソースを追加
    final toAdd = currentIds.difference(activeOverlaySourceIds);
    for (final node in overlayImageNodes) {
      if (toAdd.contains(node.overlaySourceId)) {
        final corners = node.cornerCoordinates;
        sourceManager.addOverlayImage(
          sourceId: node.overlaySourceId,
          layerId: node.overlayLayerId,
          imageUrl: node.imageUrl,
          coordinates: ml.LngLatQuad(
            topLeft: geo.Geographic(
              lon: corners[0].longitude, lat: corners[0].latitude,
            ),
            topRight: geo.Geographic(
              lon: corners[1].longitude, lat: corners[1].latitude,
            ),
            bottomRight: geo.Geographic(
              lon: corners[2].longitude, lat: corners[2].latitude,
            ),
            bottomLeft: geo.Geographic(
              lon: corners[3].longitude, lat: corners[3].latitude,
            ),
          ),
        );
      }
    }

    activeOverlaySourceIds = currentIds;
  }

  /// 現在のズームレベルでクラスタ表示を更新
  void _refreshPointClusters() {
    if (!sourceManager.isInitialized) return;
    final zoom = mapController.raw != null ? mapController.camera.zoom : 16.0;
    sourceManager.refreshClusters(zoom);
  }

  /// View（とレイヤ）に固有のスタイルを、描画用のグループに落とす。
  ///
  /// > [!IMPORTANT] 「グローバル設定にKMetaを重ねる」規則はここにしか無い
  /// > `SettingsStore.resolveXxx(def, kmeta)` が合成を担当する。
  /// > `MapSourceManager` には解決済みの値だけを渡し、設定の知識を持ち込まない。
  ///
  /// 固有スタイルが1つも無ければ空リストを返す。そのとき描画は
  /// View 導入前とまったく同じになる。
  List<MapStyleGroup> _buildStyleGroups() {
    final style = layerStyleSettings;
    final groups = <MapStyleGroup>[];
    final seen = <String>{};

    // 可視レイヤを、ツリーの並び（＝z順の根拠）で辿る
    final tree = ref.read(folderTreeProvider);
    final layers =
        tree == null
            ? const <LayerNode>[]
            : tree.getVisibleLayerNodes().whereType<LayerNode>();

    for (final layer in layers) {
      for (final entry in layer.styleGroups.entries) {
        if (!seen.add(entry.key)) continue;
        final kmeta = entry.value;
        groups.add(
          MapStyleGroup(
            key: entry.key,
            fillHex: MapSourceManager.colorToHex(
              style.resolveColor(polygonFillColorDef, kmeta),
            ),
            fillOpacity: style.resolveDouble(polygonFillOpacityDef, kmeta),
            outlineHex: MapSourceManager.colorToHex(
              style.resolveColor(polygonBorderColorDef, kmeta),
            ),
            outlineOpacity: style.resolveDouble(polygonBorderOpacityDef, kmeta),
            borderWidth: style.resolveDouble(polygonBorderWidthDef, kmeta),
            lineHex: MapSourceManager.colorToHex(
              style.resolveColor(lineColorDef, kmeta),
            ),
            lineWidth: style.resolveDouble(lineWidthDef, kmeta),
            pointHex: MapSourceManager.colorToHex(
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
  void _applyLayerStyles() {
    final style = layerStyleSettings;
    sourceManager.setStyleGroups(_buildStyleGroups());
    // クラスタリング設定を反映
    final pointSize = style.getDouble(pointSizeDef);
    sourceManager.configureClustering(
      enabled: style.getBool(clusteringEnabledDef),
      radius: (pointSize * 2).round(),
      maxZoom: style.getInt(clusteringDisableZoomDef),
    );
    sourceManager.updateLayerStyles(
      polygonFillColor: style.getColor(polygonFillColorDef),
      polygonFillOpacity: style.getDouble(polygonFillOpacityDef),
      polygonOutlineColor: style.getColor(polygonBorderColorDef),
      polygonOutlineOpacity: style.getDouble(polygonBorderOpacityDef),
      polygonBorderWidth: style.getDouble(polygonBorderWidthDef),
      lineColor: style.getColor(lineColorDef),
      lineWidth: style.getDouble(lineWidthDef),
      pointColor: style.getColor(pointColorDef),
      pointSize: pointSize,
      selectedColor: style.getColor(selectedColorDef),
      selectedMultiplier: style.getDouble(selectedMultiplierDef),
      lineVertexEnabled: style.getBool(lineVertexPointsEnabledDef),
      lineVertexSizeFactor: style.getDouble(lineVertexPointSizeFactorDef),
      polygonVertexEnabled: style.getBool(polygonVertexPointsEnabledDef),
      polygonVertexSizeFactor: style.getDouble(polygonVertexPointSizeFactorDef),
    );
  }

  /// 選択中オーバーレイの枠線レイヤーを構築
  /// - 選択中: 青い矩形枠（常時表示）
  /// - 変形ツール時: 回転ハンドルの接続線も追加
  List<ml.Layer> _buildOverlaySelectionLayers(
    Set<LayerTreeNode> selectedSet,
    dynamic currentTool,
  ) {
    final layers = <ml.Layer>[];

    // 選択されたOverlayImageNodeの枠線
    for (final node in selectedSet) {
      if (node is! OverlayImageNode) continue;
      final corners = node.cornerCoordinates;
      layers.add(ml.PolylineLayer(
        polylines: [
          geo.Feature(
            geometry: geo.LineString.from([
              ...corners.map((c) => c.toGeographic()),
              corners[0].toGeographic(), // リングを閉じる
            ]),
          ),
        ],
        color: Colors.blue,
        width: 2,
      ));
    }

    // 変形ツール時: 回転ハンドルの接続線（上辺中点→回転ハンドル）
    if (currentTool is OverlayTransformTool && currentTool.target != null) {
      final target = currentTool.target!;
      final corners = target.cornerCoordinates;
      final topMid = LatLng(
        (corners[0].latitude + corners[1].latitude) / 2,
        (corners[0].longitude + corners[1].longitude) / 2,
      );
      final rotatePos = currentTool.rotationHandlePosition;
      if (rotatePos != null) {
        layers.add(ml.PolylineLayer(
          polylines: [
            geo.Feature(
              geometry: geo.LineString.from([
                topMid.toGeographic(),
                rotatePos.toGeographic(),
              ]),
            ),
          ],
          color: Colors.blue.withValues(alpha: 0.5),
          width: 1,
        ));
      }
    }

    return layers;
  }

  /// オーバーレイ変形ハンドルマーカーを構築（Photoshop風: 四隅+回転）
  List<ml.Marker> _buildTransformHandleMarkers(OverlayTransformTool tool) {
    if (tool.target == null) return [];
    final target = tool.target!;
    final corners = target.cornerCoordinates;
    final markers = <ml.Marker>[];

    // 四隅のリサイズハンドル（白丸+青ボーダー）
    for (final corner in corners) {
      markers.add(ml.Marker(
        point: corner.toGeographic(),
        size: const Size.square(24),
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.blue, width: 2.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ));
    }

    // 回転ハンドル（緑丸+回転アイコン）
    final rotatePos = tool.rotationHandlePosition;
    if (rotatePos != null) {
      markers.add(ml.Marker(
        point: rotatePos.toGeographic(),
        size: const Size.square(28),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.green.shade600,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4),
            ],
          ),
          child: const Icon(
            Icons.rotate_right,
            size: 16,
            color: Colors.white,
          ),
        ),
      ));
    }

    return markers;
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
      ..._buildPartyPeerMarkers(),
      // 現在位置マーカー — 最上位（常に見える）
      if (currentLocation != null)
        ml.Marker(
          point: currentLocation!.toGeographic(),
          size: const Size.square(64),
          child: _buildLocationMarkerWithCompass(),
        ),
    ];
  }

  /// パーティの他メンバー位置マーカー
  List<ml.Marker> _buildPartyPeerMarkers() {
    final session = ref.read(partySessionProvider);
    if (session.peers.isEmpty) return const [];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final markers = <ml.Marker>[];
    for (final peer in session.peers.values) {
      // メンバー一覧に居ないpeerはキック済みの残骸（live はhostが消せない）。
      // 一覧ロード前（空）のときは描く。
      if (session.members.isNotEmpty &&
          !session.members.any((m) => m.uid == peer.uid)) {
        continue;
      }
      final member = session.members.firstWhere(
        (m) => m.uid == peer.uid,
        orElse: () => PartyMember(uid: peer.uid, name: '', role: PartyRole.guest),
      );
      markers.add(
        ml.Marker(
          point: LatLng(peer.latitude, peer.longitude).toGeographic(),
          size: const Size(140, 70),
          child: _buildPeerMarker(peer, member.name, nowMs),
        ),
      );
    }
    return markers;
  }

  /// パーティの仲間の圏外区間軌跡（gap backfill の受信側）
  ///
  /// 「ブラックアウト中どこを通ったか」をピアマーカーと同系色の細線で描く。
  /// 揮発データ（ルーム退出で消える。GeoPackageには保存しない）。
  List<ml.PolylineLayer> _buildPartyTrackPolylines() {
    final session = ref.read(partySessionProvider);
    if (session.tracks.isEmpty) return const [];
    final layers = <ml.PolylineLayer>[];
    for (final entry in session.tracks.entries) {
      // キック済みメンバーの軌跡は描かない（マーカーと同じ判定）
      if (session.members.isNotEmpty &&
          !session.members.any((m) => m.uid == entry.key)) {
        continue;
      }
      layers.add(
        ml.PolylineLayer(
          polylines: [
            for (final track in entry.value)
              geo.Feature(
                geometry: geo.LineString.from(
                  track.points.toGeographics(),
                ),
              ),
          ],
          color: Colors.deepOrange.withValues(alpha: 0.5),
          width: 3,
        ),
      );
    }
    return layers;
  }

  /// 他メンバー1人のマーカーウィジェット（鮮度で淡色化＋経過時間ラベル）
  Widget _buildPeerMarker(PeerPosition peer, String name, int nowMs) {
    final freshness = peer.freshnessAt(nowMs);
    final double opacity;
    final Color color;
    switch (freshness) {
      case PeerFreshness.fresh:
        opacity = 1.0;
        color = Colors.deepOrange;
      case PeerFreshness.stale:
        opacity = 0.6;
        color = Colors.deepOrange;
      case PeerFreshness.lost:
        opacity = 0.4;
        color = Colors.blueGrey;
    }
    final displayName = name.isEmpty ? t.party.memberFallback : name;
    final label = freshness == PeerFreshness.fresh
        ? displayName
        : '$displayName・${_peerAgeLabel(peer.ageAt(nowMs))}';
    return Opacity(
      opacity: opacity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  /// 経過時間の短いラベル
  String _peerAgeLabel(Duration age) {
    if (age.inMinutes >= 1) return t.party.minAgo(min: age.inMinutes);
    return t.party.secAgo(sec: age.inSeconds);
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
        repaint: cameraTickNotifier,
        obscured: EdgeInsets.only(
          right: _effectiveDrawerWidth,
          bottom: _bottomButtonsInset,
        ),
        semanticsLabel: t.map.jump.toCurrentLocation,
        onTap: () => jumpToCurrentLocation(),
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
          onJumpTo: (latLng) => jumpTo(latLng),
          onStartAppendMode: (feature) {
            startAppendMode(feature);
          },
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
