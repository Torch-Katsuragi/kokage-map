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
// lib/tools/pan_tool.dart
// てのひらツール（地図パン専用）
import 'dart:math';

import 'package:flutter/gestures.dart'; // PointerScrollEvent用
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../interfaces/map_state_interface.dart';
import '../providers/tool_providers.dart';
import 'map_tool.dart';

/// 地図パン（移動）専用ツール
class PanTool extends MapTool {
  final Ref _ref;
  PanTool(this._ref);
  @override
  String get name => 'Pan';

  @override
  IconData get icon => Icons.pan_tool_alt;

  // マウスホイールズームの最大倍率設定
  static const double maxZoom = 25.0;

  // ピンチ・回転用状態（フォーカルポイントアンカリング方式）
  LatLng? _focalLatLng;
  Offset? _viewCenter;
  double? _startZoom, _startRotation;
  double? _worldSizeAtStart; // 開始時のMercatorワールドサイズ（画面ピクセル単位）

  // 中ボタンドラッグ用状態
  Offset? _lastFocalPoint;
  bool _isMiddleButtonDragging = false;

  /// 中ボタンドラッグ状態の取得（他のツールから参照可能）
  bool get isMiddleButtonDragging => _isMiddleButtonDragging;

  /// タップイベント - SelectToolのonTapを呼び出す
  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    // パンツールでのシングルタップは選択動作として動作
    _ref.read(selectToolProvider).onTap(details, mapState);
  }

  /// スケール開始イベント
  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {
    if (_isMiddleButtonDragging) return;

    final camera = mapState.mapController.camera;
    _startZoom = camera.zoom;
    _startRotation = camera.rotation;
    _focalLatLng = mapState.offsetToLatLng(details.localFocalPoint);
    _viewCenter = mapState.latLngToOffset(camera.center);
    _worldSizeAtStart = _measureWorldSize(mapState, camera.center, _viewCenter!);
  }

  /// スケール更新イベント（フォーカルポイントアンカリング方式）
  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {
    if (_isMiddleButtonDragging) return;
    if (_focalLatLng == null || _viewCenter == null) return;

    final newZoom = _startZoom! + log(details.scale) / ln2;
    final newRotation = _startRotation! - details.rotation * 180 / pi;

    // ズーム変化に応じてワールドサイズをスケール
    final worldSize = _worldSizeAtStart! * pow(2.0, newZoom - _startZoom!);

    final newCenter = _anchoredCenter(
      _focalLatLng!,
      details.localFocalPoint,
      _viewCenter!,
      worldSize,
      newRotation,
    );

    mapState.mapController.moveAndRotate(newCenter, newZoom, newRotation);
  }

  /// スケール終了イベント
  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) {
    if (_isMiddleButtonDragging) return;

    _focalLatLng = null;
    _viewCenter = null;
    _startZoom = null;
    _startRotation = null;
    _worldSizeAtStart = null;
  }

  /// マウスホイールズーム処理（他のツールからも呼び出し可能）
  void handleMouseWheelZoom(PointerScrollEvent event, IMapState mapState) {
    const double zoomSpeed = 0.01;
    final double zoomDelta = -event.scrollDelta.dy * zoomSpeed;

    final mapController = mapState.mapController;
    final camera = mapController.camera;
    final double newZoom = (camera.zoom + zoomDelta).clamp(1.0, maxZoom);

    if (newZoom != camera.zoom) {
      final cursorLatLng = mapState.offsetToLatLng(event.localPosition);
      final viewCenter = mapState.latLngToOffset(camera.center);
      final currentWorldSize = _measureWorldSize(mapState, camera.center, viewCenter);
      // ズーム変化に応じてスケール
      final worldSize = currentWorldSize * pow(2.0, newZoom - camera.zoom);

      final newCenter = _anchoredCenter(
        cursorLatLng,
        event.localPosition,
        viewCenter,
        worldSize,
        camera.rotation,
      );
      mapController.moveAndRotate(newCenter, newZoom, camera.rotation);
    }
  }

  /// マウスホイールスクロールイベント（ズーム機能）
  @override
  void onPointerSignal(PointerEvent event, IMapState mapState) {
    if (event is PointerScrollEvent) {
      handleMouseWheelZoom(event, mapState);
    }
  }

  /// 中ボタンドラッグ開始（パン処理用の初期化）
  @override
  void onMiddleButtonDown(PointerDownEvent event, IMapState mapState) {
    _isMiddleButtonDragging = true;
    _lastFocalPoint = event.localPosition;
  }

  /// 中ボタンドラッグ移動（パン処理のみ）
  @override
  void onMiddleButtonMove(PointerMoveEvent event, IMapState mapState) {
    if (!_isMiddleButtonDragging || _lastFocalPoint == null) return;

    // 前回位置からの移動量を計算
    final delta = event.localPosition - _lastFocalPoint!;
    _lastFocalPoint = event.localPosition;

    final mapController = mapState.mapController;
    final center = mapController.camera.center;

    // パン処理（Flutter Map v8の正しい座標変換を使用）
    final centerPx = mapState.latLngToOffset(center);
    final newCenterPx = centerPx - delta;
    final newCenter = mapState.offsetToLatLng(newCenterPx);

    // パンのみ適用（ズームと回転は現在の値を維持）
    mapController.moveAndRotate(
      newCenter,
      mapController.camera.zoom,
      mapController.camera.rotation,
    );
  }

  /// 中ボタンドラッグ終了
  @override
  void onMiddleButtonUp(PointerUpEvent event, IMapState mapState) {
    _isMiddleButtonDragging = false;
    _lastFocalPoint = null;
  }

  // --------------------------------------------------
  // フォーカルポイントアンカリング計算
  // --------------------------------------------------

  /// マップの座標変換から現在ズームでの実効ワールドサイズ（画面px単位）を算出
  static double _measureWorldSize(
    IMapState mapState, LatLng center, Offset centerScreen,
  ) {
    const testDeg = 0.01;
    final testLl = LatLng(center.latitude, center.longitude + testDeg);
    final testScreen = mapState.latLngToOffset(testLl);
    // 経度方向のピクセル距離（回転の影響を受けても distance で正確）
    final pxPerDeg = (testScreen - centerScreen).distance / testDeg;
    return pxPerDeg * 360;
  }

  /// anchorLatLng が anchorScreen に留まるようなカメラ中心を算出
  static LatLng _anchoredCenter(
    LatLng anchorLatLng,
    Offset anchorScreen,
    Offset viewCenter,
    double worldSize,
    double bearingDeg,
  ) {
    final anchorMerc = _toMercator(anchorLatLng, worldSize);

    // 画面中心から指位置へのスクリーンオフセット → Mercator座標系に逆回転
    final screenOffset = anchorScreen - viewCenter;
    final bRad = bearingDeg * pi / 180;
    final cosB = cos(bRad);
    final sinB = sin(bRad);
    final mercOffsetX = screenOffset.dx * cosB - screenOffset.dy * sinB;
    final mercOffsetY = screenOffset.dx * sinB + screenOffset.dy * cosB;

    final centerMerc = Offset(
      anchorMerc.dx - mercOffsetX,
      anchorMerc.dy - mercOffsetY,
    );
    return _fromMercator(centerMerc, worldSize);
  }

  /// LatLng → Web Mercator ピクセル座標
  static Offset _toMercator(LatLng ll, double worldSize) {
    final x = (ll.longitude + 180) / 360 * worldSize;
    final latRad = ll.latitude * pi / 180;
    final y =
        (1 - log(tan(latRad) + 1 / cos(latRad)) / pi) / 2 * worldSize;
    return Offset(x, y);
  }

  /// Web Mercator ピクセル座標 → LatLng
  static LatLng _fromMercator(Offset merc, double worldSize) {
    final lng = merc.dx / worldSize * 360 - 180;
    final n = pi - 2 * pi * merc.dy / worldSize;
    final lat = 180 / pi * atan(_sinh(n));
    return LatLng(lat, lng);
  }

  static double _sinh(double x) => (exp(x) - exp(-x)) / 2;
}
