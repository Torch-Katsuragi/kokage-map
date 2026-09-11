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
// Root Maps: MapPage状態の基底mixin
// 全てのMixinが共通でアクセスする状態変数を定義
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/r_map_controller.dart';
import '../../interfaces/map_state_interface.dart';
import '../../interfaces/terrain_projection.dart';
import '../../models/gps_position_record.dart';
import '../../models/map_style_group.dart';
import '../../models/nodes/current_location_node.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/image_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../services/basemap_service.dart';
import '../../services/gps_history_recorder.dart';
import '../../services/gps_manager_service.dart';
import '../../services/internal_gps_location_store.dart';
import '../../services/tile_server.dart';
import 'feature_geojson_cache.dart';

/// MapPageの状態変数を定義する基底mixin
/// 各機能別Mixinはこのmixinを継承（on）して状態にアクセス
mixin MapPageStateBase<T extends ConsumerStatefulWidget>
    on ConsumerState<T>, TickerProviderStateMixin<T>
    implements IMapState {

  // =============================================
  // 地図基本状態
  // =============================================

  /// 地図の初期中心座標（東京駅）
  final LatLng defaultCenter = const LatLng(35.681236, 139.767125);

  /// ローカルスタイルの file:// URI（TileServer起動後にセット）
  String? basemapStyleUri;

  /// 現在位置
  LatLng? currentLocation;

  /// 現在位置マーカーの擬似フィーチャ。値は地図側のフィールドをその都度読む
  @override
  late final CurrentLocationNode currentLocationNode = CurrentLocationNode(
    locationOf: () => currentLocation,
    gpsInfoOf: () => currentGpsInfo,
    headingNotifier: headingNotifier,
  );

  /// 位置情報ストリームサブスクリプション（Store.positionStream購読用）
  StreamSubscription<GpsPositionRecord>? positionSubscription;

  /// 初回の現在位置移動フラグ
  bool movedToCurrentLocationOnce = false;

  /// 地図コントローラー（旧 flutter_map 互換ラッパー）
  final RMapController mapControllerInstance = RMapController();

  @override
  RMapController get mapController => mapControllerInstance;

  // =============================================
  // コンパス関連
  // =============================================

  /// 現在のデバイス方角（ValueNotifier化で局所再描画）
  final ValueNotifier<double?> headingNotifier = ValueNotifier<double?>(null);

  /// 地図の回転角（bearing）— MapEventMoveCamera で毎フレーム更新
  final ValueNotifier<double> mapBearingNotifier = ValueNotifier<double>(0.0);

  /// カメラが動いた回数。MapEventMoveCamera / Idle ごとに増える。
  /// 画面座標に依存するオーバーレイ（画面外の現在位置インジケータ等）が
  /// ページ全体を再ビルドせずに追従するための通知用。
  final ValueNotifier<int> cameraTickNotifier = ValueNotifier<int>(0);

  /// コンパスヘディングの前回スムーズ値（ローパスフィルタ用）
  double? lastSmoothedHeading;

  /// コンパスイベントサブスクリプション
  StreamSubscription<CompassEvent>? compassSubscription;

  // =============================================
  // レイヤーツリー関連
  // =============================================

  /// 現在選択中のノード
  LayerTreeNode? currentNode;

  // =============================================
  // ドロワー関連
  // =============================================

  /// ドロワー幅
  double drawerWidth = 320;

  /// ドロワー開閉状態
  bool drawerOpen = true;

  /// ドロワー最小幅
  final double minDrawerWidth = 200;

  // =============================================
  // GPS管理サービス
  // =============================================

  /// 統合GPS管理サービス
  final GpsManagerService gpsManager = GpsManagerService();

  /// 背景地図サービス
  final BaseMapService baseMapService = BaseMapService();

  /// ローカルタイルサーバー
  late final TileServer tileServer = TileServer(baseMapService);


  /// 内蔵GPS位置情報ストア
  final InternalGpsLocationStore locationStore = InternalGpsLocationStore();

  /// GPS履歴レコーダー
  final GpsHistoryRecorder gpsHistoryRecorder = GpsHistoryRecorder();

  /// 現在のGPS情報
  Map<String, dynamic>? currentGpsInfo;

  // =============================================
  // GPS測量関連
  // =============================================

  /// 長押し中フラグ
  bool isLongPressing = false;

  /// 長押しGPSカウント
  int longPressGpsCount = 0;

  /// 長押しカウント更新タイマー
  Timer? longPressCountUpdateTimer;

  // =============================================
  // 属性テーブル関連
  // =============================================

  /// 属性テーブル表示フラグ
  bool showAttributeTable = false;

  /// 属性テーブル高さ
  double attributeTableHeight = 350;

  /// 属性テーブル対象レイヤー
  LayerNode? attributeTableLayer;

  // =============================================
  // フィーチャキャッシュ
  // =============================================

  @override
  List<PointFeatureNode> pointFeatures = [];

  @override
  List<LineFeatureNode> lineFeatures = [];

  @override
  List<PolygonFeatureNode> polygonFeatures = [];

  @override
  List<ImageNode> photoNodes = [];

  @override
  List<OverlayImageNode> overlayImageNodes = [];

  // =============================================
  // レンダリングキャッシュ（パン/ズーム時の再構築を防止）
  // =============================================

  /// 地図に流す GeoJSON（通常 / 選択済み）。組み立ては [FeatureGeoJsonCache]
  final geoJson = FeatureGeoJsonCache();

  /// View 固有スタイルの束（フィーチャの `k-style` と突き合わせる）。3D 地図面が見た目を決めるのに使う
  List<MapStyleGroup> styleGroups = const [];

  /// [styleGroups] を差し替える。変わったら true
  bool setStyleGroups(List<MapStyleGroup> groups) {
    if (styleGroupsEqual(styleGroups, groups)) return false;
    styleGroups = List.unmodifiable(groups);
    return true;
  }

  /// キャッシュ再構築フラグ
  bool layerCacheDirty = true;

  /// 3D 地形モード中の投影。null なら MapLibre（`TerrainMapLayer` が登録 / 解除する）
  TerrainProjection? terrainProjection;

  /// 地図に流す GeoJSON が更新されたら増える（3D 地図面がシーンを組み直す合図）
  final ValueNotifier<int> terrainSceneRevision = ValueNotifier<int>(0);

  /// 前回キャッシュ構築時の選択状態（identity比較用）
  List<LayerTreeNode>? lastCacheSelection;

  /// レンダリングキャッシュを無効化（次回build時に再構築）
  @override
  void invalidateLayerCache() {
    layerCacheDirty = true;
  }

  // =============================================
  // IMapState実装
  // =============================================

  @override
  LatLng offsetToLatLng(Offset offset) {
    final terrain = terrainProjection;
    if (terrain != null) {
      final p = terrain.unproject(offset);
      if (p != null) return p;
    }
    try {
      return mapControllerInstance.toLngLat(offset);
    } catch (e) {
      return mapControllerInstance.camera.center;
    }
  }

  @override
  Offset latLngToOffset(LatLng latlng) {
    final terrain = terrainProjection;
    if (terrain != null) return terrain.project(latlng);
    try {
      return mapControllerInstance.toScreenLocation(latlng);
    } catch (e) {
      final size = MediaQuery.of(context).size;
      return Offset(size.width / 2, size.height / 2);
    }
  }

  @override
  List<LatLng> closeRing(List<LatLng> pts) {
    if (pts.length < 3) return [];
    final first = pts.first;
    final last = pts.last;
    final bool isClosed =
        (first.latitude == last.latitude) &&
        (first.longitude == last.longitude);
    if (!isClosed) {
      return List<LatLng>.from(pts)..add(first);
    }
    return pts;
  }

  // =============================================
  // 抽象メソッド（各Mixinで実装）
  // =============================================

  /// GPS情報更新コールバック
  void onGpsManagerUpdate();

  /// レイヤスタイル変更コールバック
  void onLayerStyleChanged();

  /// 現在のGPS情報を更新
  void updateCurrentGpsInfo();

  // =============================================
  // ヘルパーメソッド
  // =============================================

  /// setStateのラッパー（Mixinから呼び出し用）
  void triggerSetState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    }
  }
}
