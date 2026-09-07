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
// Root Maps: オーバーレイ画像変換ツール
// ハンドル型のUI操作で画像オーバーレイの平行移動・拡縮・回転を行う
// スマホ: 1本指でハンドル操作、2本指でカメラ移動（PanTool委譲）
// PC: マウスドラッグでハンドル操作、ホイールでズーム（PanTool委譲）

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../interfaces/map_state_interface.dart';
import '../models/nodes/overlay_image_node.dart';
import '../providers/selection_providers.dart';
import '../providers/tool_providers.dart';
import 'map_tool.dart';

/// ハンドルの種類
enum _HandleType {
  none,
  center,    // 中央: 平行移動
  topLeft,   // 四隅: 拡縮
  topRight,
  bottomRight,
  bottomLeft,
  rotate,    // 回転ハンドル
}

/// オーバーレイ画像変換ツール
class OverlayTransformTool extends MapTool {
  final Ref _ref;

  OverlayTransformTool(this._ref);

  /// 変形更新通知（ハンドルマーカーの局所rebuild用）
  final ValueNotifier<int> transformNotifier = ValueNotifier<int>(0);

  /// 操作対象のオーバーレイノード
  OverlayImageNode? _target;

  /// 現在つかんでいるハンドル
  _HandleType _activeHandle = _HandleType.none;

  /// ドラッグ開始時の画面座標
  Offset? _dragStartScreen;

  /// ドラッグ開始時のパラメータバックアップ
  double _startCenterLng = 0;
  double _startCenterLat = 0;
  double _startScale = 1;
  double _startRotation = 0;

  /// 2本指操作中フラグ（PanTool委譲中）
  bool _isPanDelegating = false;

  /// MapLibre更新デバウンスタイマー
  Timer? _mapUpdateDebounce;

  /// MapLibre更新の最小間隔（100ms）
  /// 毎フレームの重い remove+add を間引き、ハンドルUIだけ即時更新する
  static const _mapUpdateInterval = Duration(milliseconds: 100);

  /// 最新のmapState参照（デバウンスコールバック用）
  IMapState? _lastMapState;

  @override
  String get name => 'Overlay Transform';

  @override
  IconData get icon => Icons.transform;

  @override
  void onActivate() {
    // 選択中のOverlayImageNodeを取得
    final selected = _ref.read(selectedFeaturesProvider);
    _target = selected.whereType<OverlayImageNode>().firstOrNull;
  }

  @override
  void onDeactivate() {
    _mapUpdateDebounce?.cancel();
    _mapUpdateDebounce = null;
    _target = null;
    _activeHandle = _HandleType.none;
  }

  /// 操作対象を設定（外部から呼び出し可能）
  void setTarget(OverlayImageNode? node) {
    _target = node;
  }

  /// 操作対象を取得
  OverlayImageNode? get target => _target;

  /// ドラッグ中かどうか
  bool get isDragging => _activeHandle != _HandleType.none;

