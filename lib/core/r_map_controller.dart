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
/// かつての `flutter_map` 互換のMapControllerラッパー
///
/// ⚠ `flutter_map` への依存は 2026-08-26 に外した。このAPIの形が
/// maplibre 寄りでないのは移行時の名残であって、現役の互換要件ではない。
///
/// maplibreのMapControllerを内包し、既存コードが使う
/// 旧 `flutter_map` 風のAPIを提供する。座標はLatLng(latlong2)を維持。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import '../utils/app_logger.dart';
import '../utils/geo_converter.dart';

/// 旧 `flutter_map` 互換のカメラ情報
class KMapCamera {
  final ml.MapController? _controller;
  final LatLng? _fixedCenter;
  final double _fixedZoom;
  final double _fixedBearing;

  KMapCamera(ml.MapController controller)
      : _controller = controller,
        _fixedCenter = null,
        _fixedZoom = 0,
        _fixedBearing = 0;

  /// 地図が組み立てられていない間（3D 中）の、最後に覚えたカメラ
  const KMapCamera.fixed({required LatLng center, required double zoom, required double bearing})
      : _controller = null,
        _fixedCenter = center,
        _fixedZoom = zoom,
        _fixedBearing = bearing;

  double get zoom => _controller?.getCamera().zoom ?? _fixedZoom;
  LatLng get center => _controller?.getCamera().center.toLatLng() ?? _fixedCenter!;

  /// bearing (maplibre) = rotation (旧 flutter_map) として扱う
  double get rotation => bearing;
  double get bearing => _controller?.getCamera().bearing ?? _fixedBearing;
  double get pitch => _controller?.getCamera().pitch ?? 0;

  /// 画面座標 → 地図座標（地図が無い間は使えない。呼ぶ側は 3D の投影を先に見る）
  LatLng offsetToCrs(Offset offset) {
    final c = _controller;
    if (c == null) throw StateError('map is not attached');
    return c.toLngLat(offset).toLatLng();
  }

  /// 地図座標 → 画面座標
  Offset latLngToScreenOffset(LatLng latlng) {
    final c = _controller;
    if (c == null) throw StateError('map is not attached');
    return c.toScreenLocation(latlng.toGeographic());
  }
}

/// maplibreのMapControllerをラップし、旧 flutter_map 互換APIを提供
class RMapController {
  ml.MapController? _controller;
  ml.StyleController? _styleController;

  /// カメラアニメーション排他制御用
  Timer? _fitDebounceTimer;
  bool _isCameraAnimating = false;

  /// attach 前に呼ばれたカメラ操作の保留分（最後の1件だけ持つ）。
  ///
  /// 地図の生成（プラットフォームビューの立ち上げ・WebView2の起動）は重く、
  /// GPSの初回フィックスのほうが先に届くことがある。その場合に操作を
  /// 黙って捨てると「起動時に現在地へ飛ばない」という形で表面化する
  /// （Android・Windows のどちらでも起きる）。
  /// ここに退避しておき、attach された時点で実行する。
  ///
  /// 複数たまった場合は最後の1件だけを実行する（カメラ操作は上書きが正しい）。
  void Function()? _pendingCameraAction;

  /// maplibreのMapControllerをセット
  ///
  /// ⚠ ここではまだ保留分を流さない。`onMapCreated` の意味がバックエンドで違うため。
  /// - MapLibre Native（Android/iOS）: この時点で地図は操作できる
  /// - maplibre_webview（Windows/macOS）: **WebViewができただけ**で、
  ///   中のMapLibre JSオブジェクトはまだ存在しない。ここで moveCamera すると
  ///   `Null check operator used on a null value` で落ちる
  ///
  /// 両方で確実に操作できるのは onStyleLoaded 以降なので、
  /// 保留分は [attachStyle] で流す。
  void attach(ml.MapController controller) {
    _controller = controller;
  }

  /// 地図（MapLibre）が外れた（3D 中は組み立てない）。最後のカメラは覚えておき、
  /// 以後のカメラ操作は保留にして次に組み立てたときに流す
  void detach() {
    final c = _controller;
    if (c != null) {
      try {
        final cam = c.getCamera();
        rememberCamera(cam.center.toLatLng(), cam.zoom, cam.bearing);
      } on Object catch (_) {}
    }
    _controller = null;
    _styleController = null;
    _fitDebounceTimer?.cancel();
    _isCameraAnimating = false;
  }

  LatLng? _lastCenter;
  double _lastZoom = 16;
  double _lastBearing = 0;

  /// 最後に覚えたカメラ（地図を組み立て直すときの初期値、外れている間の [camera]）
  LatLng? get lastCenter => _lastCenter;
  double get lastZoom => _lastZoom;
  double get lastBearing => _lastBearing;

