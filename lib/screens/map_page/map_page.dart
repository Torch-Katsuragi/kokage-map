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
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../../core/launch_request.dart';
import '../../core/map_layout.dart';
import '../../devices/base/device_tool.dart';
import '../../editing/edit_overlay.dart';
import '../../editing/edit_panel.dart';
import '../../editing/edit_session.dart';
import '../../editing/edit_toolbar.dart';
import '../../i18n/strings.g.dart';
import '../../interfaces/terrain_projection.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../providers/device_tool_providers.dart';
import '../../providers/notification_providers.dart';
import '../../providers/project_providers.dart';
import '../../providers/selection_providers.dart';
import '../../providers/tool_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/kmeta_service.dart';
import '../../services/party/party_invite.dart';
import '../../tools/gps_tool.dart';
import '../../tools/map_tool.dart';
import '../../tools/pen_tool.dart';
import '../../tutorial/practice_project.dart';
import '../../tutorial/tutorial.dart';
import '../../utils/app_logger.dart';
import '../../utils/feature_calc_utils.dart';
import '../../utils/global_drawing_state.dart';
import '../../utils/keyboard_handler.dart';
import '../../widgets/attribute_table/attribute_table_widget.dart';
import '../../widgets/feature_detail_panel.dart';
import '../../widgets/feature_set_panel.dart';
import '../../widgets/feature_silhouette.dart';
import '../../widgets/info_panel_card.dart';
import '../../widgets/layer_drawer/layer_drawer.dart';
import '../../widgets/left_bottom_fab.dart';
import '../../widgets/map_appbar_actions.dart';
import '../../widgets/map_toolbar.dart';
import '../../widgets/resizable_bottom_panel.dart';
import '../../widgets/resizable_side_panel.dart';
// Mixins
import 'map_page_state_base.dart';
import 'mixins/index.dart';
// Widgets
import 'widgets/index.dart';
import 'widgets/map_menu_button.dart';
import 'widgets/party_controls.dart';
import 'widgets/terrain_map_layer.dart';
import 'widgets/tool_name_flash.dart';

/// Map and edit screen (main structure)
class RootMapsHomePage extends ConsumerStatefulWidget {
  const RootMapsHomePage({super.key});
  @override
  ConsumerState<RootMapsHomePage> createState() => _RootMapsHomePageState();
}