  /// 回転ハンドルの地理座標（上辺中点から外側へオフセット）
  LatLng? get rotationHandlePosition {
    if (_target == null) return null;
    final corners = _target!.cornerCoordinates;
    final topMid = LatLng(
      (corners[0].latitude + corners[1].latitude) / 2,
      (corners[0].longitude + corners[1].longitude) / 2,
    );
    final center = LatLng(
      _target!.overlayParams.centerLat,
      _target!.overlayParams.centerLng,
    );
    final dLat = topMid.latitude - center.latitude;
    final dLng = topMid.longitude - center.longitude;
    return LatLng(
      topMid.latitude + dLat * 0.6,
      topMid.longitude + dLng * 0.6,
    );
  }

  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    // タップでハンドルを選択するだけ（何もしない）
  }

  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {
    if (details.pointerCount >= 2) {
      // 2本指: PanToolに委譲
      _isPanDelegating = true;
      _ref.read(panToolProvider).onScaleStart(details, mapState);
      return;
    }

    _isPanDelegating = false;
    if (_target == null) return;

    // 1本指: ハンドルのヒットテスト
    _activeHandle = _hitTestHandle(details.localFocalPoint, mapState);
    _dragStartScreen = details.localFocalPoint;

    // パラメータをバックアップ
    _startCenterLng = _target!.overlayParams.centerLng;
    _startCenterLat = _target!.overlayParams.centerLat;
    _startScale = _target!.overlayParams.scale;
    _startRotation = _target!.overlayParams.rotation;
  }

  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {
    if (_isPanDelegating) {
      _ref.read(panToolProvider).onScaleUpdate(details, mapState);
      return;
    }

    if (_target == null || _dragStartScreen == null) return;
    if (_activeHandle == _HandleType.none) return;

    final currentScreen = details.localFocalPoint;

    switch (_activeHandle) {
      case _HandleType.center:
        _applyMove(currentScreen, mapState);
      case _HandleType.topLeft:
      case _HandleType.topRight:
      case _HandleType.bottomRight:
      case _HandleType.bottomLeft:
        _applyScale(currentScreen, mapState);
      case _HandleType.rotate:
        _applyRotation(currentScreen, mapState);
      case _HandleType.none:
        break;
    }
  }

  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) {
    if (_isPanDelegating) {
      _ref.read(panToolProvider).onScaleEnd(details, mapState);
      _isPanDelegating = false;
      return;
    }

    if (_target != null && _activeHandle != _HandleType.none) {
      // デバウンスタイマーをキャンセルし、最終位置を即時反映
      _mapUpdateDebounce?.cancel();
      _mapUpdateDebounce = null;
      mapState.updateOverlayTransform(_target!);

      // KMetaに永続化
      _target!.saveOverlayParams();
    }

    _activeHandle = _HandleType.none;
    _dragStartScreen = null;
  }

  // PC: ホイール → PanToolに委譲
  @override
  void onPointerSignal(PointerEvent event, IMapState mapState) {
    _ref.read(panToolProvider).onPointerSignal(event, mapState);
  }

  // PC: 中ボタンドラッグ → PanToolに委譲
  @override
  void onMiddleButtonDown(PointerDownEvent event, IMapState mapState) =>
      _ref.read(panToolProvider).onMiddleButtonDown(event, mapState);
  @override
  void onMiddleButtonMove(PointerMoveEvent event, IMapState mapState) =>
      _ref.read(panToolProvider).onMiddleButtonMove(event, mapState);
  @override
  void onMiddleButtonUp(PointerUpEvent event, IMapState mapState) =>
      _ref.read(panToolProvider).onMiddleButtonUp(event, mapState);

  // --------------------------------------------------
  // ハンドルヒットテスト
  // --------------------------------------------------

  /// ハンドルのヒットテスト
  /// 画面上のタップ位置から、どのハンドルがヒットしたかを判定
  _HandleType _hitTestHandle(Offset screenPoint, IMapState mapState) {
    if (_target == null) return _HandleType.none;

    final corners = _target!.cornerCoordinates;
    const hitRadius = 36.0;

    // 各頂点の画面座標
    final screenCorners = corners.map((c) => mapState.latLngToOffset(c)).toList();

    // 回転ハンドル（rotationHandlePositionの画面座標を使う）
    final rotateGeo = rotationHandlePosition;
    if (rotateGeo != null) {
      final rotateScreenPos = mapState.latLngToOffset(rotateGeo);
      if ((screenPoint - rotateScreenPos).distance < hitRadius) {
        return _HandleType.rotate;
      }
    }

    // 四隅のハンドル
    final handleTypes = [
      _HandleType.topLeft,
      _HandleType.topRight,
      _HandleType.bottomRight,
      _HandleType.bottomLeft,
    ];
    for (var i = 0; i < screenCorners.length; i++) {
      if ((screenPoint - screenCorners[i]).distance < hitRadius) {
        return handleTypes[i];
      }
    }

    // 中央領域（回転矩形の内部判定）
    if (_isInsideQuad(screenPoint, screenCorners)) {
      return _HandleType.center;
    }

    return _HandleType.none;
  }

  /// 凸四角形の内部判定（クロス積方式）
  /// 頂点が時計回りに並んでいる前提で、全辺の外積が同符号ならば内部
  bool _isInsideQuad(Offset p, List<Offset> corners) {
    for (int i = 0; i < corners.length; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % corners.length];
      final cross =
          (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
      if (cross < 0) return false;
    }
    return true;
  }

  // --------------------------------------------------
  // 変換適用
  // --------------------------------------------------

  /// 平行移動を適用
  void _applyMove(Offset currentScreen, IMapState mapState) {
    final start = mapState.offsetToLatLng(_dragStartScreen!);
    final current = mapState.offsetToLatLng(currentScreen);

    final dLat = current.latitude - start.latitude;
    final dLng = current.longitude - start.longitude;

    _target!.overlayParams = _target!.overlayParams.copyWith(
      centerLat: _startCenterLat + dLat,
      centerLng: _startCenterLng + dLng,
    );

    _notifyOverlayChanged(mapState);
  }

  /// 拡縮を適用
  void _applyScale(Offset currentScreen, IMapState mapState) {
    final centerScreen = mapState.latLngToOffset(
      LatLng(_startCenterLat, _startCenterLng),
    );
    final startDist = (_dragStartScreen! - centerScreen).distance;
    final currentDist = (currentScreen - centerScreen).distance;

    if (startDist < 10) return; // ゼロ除算回避

    final scaleFactor = currentDist / startDist;
    _target!.overlayParams = _target!.overlayParams.copyWith(
      scale: (_startScale * scaleFactor).clamp(0.01, 1000.0),
    );

    _notifyOverlayChanged(mapState);
  }

  /// 回転を適用
  void _applyRotation(Offset currentScreen, IMapState mapState) {
    final centerScreen = mapState.latLngToOffset(
      LatLng(_startCenterLat, _startCenterLng),
    );

    final startAngle = math.atan2(
      _dragStartScreen!.dy - centerScreen.dy,
      _dragStartScreen!.dx - centerScreen.dx,
    );
    final currentAngle = math.atan2(
      currentScreen.dy - centerScreen.dy,
      currentScreen.dx - centerScreen.dx,
    );

    final deltaAngle = (currentAngle - startAngle) * 180 / math.pi;
    _target!.overlayParams = _target!.overlayParams.copyWith(
      rotation: _startRotation - deltaAngle,
    );

    _notifyOverlayChanged(mapState);
  }

  /// オーバーレイ変更を通知
  ///
  /// ハンドルUIは即時更新（transformNotifier）し、
  /// MapLibreへの反映は100msデバウンスで間引く。
  /// これにより毎フレームの重いremove+addを回避する。
  void _notifyOverlayChanged(IMapState mapState) {
    if (_target == null) return;

    // ハンドル位置は即座に更新（Flutter側の軽量描画）
    transformNotifier.value++;

    // MapLibre更新は100ms間隔にデバウンス
    _lastMapState = mapState;
    _mapUpdateDebounce?.cancel();
    _mapUpdateDebounce = Timer(_mapUpdateInterval, () {
      if (_target != null && _lastMapState != null) {
        _lastMapState!.updateOverlayTransform(_target!);
      }
    });
  }
}