  void rememberCamera(LatLng center, double zoom, double bearing) {
    _lastCenter = center;
    _lastZoom = zoom;
    _lastBearing = bearing;
  }

  /// 地図が使える状態か（コントローラとスタイルの両方が揃っているか）
  bool get isAttached => _controller != null && _styleController != null;

  /// StyleControllerをセット
  ///
  /// 地図が実際に操作可能になる時点。ここで保留分のカメラ操作を流す。
  void attachStyle(ml.StyleController style) {
    _styleController = style;

    final pending = _pendingCameraAction;
    _pendingCameraAction = null;
    if (pending == null) return;
    try {
      pending();
    } on Object catch (e) {
      // 保留分で落ちても地図の初期化自体は続行させる
      AppLogger.debug('[RMapController] 保留カメラ操作の実行に失敗: $e');
    }
  }

  /// 生のmaplibreコントローラ（maplibre固有API用）
  ml.MapController? get raw => _controller;

  /// StyleController（ソース・レイヤ管理用）
  ml.StyleController? get style => _styleController;

  /// カメラ情報
  KMapCamera get camera {
    final c = _controller;
    if (c == null) {
      return KMapCamera.fixed(
        center: _lastCenter ?? const LatLng(35.681236, 139.767125),
        zoom: _lastZoom,
        bearing: _lastBearing,
      );
    }
    return KMapCamera(c);
  }

  /// カメラ移動（同期的にfire-and-forget）
  ///
  /// Returns: 即座に反映されたら true。attach 前だった場合は false を返し、
  /// attach 後に実行されるよう保留する（呼び出しは失われない）。
  bool move(LatLng center, double zoom) {
    rememberCamera(center, zoom, _lastBearing);
    final controller = _controller;
    if (controller == null) {
      _pendingCameraAction = () => move(center, zoom);
      return false;
    }
    controller.moveCamera(center: center.toGeographic(), zoom: zoom);
    return true;
  }

  /// カメラ移動 + 回転
  ///
  /// Returns: [move] と同じ。attach 前なら false を返して保留する。
  bool moveAndRotate(LatLng center, double zoom, double rotation) {
    rememberCamera(center, zoom, rotation);
    final controller = _controller;
    if (controller == null) {
      _pendingCameraAction = () => moveAndRotate(center, zoom, rotation);
      return false;
    }
    controller.moveCamera(
      center: center.toGeographic(),
      zoom: zoom,
      bearing: rotation,
    );
    return true;
  }

  /// アニメーション付きカメラ移動
  ///
  /// 進行中のアニメーションがあれば即キャンセルしてから開始する。
  Future<void> animateTo({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
  }) async {
    if (_controller == null) {
      // attach 前。保留してから attach 時に実行する。
      _pendingCameraAction =
          () => animateTo(
            center: center,
            zoom: zoom,
            bearing: bearing,
            pitch: pitch,
          );
      return;
    }

    _fitDebounceTimer?.cancel();
    _cancelOngoingAnimation();

    _isCameraAnimating = true;
    try {
      await _controller?.animateCamera(
        center: center?.toGeographic(),
        zoom: zoom,
        bearing: bearing,
        pitch: pitch,
      );
      // バックエンドによっては animateCamera の Future がアニメーション完了を
      // 待たずに即座に返る（maplibre_webview は 15ms で返り、カメラはその後
      // 1秒ほどかけて動く。maplibre_android は着地まで待つ）。
      // 呼び出し側が「戻ってきたら着地済み」を前提にできるよう、ここで揃える。
      await _awaitCameraSettled(center: center, zoom: zoom, bearing: bearing);
    } on Exception catch (_) {
      // moveCamera によるキャンセル時に "Map camera movement cancelled." が
      // スローされる。こちらから止めたのだから無視してよい。
      //
      // > [!IMPORTANT] web は「止めていないのに」ここへ来る
      // > maplibre_web は flyTo の完了を `moveend` **1発**で判定し、その時点の
      // > カメラが目標と許容差 1e-7 で一致しなければ CancellationException を
      // > 投げる。飛行中に別の理由（コンテナのリサイズ等）で moveend が来ると
      // > これに落ちる。カメラはまだ飛んでいるので、ここで抜けると
      // > 「Future が返った＝着地済み」という契約が破れる。
      // >
      // > こちらから止めた場合は `_cancelOngoingAnimation()` が
      // > `_isCameraAnimating` を倒しているので、それで区別できる。
      if (_isCameraAnimating) {
        await _awaitCameraSettled(center: center, zoom: zoom, bearing: bearing);
      }
    } finally {
      _isCameraAnimating = false;
    }
  }

