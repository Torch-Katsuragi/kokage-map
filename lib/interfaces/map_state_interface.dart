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
/// Root Maps: 地図状態の抽象インターフェース
/// MapToolやその他のクラスで型安全にMapPageStateにアクセスするためのインターフェース
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../core/r_map_controller.dart';
import '../models/nodes/current_location_node.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/image_node.dart';
import '../models/nodes/overlay_image_node.dart';

/// 地図状態の抽象インターフェース
/// 
/// [MapTool]やウィジェットからMapPageのStateに型安全にアクセスするために使用。
/// これにより、dynamic型を排除し、IDE補完とコンパイル時型チェックを有効化。
abstract class IMapState {
  /// 画面座標を地図座標（緯度経度）に変換
  LatLng offsetToLatLng(Offset offset);

  /// 地図座標（緯度経度）を画面座標に変換
  Offset latLngToOffset(LatLng latlng);

  /// 現在位置マーカーの擬似フィーチャ（タップ選択の候補に混ざる）
  CurrentLocationNode get currentLocationNode;

  /// UIの再描画をトリガー
  void setState(VoidCallback fn);

  /// フィーチャキャッシュを更新し、地図を再描画
  void refreshFeatures();

  /// マップの強制更新処理（レイヤ削除時などに使用）
  void forceMapRefresh();

  /// このStateに関連付けられたBuildContext
  BuildContext get context;

  /// ポリゴンのリングを閉じる（始点と終点を一致させる）
  List<LatLng> closeRing(List<LatLng> points);

  /// 地図コントローラー（旧 flutter_map 互換ラッパー）
  RMapController get mapController;

  /// StateがWidgetツリーにマウントされているか
  bool get mounted;

  /// キャッシュ済みポイントフィーチャ（全可視レイヤー）
  List<PointFeatureNode> get pointFeatures;

  /// キャッシュ済みラインフィーチャ（全可視レイヤー）
  List<LineFeatureNode> get lineFeatures;

  /// キャッシュ済みポリゴンフィーチャ（全可視レイヤー）
  List<PolygonFeatureNode> get polygonFeatures;

  /// キャッシュ済み写真ノード（全可視ImageNode）
  List<ImageNode> get photoNodes;

  /// キャッシュ済みオーバーレイ画像ノード
  List<OverlayImageNode> get overlayImageNodes;

  /// MapLibreに登録済みのオーバーレイソースID
  Set<String> get activeOverlaySourceIds;
  set activeOverlaySourceIds(Set<String> value);

  /// レイヤキャッシュを無効化
  void invalidateLayerCache();

  /// オーバーレイ画像の変形をリアルタイム更新（ドラッグ中の軽量パス）
  void updateOverlayTransform(OverlayImageNode node);
}