class _RootMapsHomePageState extends ConsumerState<RootMapsHomePage>
    with
        TickerProviderStateMixin,
        MapPageStateBase,
        MapJumpMixin,
        MapInitializationMixin,
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
    // チュートリアルは「レイヤ一覧を開く」「ペンを押す」から教えるので、閉じた一覧・パン・未選択で始める
    // （道具と選択は前の地図から持ち越される。プロバイダは組み立て中に変えられないので次のフレームで）
    final tutorial = ref.read(tutorialProvider) != null;
    _decideInitialLayout(tutorial: tutorial);
    initializeAllServices();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFirstFrame(tutorial: tutorial));
    LaunchRequest.incoming.addListener(_onLaunchRequest);
  }

  /// 始めの配置: レイヤ一覧を開くか、起動時のカメラを GPS の初回の位置に任せるか
  void _decideInitialLayout({required bool tutorial}) {
    // レイヤ一覧を開いて始めるかは画面の幅で決める（MediaQuery は initState では読めないので views から）
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    drawerOpen = !tutorial && MapLayout.layerListOpenAtStart(view.physicalSize / view.devicePixelRatio);
    // チュートリアルは「データが全部入る範囲」に合わせず、GPS の初回の位置へ飛ぶ（松本 2026-10-01。
    // 自分のいる場所から始め、練習のデータへはダブルタップで飛んでもらう）
    if (tutorial) initialViewDecided = true;
  }

  /// 最初のフレームの後: ルートとコントローラの登録、チュートリアルの初期状態、招待 URL・起動ルートの要求
  void _onFirstFrame({required bool tutorial}) {
    tutorialRoutes.mapRoute = ModalRoute.of(context);
    ref.read(mapControllerHolderProvider.notifier).set(mapController);
    if (tutorial) {
      ref.read(currentToolProvider.notifier).set(ref.read(panToolProvider));
      ref.read(selectedLayerNodeProvider.notifier).select(null);
      ref.read(selectedFeaturesProvider.notifier).set([]); // 前の練習の地物が選ばれたまま残る
    }
    // 招待URL（web の `?room=CODE`）経由の起動なら、参加ダイアログを
    // コード充填済みで開く（「ルーム参加がURLで済む」の受け側）。
    final inviteCode = consumePendingRoomCode();
    if (inviteCode != null && mounted) {
      showPartyEntry(context, ref, initialCode: inviteCode);
    }
    // 起動ルートのカメラ指定（`/map?lat=...`）。3D が attach したら合わせる
    _applyLaunchRequest(LaunchRequest.consumePending());
  }

  /// 3D が attach するまで待たせるカメラ指定
  LaunchRequest? _pendingLaunchCamera;

  void _onLaunchRequest() => _applyLaunchRequest(LaunchRequest.incoming.value);

  /// 外からの要求（起動時・起動中）を地図に反映する。
  /// プロジェクトの切替はここではしない（ホームに戻ってから開き直す。今のところ手動）
  void _applyLaunchRequest(LaunchRequest? req) {
    if (req == null || !mounted) return;
    if (req.reload) unawaited(reloadProjectFromDisk());
    if (!req.hasCamera) return;
    // 位置を指定されたら、GPS の初回フィックスで現在位置へ飛ぶ動きは要らない（上書きされてしまう）
    if (req.hasCenter) {
      movedToCurrentLocationOnce = true;
      initialViewDecided = true;
    }
    final p = terrainProjection;
    if (p == null) {
      _pendingLaunchCamera = req; // attach 時（_onProjectionChanged）に流す
      return;
    }
    _lookAtLaunch(p, req);
  }

  void _lookAtLaunch(TerrainProjection p, LaunchRequest req) => unawaited(
      p.lookAt(center: req.center, zoom: req.zoom, bearingDeg: req.bearing, pitchDeg: req.pitch, animate: false));

  /// 3D の地図面が組み上がった（null なら外れた）。保留していたカメラ指定を流し、
  /// レイヤのダブルタップなど、ホルダー経由の「寄せる」「移動」も 3D に流す
  /// （fit → jump の順。jumpOverride を置いた瞬間に組み上がる前の保留分が流れる）
  void _onProjectionChanged(TerrainProjection? p) {
    terrainProjection = p;
    final pendingLaunch = _pendingLaunchCamera;
    if (p != null && pendingLaunch != null) {
      _pendingLaunchCamera = null;
      _lookAtLaunch(p, pendingLaunch);
    }
    mapController.fitOverride = p == null ? null : (c, pad) => p.fitCoordinates(c, padding: pad);
    mapController.jumpOverride =
        p == null ? null : (c, z, _, {required animate}) => unawaited(p.jumpTo(c, z, animate: animate));
  }

  /// チュートリアルの決まった配置: 地図だけが前に出ていて、レイヤ一覧・表は閉じ、パン・何も選んでいない
  void _resetForTutorial(TutorialChapter chapter) {
    final me = ModalRoute.of(context);
    if (me != null) Navigator.of(context).popUntil((r) => r == me);
    GlobalDrawingState.instance.clear(isLine: true);
    GlobalDrawingState.instance.clear(isLine: false);
    if (showAttributeTable) _closeAttributeTable();
    triggerSetState(() => drawerOpen = false);
    ref.read(currentToolProvider.notifier).set(ref.read(panToolProvider));
    // GPS の章は記録先が要るので測点を選んでおく（選んでいないと「レイヤーが選択されていません」で止まる）
    final layers = ref.read(folderTreeProvider)?.getVisibleLayerNodes().whereType<LayerNode>() ?? const <LayerNode>[];
    ref.read(selectedLayerNodeProvider.notifier).select(chapter == TutorialChapter.gps
        ? layers.where((l) => isPracticeLayer(l, PracticeProject.pointsLayer)).firstOrNull
        : null);
    ref.read(selectedFeaturesProvider.notifier).set([]);
    // 練習のデータを触る章は、そのデータが収まる位置から始める（地図は自分のいる場所から開くので）
    const onData = {TutorialChapter.style, TutorialChapter.record, TutorialChapter.fix, TutorialChapter.photo};
    if (onData.contains(chapter)) {
      final coords = [
        for (final l in ref.read(folderTreeProvider)?.getVisibleLayerNodes().whereType<LayerNode>() ?? const <LayerNode>[])
          if (isPracticeGpkg(l.geoPackageFile.getAbsolutePath())) ...l.getAllCoordinates(),
      ];
      // 下は案内の札の分を空ける（札の裏に練習のデータが隠れて、色を変えても見えなかった）
      if (coords.isNotEmpty) mapController.fitCoordinates(coords, padding: const EdgeInsets.fromLTRB(60, 60, 60, 260));
    }
  }

  /// プロジェクトをディスクから読み直す（メニューの「読み直す」・`/map?reload=1`）。
  /// AI や QGIS が .gpkg / フォルダ設定（`.qgs`） / .qgs を書き換えたあとに、開き直さずに追いつく
  Future<void> reloadProjectFromDisk() async {
    AppLogger.debug('[MapPage] プロジェクトを読み直す');
    KMetaService.instance.clearCache();
    final root = ref.read(folderTreeProvider);
    if (root is FolderNode) root.invalidateMetaCache();
    for (final layer in ref.read(folderTreeProvider)?.getVisibleLayerNodes().whereType<LayerNode>() ?? const <LayerNode>[]) {
      layer.invalidateKmetaStyleCache();
      await layer.updateChildren();
    }
    await initializeProjectTree();
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
    if (mounted) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.map.reloaded,
            level: NotificationLevel.success,
          );
    }
  }

  /// 裏に回ったらコンパスを止め、戻ったら付け直す
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      resumeCompass();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      pauseCompass();
    }
  }

  @override
  void dispose() {
    LaunchRequest.incoming.removeListener(_onLaunchRequest);
    WidgetsBinding.instance.removeObserver(this);
    disposeAllServices();
    super.dispose();
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

  /// オーバーレイ画像の変形（ドラッグ中）。3D 地図面が枠とハンドルを描き直す
  @override
  void updateOverlayTransform(OverlayImageNode node) => terrainSceneRevision.value++;

  @override
  void onLayerStyleChanged() {
    if (mounted) {
      invalidateLayerCache(); // View 固有スタイルを持ち直して GeoJSON を組み直す
      triggerSetState(() {});
    }
  }

  @override
  void updateCurrentGpsInfo() {
    final info = gpsManager.currentInfo;
    final before = currentGpsInfo;
    // 表示に関わる値が同じなら組み立て直さない（フォアグラウンドサービスは同じ位置を毎秒送り直してくるので、
    // そのたびに地図ページ全体を組み立て直していた。2026-10-06）
    // 読むのは現在位置の詳細パネルだけ（開いているときに変わったら組み立て直す）
    if (before != null && (!showsCurrentLocationDetail || before.sameDisplayAs(info))) {
      currentGpsInfo = info;
      return;
    }
    triggerSetState(() => currentGpsInfo = info);
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
      ref.read(tutorialProvider.notifier).report(const AttributeTableToggled(true));
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
    ref.read(tutorialProvider.notifier).report(const AttributeTableToggled(false));
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
  // ビルドメソッド
  // =============================================

  @override
  Widget build(BuildContext context) {
    _listenProviders();

    // 選択状態を監視（変更時に自動rebuild）
    final selectedFeatures = ref.watch(selectedFeaturesProvider);
    final folderTree = ref.watch(folderTreeProvider);
    currentNode ??= folderTree;
    final currentTool = ref.watch(currentToolProvider);
    // 編集中なら属性タブか（編集中でなければ null）。頂点を動かすたびに変わる編集の中身では組み直さない
    // （編集の形・パネル・ツールバーはそれぞれが featureEditorProvider を聞いている）
    final editAttrsTab = ref.watch(featureEditorProvider.select((s) => s?.attrsTab));
    final editing = editAttrsTab != null;
    final layout = MapLayout.resolve(ref.watch(mapLayoutPresetSettingProvider), MediaQuery.of(context).size);

    // 編集中の ← （と端末の戻る）はホームへ戻らず編集をやめる（つい押してしまうので）
    return PopScope(
      canPop: !editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) cancelEdit(context, ref);
      },
      child: KeyboardShortcutWrapper(
        mapState: this,
        child: Scaffold(
          appBar: _buildAppBar(editing: editing),
          body: Column(
            children: [
              // 地図エリア（ボトムパネル表示時に縮む）
              Expanded(child: _buildMapArea(layout, currentTool, selectedFeatures, editing: editing)),
              // 下パネル: 属性テーブルが開いていればそれ、閉じていれば情報カード（排他。
              // 属性テーブルの行を選ぶ流れを切らないよう、表が開いている間の情報カードは地図の上に浮く）
              if (showAttributeTable && attributeTableLayer != null)
                _buildAttributeTablePanel()
              else if (layout.info == InfoPlacement.bottom && selectedFeatures.isNotEmpty)
                _buildInfoBottomPanel(selectedFeatures),
            ],
          ),
          floatingActionButton: DrawingActionButtons(
            onConfirmDrawing: onConfirmDrawing,
            onConfirmGpsSurvey: onConfirmGpsSurvey,
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        ),
      ),
    );
  }

  /// プロバイダの変化を地図ページの状態へつなぐ（build から呼ぶ）
  void _listenProviders() {
    ref.listen<int>(featureRefreshTriggerProvider, (prev, next) {
      if (prev != null && prev != next) {
        updateFeatures();
      }
    });

    // DeviceTool の内部状態変更で地図オーバーレイを再描画
    ref.listen<int>(deviceToolOverlayRefreshProvider, (prev, next) {
      if (prev != null && prev != next) {
        triggerSetState(() {});
      }
    });

    ref.listen<List<LayerTreeNode>>(selectedFeaturesProvider, (_, sel) {
      // 選択状態の変更でフィーチャソースを再同期
      syncFeatureSources();
      // 編集中の地物の選択が外れたら（パネルを閉じたら）編集を取り消す
      final ed = ref.read(featureEditorProvider);
      if (ed != null && !sel.contains(ed.feature)) ref.read(featureEditorProvider.notifier).cancel();
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

    // チュートリアル: 章に入るたびに決まった配置へ戻す（前の章で開いた設定や一覧が残っていると案内がずれる）
    ref.listen(tutorialProvider, (prev, s) {
      if (s != null && !s.menu && (prev == null || prev.index != s.index || prev.chapter != s.chapter) && s.step.clearSelection) {
        ref.read(selectedFeaturesProvider.notifier).set([]);
      }
      if (s == null || s.menu || s.index != 0) return;
      if (prev != null && !prev.menu && prev.chapter == s.chapter) return;
      _resetForTutorial(s.chapter);
    });

    // 編集の始まり・終わり: 元の地物を地図から隠す／戻す
    ref.listen(featureEditorProvider, (prev, next) {
      if ((prev == null) == (next == null)) return;
      invalidateLayerCache();
      if (next != null && showAttributeTable) _closeAttributeTable();
      // 終えたとき: 保存した形が地図に出るまで描き直す（隠していた間の場面が残って、動かすまで出なかった）
      if (next == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          invalidateLayerCache();
          terrainSceneRevision.value++;
        });
      }
    });
  }

  AppBar _buildAppBar({required bool editing}) {
    return AppBar(
      title: Text(p.basename(ref.watch(projectRootDirProvider) ?? t.common.appName)),
      actions: buildMapAppBarActions(
        showAttributeTable: showAttributeTable,
        drawerOpen: drawerOpen,
        onAttributeTableToggle: () {
          // 編集中は属性も編集のパネルで書き換える（表を開くと編集のパネルが隠れる）
          if (editing) return;
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
          ref.read(tutorialProvider.notifier).report(LayersPanelToggled(drawerOpen));
        },
        // ≡ メニュー（パーティ・水準器・設定を集約）はレイヤ一覧の左
        beforeLayerButton: [KeyedSubtree(key: TutorialTargets.menuButton, child: MapMenuButton(onReload: reloadProjectFromDisk))],
      ),
    );
  }

  /// 地図エリア: ツールバー・地図本体・レイヤ一覧・情報カード・下のボタン列
  Widget _buildMapArea(
    MapLayout layout,
    MapTool currentTool,
    List<LayerTreeNode> selectedFeatures, {
    required bool editing,
  }) {
    return Stack(
      children: [
        // ツールバー（左右は配置プリセットで決まる）
        if (editing)
          EditToolbar(side: layout.toolbar)
        else
          MapToolbar(onToolChanged: () => triggerSetState(() {}), side: layout.toolbar),
        // 地図本体
        Positioned.fill(
          left: layout.toolbarLeft ? 44 : 0,
          right: layout.toolbarLeft ? 0 : 44,
          child: _buildMapSurface(editing: editing),
        ),
        // Layer Drawer Panel（右サイド — 属性テーブルとは独立）
        if (drawerOpen) _buildLayerDrawerPanel(),
        // 情報カード。置き場所は配置プリセット（浮かせる／右パネル。下パネルは Column 側）
        if (selectedFeatures.isNotEmpty && _infoFloats(layout))
          Positioned(
            left: layout.toolbarLeft ? 60 : null,
            right: layout.toolbarLeft ? null : 60,
            top: 20,
            child: _buildInfoContent(selectedFeatures),
          ),
        if (selectedFeatures.isNotEmpty && layout.info == InfoPlacement.side)
          _buildInfoSidePanel(selectedFeatures),
        // 外部機器ツールのステータスパネル（DeviceTool抽象経由）
        if (currentTool is DeviceTool)
          ListenableBuilder(
            listenable: currentTool,
            builder: (ctx, _) => currentTool.buildStatusPanel(ctx),
          ),
        // 下のフローティングボタン列（ツールバーと同じ側）
        Positioned(
          left: layout.toolbarLeft ? 56 : null,
          right: layout.toolbarLeft ? null : 56,
          bottom: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (currentTool is GpsTool)
                // 長押し中の点数はツールが通知する（ここだけ組み直す）
                ListenableBuilder(
                  listenable: currentTool,
                  builder: (_, _) => GpsSurveyButtons(
                    isLongPressing: isLongPressing,
                    longPressGpsCount: currentTool.longPressGpsCount,
                    onRecordGpsPosition: recordGpsPosition,
                    onStartLongPressGpsSurvey: startLongPressGpsSurvey,
                    onStopLongPressGpsSurvey: stopLongPressGpsSurvey,
                    onOpenTrackExtraction: openTrackExtractionDialog,
                  ),
                ),
              // 地物の編集中は地図の上のボタンを出さない
              if (!editing) const LeftBottomFab(),
            ],
          ),
        ),
      ],
    );
  }

  /// 地図本体: ジェスチャ・3D の地図面・編集の重ね絵・描きかけの寸法・画面外の現在位置
  Widget _buildMapSurface({required bool editing}) {
    return Stack(
      children: [
        // 地図面は TerrainMapLayer（3D）。MapLibre は 2026-09-11 に地図ページから、2026-10-04 に依存ごと撤去
        const SizedBox.expand(),
        _buildGestureLayer(),
        // 3D 地形モード: 地図面を上に重ね、ジェスチャもここで受ける
        if (baseMapReady)
          Positioned.fill(
            child: TerrainMapLayer(
              mapState: this,
              baseMapService: baseMapService,
              geoJson: geoJson,
              sceneRevision: terrainSceneRevision,
              styleGroups: () => styleGroups,
              location: locationNotifier,
              gpsTrack: () => gpsHistoryRecorder.todayPoints,
              onProjectionChanged: _onProjectionChanged,
              mapBearingNotifier: mapBearingNotifier,
              cameraTickNotifier: cameraTickNotifier,
              heading: headingNotifier,
            ),
          ),
        // 編集中の形と取っ手（地図の場面には焼かず、カメラが動くたびに描き直す）
        EditOverlay(project: latLngToOffset, cameraTick: cameraTickNotifier),
        _buildDrawingPreviewInfo(),
        if (!editing) _buildOffscreenLocationIndicator(),
        const ToolNameFlash(),
      ],
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

  /// 描画プレビュー情報構築（描きかけが変わるたびにここだけ組み直す）
  Widget _buildDrawingPreviewInfo() {
    if (ref.read(currentToolProvider) is! PenTool) {
      return const SizedBox.shrink();
    }
    final drawingState = GlobalDrawingState.instance;
    return ListenableBuilder(
      listenable: drawingState,
      builder: (_, _) => _drawingPreviewLabel(drawingState),
    );
  }

  Widget _drawingPreviewLabel(GlobalDrawingState drawingState) {
    final selected = ref.read(selectedLayerNodeProvider);
    String? previewText;
    Offset? previewOffset;

    final pointPreview = drawingState.pointPreview;
    if (selected is PointLayerNode && pointPreview != null) {
      final pt = pointPreview;
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
      // calcPolygonArea はもう m²（turf）。度²として掛け直していて、桁が 10 桁ずれていた
      final areaM2 = GeometryCalc.calcPolygonArea([closed]);
      final centroid = GeometryCalc.calcPolygonCentroid([closed]);
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
    if (maxWidth <= minDrawerWidth) return maxWidth; // 起動直後の 0 幅など（clamp は下限 > 上限で落ちる）
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
      child: ValueListenableBuilder<LatLng?>(
        valueListenable: locationNotifier,
        builder: (context, loc, _) => OffscreenLocationIndicator(
        location: loc,
        project: (l) => terrainProjection?.project(l),
        repaint: cameraTickNotifier,
        obscured: EdgeInsets.only(
          right: _effectiveDrawerWidth,
          bottom: _bottomButtonsInset,
        ),
        semanticsLabel: t.map.jump.toCurrentLocation,
        onTap: jumpToCurrentLocation,
        ),
      ),
    );
  }

  /// 情報カードの高さ（下パネルのとき）
  double infoPanelHeight = 240;

  /// 情報カードを地図の上に浮かせるか（下パネルの配置で、属性テーブルが開いている間だけ）
  bool _infoFloats(MapLayout layout) =>
      layout.info == InfoPlacement.bottom && showAttributeTable && attributeTableLayer != null;

  Widget _buildInfoContent(List<LayerTreeNode> selected) => ref.read(featureEditorProvider) != null
      // 編集中は情報パネルの枠のまま編集に替わる
      ? const EditPanel()
      : selected.length == 1
          ? FeatureDetailPanel(feature: selected.first)
          : FeatureSetPanel(features: selected);

  /// 情報カードを下から出す（属性テーブルと同じ動き。下へ引き切ると選択解除）
  Widget _buildInfoBottomPanel(List<LayerTreeNode> selected) {
    // 編集中は上まで引き上げられる（属性が多いとき・メモを長く書くとき）
    final screenH = MediaQuery.of(context).size.height;
    // 地図とパネルが入る高さ（アプリバーと上の帯を除く）。上まで上げても地図を一筋残す
    // キーボードが出ている間はその分も除く（出たままの高さだとパネルがはみ出していた）
    final bodyH = screenH - MediaQuery.of(context).padding.top - kToolbarHeight - MediaQuery.viewInsetsOf(context).bottom;
    final edit = ref.read(featureEditorProvider);
    final maxHeight = edit != null ? math.max(160.0, bodyH - 56) : screenH * 0.6;
    // 情報パネル → 編集（少しせり上がる）→ 属性（上までせり上がる）→ 終われば元の高さへ下りる
    final target = edit == null
        ? infoPanelHeight.clamp(120.0, maxHeight)
        : edit.attrsTab
            ? maxHeight
            : math.max(infoPanelHeight, math.min(330.0, screenH * 0.45));
    return ResizableBottomPanel(
      initialHeight: infoPanelHeight.clamp(120.0, maxHeight),
      minHeight: 120,
      maxHeight: maxHeight,
      backgroundColor: _panelBackgroundColor,
      handleColor: Colors.black.withValues(alpha: 0.08),
      onOpenChanged: (isOpen) {
        if (!isOpen) ref.read(selectedFeaturesProvider.notifier).clear();
      },
      // 編集中に指で変えた高さは、情報パネルに戻ったときの高さにしない
      onHeightChanged: (height) {
        if (ref.read(featureEditorProvider) == null) infoPanelHeight = height;
      },
      targetHeight: target,
      // 編集中は編集のパネルが自分で形を敷く（直すたびに変わる）
      child: ref.read(featureEditorProvider) != null
          ? _buildInfoContent(selected)
          : _withSilhouette(selected, InfoPanelFill(child: _buildInfoContent(selected))),
    );
  }

  /// 情報パネルの背景に、選んだ地物の形を薄く敷く（1 つだけ選んでいるとき）
  Widget _withSilhouette(List<LayerTreeNode> selected, Widget content) {
    if (selected.length != 1) return content;
    return Stack(
      children: [
        Positioned.fill(child: FeatureSilhouette(feature: selected.first)),
        content,
      ],
    );
  }

  /// 情報カードを右のサイドパネルに（横長。ドロワーが開いていればその手前）
  Widget _buildInfoSidePanel(List<LayerTreeNode> selected) {
    return Positioned(
      right: _effectiveDrawerWidth,
      top: 0,
      bottom: 0,
      width: 280,
      child: Material(
        color: _panelBackgroundColor,
        elevation: 4,
        child: ref.read(featureEditorProvider) != null
            ? const EditPanel()
            : _withSilhouette(selected, InfoPanelFill(child: SingleChildScrollView(child: _buildInfoContent(selected)))),
      ),
    );
  }

  /// レイヤードロワーパネル構築
  Widget _buildLayerDrawerPanel() {
    final maxWidth = MediaQuery.of(context).size.width * 0.67;
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: _effectiveDrawerWidth,
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
          ref.read(tutorialProvider.notifier).report(LayersPanelToggled(isOpen));
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