  /// カメラが目標値に到達するまで待つ（上限付き）。
  ///
  /// [_cancelOngoingAnimation] で `_isCameraAnimating` が倒されたら即座に抜ける。
  Future<void> _awaitCameraSettled({
    LatLng? center,
    double? zoom,
    double? bearing,
    Duration timeout = const Duration(seconds: 3),
    Duration step = const Duration(milliseconds: 32),
  }) async {
    if (_controller == null) return;
    if (center == null && zoom == null && bearing == null) return;

    final deadline = DateTime.now().add(timeout);
    while (_isCameraAnimating && DateTime.now().isBefore(deadline)) {
      if (_isCameraAtTarget(center: center, zoom: zoom, bearing: bearing)) {
        return;
      }
      await Future<void>.delayed(step);
    }
  }

  /// 現在のカメラが目標値とみなせる範囲に入っているか
  bool _isCameraAtTarget({LatLng? center, double? zoom, double? bearing}) {
    final controller = _controller;
    if (controller == null) return true;
    final cam = controller.getCamera();

    if (zoom != null && (cam.zoom - zoom).abs() > 0.05) return false;
    if (bearing != null && (cam.bearing - bearing).abs() > 0.5) return false;
    if (center != null) {
      final c = cam.center.toLatLng();
      if ((c.latitude - center.latitude).abs() > 1e-3) return false;
      if ((c.longitude - center.longitude).abs() > 1e-3) return false;
    }
    return true;
  }

  /// 座標リストに合わせてカメラをフィット
  ///
  /// 短時間の連続呼び出しはデバウンスし、最後の呼び出しのみ実行する。
  /// 進行中のアニメーションがあれば即キャンセルしてから開始する。
  /// 3D 中の差し替え先（地形のカメラを動かす）。地図の外からの「ここへ寄せる」はこれを先に見る
  void Function(List<LatLng> coordinates, EdgeInsets padding)? fitOverride;

  void fitCoordinates(
    List<LatLng> coordinates, {
    EdgeInsets padding = EdgeInsets.zero,
  }) {
    if (coordinates.isEmpty) return;
    final override = fitOverride;
    if (override != null) {
      override(coordinates, padding);
      return;
    }
    if (_controller == null) {
      // attach 前。保留してから attach 時に実行する。
      _pendingCameraAction =
          () => fitCoordinates(coordinates, padding: padding);
      return;
    }

    // デバウンス: 短時間の連続ダブルタップをまとめて最後の1つだけ実行
    _fitDebounceTimer?.cancel();
    _fitDebounceTimer = Timer(const Duration(milliseconds: 150), () {
      _executeFitBounds(coordinates, padding);
    });
  }

  /// 実際の fitBounds 実行（排他制御付き）
  Future<void> _executeFitBounds(
    List<LatLng> coordinates,
    EdgeInsets padding,
  ) async {
    if (_controller == null) return;

    // 進行中のアニメーションをキャンセル
    _cancelOngoingAnimation();

    // 座標からバウンディングボックスを計算
    double minLat = double.infinity, maxLat = -double.infinity;
    double minLon = double.infinity, maxLon = -double.infinity;
    for (final c in coordinates) {
      if (c.latitude < minLat) minLat = c.latitude;
      if (c.latitude > maxLat) maxLat = c.latitude;
      if (c.longitude < minLon) minLon = c.longitude;
      if (c.longitude > maxLon) maxLon = c.longitude;
    }

    _isCameraAnimating = true;
    try {
      await _controller!.fitBounds(
        bounds: ml.LngLatBounds(
          longitudeWest: minLon,
          longitudeEast: maxLon,
          latitudeSouth: minLat,
          latitudeNorth: maxLat,
        ),
        padding: padding,
      );
    } on Exception catch (_) {
      // moveCamera によるキャンセル時に "Map camera movement cancelled." が
      // スローされるが、意図的なキャンセルなので無視する
    } finally {
      _isCameraAnimating = false;
    }
  }

  /// 進行中のカメラアニメーションを即座にキャンセル
  ///
  /// moveCamera（瞬時移動）で現在位置にスナップすることで
  /// ネイティブ側のアニメーションを中断する。
  void _cancelOngoingAnimation() {
    if (!_isCameraAnimating || _controller == null) return;
    final cam = _controller!.getCamera();
    _controller!.moveCamera(
      center: cam.center,
      zoom: cam.zoom,
      bearing: cam.bearing,
      pitch: cam.pitch,
    );
    _isCameraAnimating = false;
  }

  /// 画面座標 → 地図座標
  LatLng toLngLat(Offset offset) {
    assert(_controller != null, 'MapController is not attached');
    return _controller!.toLngLat(offset).toLatLng();
  }

  /// 地図座標 → 画面座標
  Offset toScreenLocation(LatLng latlng) {
    assert(_controller != null, 'MapController is not attached');
    return _controller!.toScreenLocation(latlng.toGeographic());
  }

  void dispose() {
    _fitDebounceTimer?.cancel();
    _pendingCameraAction = null;
    _controller = null;
    _styleController = null;
  }
}
