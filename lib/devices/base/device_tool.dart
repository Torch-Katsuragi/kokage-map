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
/// 外部機器連動ツールの抽象基底クラス
///
/// [ExternalDeviceService]と連携し、機器接続時のみツールバーに表示される
/// 地図操作ツール。各機器のツールはこのクラスを継承する。
///
/// map_page / MapToolbar はこの抽象型のみに依存し、
/// 個別機器の知識を持たない（プラグインパターン）。
library;

import 'package:flutter/widgets.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import '../../tools/map_tool.dart';
import 'device_service.dart';

abstract class DeviceTool extends MapTool with ChangeNotifier {
  /// このツールが使用する機器サービス
  ExternalDeviceService get service;

  /// ツールが利用可能か（機器が接続されているか）
  bool get isAvailable => service.isConnected;

  /// 地図上に描画するオーバーレイレイヤ（PolylineLayer等）
  List<ml.Layer> buildOverlayLayers();

  /// 描画系に依らない形のオーバーレイ（3D の地形にも載せる）: 線と基準点。
  /// [buildOverlayLayers] / [buildOverlayMarkers] はこれを MapLibre 向けに包む
  List<geo.Feature<geo.LineString>> overlayLines() => const [];
  LatLng? get overlayStation => null;

  /// 地図上に描画するウィジェットマーカー（BP標識等）
  List<ml.Marker> buildOverlayMarkers();

  /// ステータスパネルウィジェット（機器状態・計測値表示）
  Widget buildStatusPanel(BuildContext context);

  /// 機器固有の詳細/操作画面（null なら遷移しない）
  Widget? buildDetailScreen(BuildContext context) => null;
}
