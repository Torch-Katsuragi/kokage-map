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
// Root Maps: 初期化処理Mixin
// MapPageの各種サービス初期化処理を分離
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/platform_capabilities.dart';
import '../../../utils/app_logger.dart';
import '../../../providers/project_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../models/nodes/layer_tree_node.dart';
import '../../../models/nodes/folder_node.dart';
import '../../../models/nodes/geopackage_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../services/google_drive/index.dart';
import '../../../services/google_drive/auto_sync_service.dart';
import '../../../services/tile_server.dart';
import '../../../services/basemap_style_json.dart';
import '../map_page_state_base.dart';
import 'map_jump_mixin.dart';
import '../../../services/qgis/qgs_read_back.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../providers/notification_providers.dart';
import '../../../utils/geo_converter.dart';
import '../../layer_style_settings_screen.dart' show layerStyleSettings;

/// 初期化処理Mixin
/// プロジェクトツリー、GPS、背景地図、コンパスの初期化を担当
mixin MapInitializationMixin<T extends ConsumerStatefulWidget>
    on MapPageStateBase<T>, MapJumpMixin<T> {
  // =============================================
  // 初期化処理
  // =============================================

  /// 全サービスの初期化を実行
  Future<void> initializeAllServices() async {
    AppLogger.debug('[Init] start');

    if (ref.read(folderTreeProvider) == null) {
      final projectDir = ref.read(projectRootDirProvider);
      if (projectDir != null) {
        final rootNode = await FolderNode.createRootNode(projectDir);
        ref.read(folderTreeProvider.notifier).set(rootNode);
      } else {
        ref
            .read(folderTreeProvider.notifier)
            .set(FolderNode("Home", visible: true));
      }
    }
    currentNode = ref.read(folderTreeProvider);

    // 背景地図サービス初期化（TileServer起動を最優先）
    await initializeBaseMapService();

    // ツリー初期化とGPS初期化は互いに独立なので並列実行
    await Future.wait([
      // ブランチ1: プロジェクトツリー + フィーチャ
      () async {
        await layerStyleSettings.load();
        layerStyleSettings.addListener(onLayerStyleChanged);
        await initializeProjectTree();
      }(),
      // ブランチ2: GPS → 履歴 → コンパス
      () async {
        await initializeGpsManager();
        await initializeGpsHistoryRecorder();
        await initializeCompass();
      }(),
    ]);

    AppLogger.debug('[Init] complete');
  }

  /// プロジェクトツリーの初期化（非同期）
  /// ツリー構造が読み込まれた時点でUIに反映し、
  /// 重いフィーチャパースはその後ろで実行する
  Future<void> initializeProjectTree() async {
    AppLogger.debug('[Init] projectTree start');
    final rootNode = ref.read(folderTreeProvider);
    if (rootNode != null) {
      try {
        await updateNodeRecursively(rootNode);
      } catch (e) {
        AppLogger.debug('[Init] projectTree error (部分的に初期化): $e');
      }

      // QGIS 側で `.qgs` が保存されていれば、View・スタイル・可視性を読み戻す
      if (rootNode is FolderNode) {
        try {
          final readBack = await const QgsReadBack().run(rootNode);
          if (readBack != null) {
            final notifier = ref.read(notificationCenterProvider.notifier);
            notifier.add(
              title: t.qgis.readBack(
                file: readBack.fileName,
                count: readBack.importedViewCount,
              ),
              level: NotificationLevel.info,
            );
            if (readBack.discarded.isNotEmpty) {
              notifier.add(
                title: t.qgis.discarded(
                  count: readBack.discarded.length,
                  names: readBack.discarded.join(' / '),
                ),
                level: NotificationLevel.warning,
              );
            }
          }
        } catch (e) {
          AppLogger.debug('[Init] QGIS 読み戻しに失敗: $e');
        }
      }

      // ツリー構造が揃った時点でDrawerに反映（フィーチャ読込を待たない）
      triggerSetState(() {});

      try {
        await updateFeatures();
        triggerSetState(() {});
      } catch (e) {
        AppLogger.debug('[Init] updateFeatures error: $e');
      }

      // AutoSyncServiceを起動（WiFi時に自動同期、conflict時はサブタイトル通知）
      if (PlatformCapabilities.supportsDriveSyncStatusCheck) {
        AutoSyncService.instance.start(
          root: rootNode,
          onStatusChanged: () => triggerSetState(() {}),
          onRefreshNeeded: (node) => _updateChildrenRecursive(node),
        );
      }
    }
    AppLogger.debug('[Init] projectTree complete');
  }

  /// 子ノードを再帰的に更新（Pull後のツリーリフレッシュ用）
  Future<void> _updateChildrenRecursive(LayerTreeNode node) async {
    await node.updateChildren();
    for (final child in node.children) {
      if (child is FolderNode) {
        await _updateChildrenRecursive(child);
      } else if (child is GeoPackageNode) {
        await child.updateChildren();
      }
    }
  }

  /// ノードを再帰的に更新（サブフォルダ・GeoPackage・レイヤすべて）
  /// 兄弟ノードは並列処理（異なる.gpkgは別DB接続なので安全）
  /// 個別ノードの失敗は握りつぶし、成功したノードだけでツリーを構築する
  Future<void> updateNodeRecursively(LayerTreeNode node) async {
    try {
      await node.ensureInitialized();
    } catch (e) {
      AppLogger.debug('[Init] ノード初期化失敗 "${node.name}": $e');
      return;
    }

    // 兄弟ノードをFuture.waitで並列初期化（個別失敗は伝播させない）
    final childFutures = node.children
        .where((c) => c is FolderNode || c is GeoPackageNode)
        .map((c) => updateNodeRecursively(c));

    await Future.wait(childFutures, eagerError: false);
  }

  /// 背景地図サービス初期化（タイルサーバーも起動）
  Future<void> initializeBaseMapService() async {
    try {
      await baseMapService.initialize();

      if (PlatformCapabilities.supportsLocalTileServer) {
        await tileServer.start();

        // フォントPBFをキャッシュ（初回オンライン時にダウンロード）
        final fontDir = await TileServer.ensureFontCache();

        // fontDir が null（オフライン初回等）でも ensureLocalStyle は
        // オンラインフォールバックを使用する。
        basemapStyleUri = await TileServer.ensureLocalStyle(fontDir: fontDir);
      } else {
        // web: TileServerは立てられず（`dart:io` の HttpServer が無い）、
        // そして不要。MapLibre GL JS がタイルURLを直接叩く。
        // 背景地図の**ソース**だけをスタイルJSONに焼き込む（レイヤは
        // `_addBasemapSources()` が積む）— 理由は
        // [[../../../services/basemap_style_json]] を読むこと。
        basemapStyleUri = buildBasemapStyleJson();
      }

      baseMapService.addListener(onBaseMapServiceUpdate);
      if (mapControllerInstance.style != null) onBaseMapServiceUpdate();
      triggerSetState(() {});
      AppLogger.debug('[Init] BaseMap ready (port=${tileServer.port})');
    } catch (e) {
      AppLogger.debug('[ERROR] BaseMapService: 初期化エラー: $e');
    }
  }

  /// コンパス機能初期化
  Future<void> initializeCompass() async {
    if (!PlatformCapabilities.supportsCompass) {
      AppLogger.debug('[Init] Compass: skipped (desktop)');
      return;
    }

    try {
      final compassStream = FlutterCompass.events;
      if (compassStream == null) return;

      compassSubscription = compassStream.listen((event) {
        if (mounted && event.heading != null) {
          headingNotifier.value = _smoothHeading(event.heading!);
        }
      });

      AppLogger.debug('[Init] Compass ready');
    } catch (e) {
      AppLogger.debug('[ERROR] Compass: 初期化エラー: $e');
    }
  }

  /// 指数移動平均（EMA）によるヘディング平滑化
  ///
  /// 角度は0°/360°の境界で不連続になるため、最短角度差分を用いる。
  /// [alpha] が小さいほど滑らかだが追従が遅い（0.08 = 安定重視）。
  static const double _compassAlpha = 0.08;

  double _smoothHeading(double rawHeading) {
    final prev = lastSmoothedHeading;
    if (prev == null) {
      lastSmoothedHeading = rawHeading;
      return rawHeading;
    }

    // 最短角度差分を計算（-180° ~ +180°）
    double diff = rawHeading - prev;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;

    double smoothed = (prev + _compassAlpha * diff) % 360;
    if (smoothed < 0) smoothed += 360;

    lastSmoothedHeading = smoothed;
    return smoothed;
  }

  /// GPS管理サービス初期化
  Future<void> initializeGpsManager() async {
    if (!PlatformCapabilities.supportsGpsLocation) {
      AppLogger.debug('[Init] GPS: skipped (unsupported)');
      return;
    }

    try {
      // GPS管理サービスを初期化
      if (!gpsManager.isInitialized) {
        await gpsManager.initialize();
      }

      // GPS管理サービスの更新を監視
      gpsManager.addListener(onGpsManagerUpdate);

      // 外部GNSS機器をスキャン（Bluetooth対応プラットフォームのみ）
      if (PlatformCapabilities.supportsBluetoothGnss) {
        scanGnssDevicesBackground();
      }

      // GPS位置情報取得を開始（InternalGpsLocationStore経由）
      await gpsManager.startGps();

      // 初期GPS情報を取得
      updateCurrentGpsInfo();

      // Store.positionStream を購読（マップマーカー・中心移動用）
      positionSubscription = locationStore.positionStream.listen(
        (record) {
          triggerSetState(() {
            currentLocation = LatLng(record.latitude, record.longitude);
            if (!movedToCurrentLocationOnce && currentLocation != null) {
              // 地図の生成より先にGPSの初回フィックスが届くことがある。
              // その場合 jumpTo() は false を返して保留され、
              // onMapCreated（attach）の時点で実行される。
              movedToCurrentLocationOnce = true;
              jumpTo(
                currentLocation!,
                zoom: MapJumpMixin.defaultJumpZoom,
                animate: false,
              ).then((applied) {
                if (!applied) {
                  AppLogger.debug('[GPS] 地図が未生成のため初回ジャンプを保留（attach後に実行）');
                }
              });
            }
          });
        },
        onError: (error) {
          AppLogger.debug('[GPS] stream error: $error');
        },
      );

      AppLogger.debug('[Init] GPS ready');
    } catch (e) {
      AppLogger.debug('[Init] GPS error: $e');
    }
  }

  /// GPS履歴レコーダー初期化
  Future<void> initializeGpsHistoryRecorder() async {
    if (!PlatformCapabilities.supportsGpsTracking) {
      AppLogger.debug('[Init] GpsHistory: skipped (desktop)');
      return;
    }

    try {
      final globalPath = ref.read(globalFolderPathProvider);
      if (globalPath == null) return;

      // AppSupportDir（rawバッファ用、プロジェクトUIに非表示）
      final supportDir = await getApplicationSupportDirectory();

      // GpsHistoryRecorder を初期化（ハイブリッド方式）
      await gpsHistoryRecorder.initialize(globalPath, supportDir.path);

      // positionStream の購読開始（常時記録 + consolidationタイマー）
      gpsHistoryRecorder.startRecording(locationStore.positionStream);

      // 軌跡更新リスナー登録（未Consolidation分をkGpsTrackソースに表示）
      gpsHistoryRecorder.addListener(_onGpsHistoryUpdate);

      // Consolidation完了コールバック
      // gps_tracksレイヤーのフィーチャを強制再読み込みしてから全体更新
      gpsHistoryRecorder.onConsolidated = () async {
        if (!mounted) return;
        await _refreshGpsHistoryLayer();
        await updateFeatures();
      };

      AppLogger.debug('[Init] GpsHistory ready');
    } catch (e) {
      AppLogger.debug('[Init] GpsHistory error: $e');
    }
  }

  /// GPS履歴更新コールバック（未Consolidation分をkGpsTrackソースに更新）
  /// Consolidation済み分はGPKGレイヤツリー経由で表示される
  void _onGpsHistoryUpdate() {
    if (mounted && sourceManager.isInitialized) {
      sourceManager.updateGpsTrack(
        gpsHistoryRecorder.todayPoints.toGeographics(),
      );
    }
  }

  /// gps_tracks レイヤーのフィーチャを強制再読み込み
  /// Consolidation後にGPKGの更新をレイヤツリーに反映させる
  Future<void> _refreshGpsHistoryLayer() async {
    try {
      final folderTree = ref.read(folderTreeProvider);
      if (folderTree == null) return;

      // gps_tracks レイヤーを再帰検索
      final gpsTracksLayer = _findLayerNode(folderTree, 'gps_tracks');
      if (gpsTracksLayer != null) {
        await gpsTracksLayer.updateChildren();
      }
    } catch (e) {
      AppLogger.debug('[Init] GPS history layer refresh error: $e');
    }
  }

  /// レイヤツリーから指定名のLayerNodeを再帰検索
  LayerNode? _findLayerNode(LayerTreeNode node, String layerName) {
    if (node is LayerNode && node.layerName == layerName) return node;
    for (final child in node.children) {
      final found = _findLayerNode(child, layerName);
      if (found != null) return found;
    }
    return null;
  }

  /// 外部GNSS機器をバックグラウンドでスキャン
  Future<void> scanGnssDevicesBackground() async {
    try {
      await gpsManager.scanExternalGnssDevices();
    } catch (e) {
      AppLogger.debug('[GPS] GNSS scan error: $e');
      // エラーでもマップ画面の表示は継続
    }
  }

  // =============================================
  // 破棄処理
  // =============================================

  /// 全サービスの破棄処理
  void disposeAllServices() {
    AutoSyncService.instance.stop();
    tileServer.stop();
    gpsManager.removeListener(onGpsManagerUpdate);
    baseMapService.removeListener(onBaseMapServiceUpdate);
    layerStyleSettings.removeListener(onLayerStyleChanged);
    gpsHistoryRecorder.removeListener(_onGpsHistoryUpdate);
    gpsHistoryRecorder.onConsolidated = null;

    // GPS取得を停止（測量モードでない場合のみ）
    if (gpsManager.isGpsActive && !gpsManager.isSurveyMode) {
      gpsManager.stopGps();
    }

    positionSubscription?.cancel();
    compassSubscription?.cancel();
    headingNotifier.dispose();
    mapBearingNotifier.dispose();
    cameraTickNotifier.dispose();
    longPressCountUpdateTimer?.cancel();
  }

  // =============================================
  // 抽象メソッド（サブクラスで実装）
  // =============================================

  /// フィーチャデータを更新
  Future<void> updateFeatures();
}
