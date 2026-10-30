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
/// TruPulse測量ツール
///
/// [DeviceTool]実装。TruPulse接続時にツールバーに表示される。
/// ポイントフィーチャをStation（器械点）として選択し、
/// レーザー計測結果から対象点の座標を算出、同レイヤにポイントを逐次生成する。
/// タップ時に放射状メニューでStation設定・削除操作を提供。
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../i18n/strings.g.dart';
import '../../interfaces/map_state_interface.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../providers/notification_providers.dart';
import '../../providers/selection_providers.dart';
import '../../providers/tool_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/survey/survey_chain_resolver.dart';
import '../../services/survey/traverse_recorder.dart';
import '../../tools/pan_tool.dart';
import '../../utils/app_logger.dart';
import '../../utils/geo_converter.dart';
import '../../utils/true_heading.dart';
import '../../utils/wmm_declination.dart';
import '../../widgets/external_layer_actions.dart';
import '../../widgets/radial_action_menu.dart';
import '../base/device_tool.dart';
import 'trupulse_detail_screen.dart';
import 'trupulse_measurement.dart';
import 'trupulse_providers.dart';
import 'trupulse_service.dart';
import 'trupulse_status_panel.dart';

class TruPulseTool extends DeviceTool {
  /// TruPulse の方位角（磁北基準）を、[at] の偏角（WMM2025）で真北基準に直す
  ///
  /// 本体の偏角設定（dECLn）は 0 のまま使う前提（シリアルでは読めないので、本体側でも足すと二重になる）。
  /// 属性 `survey_az` には本体の値（磁北基準）をそのまま残す。ライン化の偏角補正（既定 ON）はこの値に足す。
  /// 後視の生の値 `survey_fs_az`・`survey_bs_az` も同じく磁北基準。
  /// docs/devices/trupulse-360r.md「偏差（Declination）設定」
  static double trueAzimuth(double magneticAz, LatLng at, [DateTime? date]) =>
      magneticToTrue(magneticAz, WmmDeclination.calculate(at.latitude, at.longitude, date));

  final Ref _ref;
  final TruPulseService _service;
  StreamSubscription<TruPulseMeasurement>? _measurementSub;
  final AudioPlayer _player = AudioPlayer();
  VoidCallback? _dismissMenu;
  ProviderSubscription<LayerNode?>? _selectedLayerSub;

  TruPulseTool(this._ref, this._service);

  @override
  String get name => 'Compass';
  @override
  IconData get icon => Icons.explore;
  @override
  TruPulseService get service => _service;

  PanTool get _panTool => _ref.read(panToolProvider);

  /// 計測・基準点の変化を知らせる。聞くのはツールを直接購読している地形とステータスパネルだけ
  /// （以前はプロバイダも進めて、計測のたびに地図ページ全体を組み直していた）
  void _notifyUI() => notifyListeners();

  PointFeatureNode? _station;
  LatLng? get stationPosition => _station?.point;
  PointFeatureNode? get station => _station;

  @visibleForTesting
  set debugStation(PointFeatureNode? stn) => _station = stn;

  String? _lastPlayedAsset;

  @visibleForTesting
  String? get debugLastPlayedAsset => _lastPlayedAsset;

  @visibleForTesting
  void debugClearLastPlayedAsset() => _lastPlayedAsset = null;

  IMapState? _mapState;

  static const double _hitRadius = 30.0;

  @override
  void onActivate() {
    _panTool.onActivate();
    _measurementSub = _service.measurementStream.listen(_onMeasurement);
    _selectedLayerSub = _ref.listen(selectedLayerNodeProvider, (_, _) {
      _notifyUI();
    });
    AppLogger.debug('[TruPulseTool] activated');
  }

  @override
  void onDeactivate() {
    _panTool.onDeactivate();
    _measurementSub?.cancel();
    _measurementSub = null;
    _selectedLayerSub?.close();
    _selectedLayerSub = null;
    _mapState = null;
    _dismissMenu?.call();
    _dismissMenu = null;
    AppLogger.debug('[TruPulseTool] deactivated');
  }

  // =========================================================
  // Measurement → point creation
  // =========================================================

  Future<void> _playSound(String assetPath) async {
    _lastPlayedAsset = assetPath;
    try {
      await _player.setPlaybackRate(1.0);
      await _player.play(AssetSource(assetPath));
    } catch (e) {
      AppLogger.debug('[TruPulseTool] Sound playback failed ($assetPath): $e');
    }
  }

  Future<void> _rejectMeasurement(String title, {String? detail}) async {
    _ref.read(notificationCenterProvider.notifier).add(
      title: title,
      detail: detail,
      level: NotificationLevel.warning,
    );
    await _playSound('sounds/survey_error.wav');
  }

  Future<void> _onMeasurement(TruPulseMeasurement m) async {
    AppLogger.debug('[TruPulseTool] _onMeasurement called: $m');
    try {
      if (_station == null || _station!.isDisposed) {
        AppLogger.debug('[TruPulseTool] Station not set');
        await _rejectMeasurement(
          t.trupulse.noStationSet,
          detail: t.trupulse.panel.tapToSetStation,
        );
        return;
      }

      final stn = _station!;
      final stnLayer = stn.parent;
      final selectedLayer = _ref.read(selectedLayerNodeProvider);

      // ポイントレイヤが選択されていない状態での誤記録を防ぐ
      if (selectedLayer is! PointLayerNode) {
        AppLogger.debug('[TruPulseTool] Point layer not selected (selected: ${selectedLayer?.name})');
        await _rejectMeasurement(t.trupulse.noPointLayerSelected);
        return;
      }

      // 選択中のポイントレイヤが器械点のレイヤと異なる場合も誤記録を防ぐ
      if (selectedLayer != stnLayer) {
        AppLogger.debug('[TruPulseTool] Selected layer (${selectedLayer.name}) != station layer (${stnLayer.name})');
        await _rejectMeasurement(t.trupulse.stationLayerMismatch(layer: stnLayer.name));
        return;
      }

      // 非表示レイヤには記録しない
      if (!stnLayer.isVisibleRecursive()) {
        AppLogger.debug('[TruPulseTool] Station layer is invisible: ${stnLayer.name}');
        await _rejectMeasurement(t.trupulse.layerInvisible(layer: stnLayer.name));
        return;
      }

      // 読み取り専用レイヤ（shp・GeoJSON など）の点を基準点にしていても書き込まない
      if (refuseReadOnlyEditBy(_ref.read, stn)) {
        await _playSound('sounds/survey_error.wav');
        return;
      }

      final shot = await TraverseRecorder.record(
        stn,
        TraverseReading(az: m.az, inc: m.inc, hd: m.hd, sd: m.sd, vd: m.vd, timestamp: m.timestamp),
        trueAz: trueAzimuth,
      );
      if (shot == null) {
        AppLogger.debug('[TruPulseTool] Failed to record measurement');
        await _playSound('sounds/survey_error.wav');
        return;
      }

      // 戻りの後視では器械点が1つ手前へ移る（ハイライトもそちらへ）
      _station = shot.station;
      _ref.read(featureRefreshTriggerProvider.notifier).trigger();
      _mapState?.refreshFeatures();
      _notifyUI();
      if (shot.kind != TraverseShotKind.forward) {
        final exceeded = _notifyBacksight(shot);
        await _playSound(
          exceeded ? 'sounds/backsight_warning.wav' : 'sounds/backsight_applied.wav',
        );
      } else {
        await _playSound('sounds/point_created.wav');
      }

      AppLogger.debug(
        '[TruPulseTool] ${shot.kind.name}: '
        '(${shot.point.point.latitude.toStringAsFixed(6)}, ${shot.point.point.longitude.toStringAsFixed(6)}), '
        'shifted ${shot.shifted}',
      );
    } catch (e, st) {
      AppLogger.debug('[TruPulseTool] _onMeasurement error: $e\n$st');
    }
  }

  /// 後視補正の通知。許容誤差基準を超えていれば true を返し警告として通知する
  bool _notifyBacksight(TraverseShot shot) {
    final delta = TraverseRecorder.backsightDeltaOf(shot.point);
    final double azDelta;
    final double hdDelta;
    if (delta != null) {
      azDelta = delta.azDeg;
      hdDelta = delta.hdM;
    } else {
      final adopted = shot.adopted!;
      azDelta = ((adopted.az - shot.forwardAz! + 540) % 360 - 180).abs() * 2;
      hdDelta = (adopted.hd - shot.forwardHd!).abs() * 2;
    }
    final effectiveDelta = delta ?? BacksightDelta(azDeg: azDelta, hdM: hdDelta);
    final tolerance = _ref.read(backsightToleranceSettingProvider);
    final exceeded = tolerance.isExceededBy(effectiveDelta);

    final detail = t.trupulse.backsightDetail(
      azDelta: azDelta.toStringAsFixed(1),
      hdDelta: hdDelta.toStringAsFixed(2),
    );
    final fromLabel = _pointLabel(shot.point);
    final toLabel = shot.legStation != null ? _pointLabel(shot.legStation!) : '?';
    final String title;
    if (shot.kind == TraverseShotKind.reverseBacksight) {
      title = exceeded
          ? t.trupulse.backsightReverseWarning(from: fromLabel, to: toLabel)
          : t.trupulse.backsightReverse(from: fromLabel, to: toLabel);
    } else {
      title = exceeded ? t.trupulse.backsightWarning : t.trupulse.backsightApplied;
    }
    _ref.read(notificationCenterProvider.notifier).add(
      title: title,
      detail: detail,
      level: exceeded ? NotificationLevel.warning : NotificationLevel.success,
    );
    return exceeded;
  }

  /// 点の呼び名。名前があれば名前、なければ導線の順番（起点 P0、続いて P1, P2, …）
  String _pointLabel(PointFeatureNode p) {
    if (p.name.isNotEmpty) return p.name;
    final layer = p.parent;
    if (layer is PointLayerNode) {
      for (final chain in SurveyChainResolver.resolveAll(layer)) {
        if (chain.origin == p) return 'P0';
        final i = chain.points.indexWhere((tp) => tp.node == p);
        if (i >= 0) return 'P${i + 1}';
      }
    }
    return t.trupulse.panel.point;
  }

  // =========================================================
  // Tap → radial menu
  // =========================================================

  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    _mapState = mapState;
    _dismissMenu?.call();

    PointFeatureNode? nearest;
    double nearestDist = double.infinity;
    for (final pf in mapState.pointFeatures) {
      final screenPos = mapState.latLngToOffset(pf.point);
      final dist = (screenPos - details.localPosition).distance;
      if (dist < _hitRadius && dist < nearestDist) {
        nearest = pf;
        nearestDist = dist;
      }
    }

    if (nearest != null) {
      _showPointMenu(mapState.context, details.globalPosition, nearest);
    } else {
      _panTool.onTap(details, mapState);
    }
  }

  void _showPointMenu(BuildContext context, Offset center, PointFeatureNode target) {
    // 基準点・削除などはどれも書き込むので、読み取り専用レイヤの点ではメニューを出さない
    if (refuseReadOnlyEditBy(_ref.read, target)) return;
    final dependents = _findDependents(target);

    _dismissMenu = showRadialMenu(
      context: context,
      center: center,
      actions: [
        RadialAction(
          icon: Icons.my_location,
          label: t.trupulse.menu.station,
          color: Colors.blue.shade100,
          onTap: () {
            _station = target;
            final layer = target.parent;
            if (_ref.read(selectedLayerNodeProvider) != layer) {
              _ref.read(selectedLayerNodeProvider.notifier).select(layer);
            }
            AppLogger.debug('[TruPulseTool] Station set: ${target.name}');
            _notifyUI();
          },
        ),
        RadialAction(
          icon: Icons.delete,
          label: t.common.delete,
          color: Colors.red.shade100,
          onTap: () {
            if (dependents.isEmpty) {
              _deletePoint(target);
            }
          },
          secondaryActions: dependents.isEmpty
              ? null
              : [
                  RadialAction(
                    icon: Icons.link,
                    label: t.trupulse.menu.bridge,
                    color: Colors.orange.shade100,
                    onTap: () => _bridgeDelete(target, dependents),
                  ),
                  RadialAction(
                    icon: Icons.open_with,
                    label: t.trupulse.menu.shift,
                    color: Colors.purple.shade100,
                    onTap: () => _shiftDelete(target, dependents),
                  ),
                ],
        ),
      ],
    );
  }

  // =========================================================
  // Chain utilities (nearest-point based)
  // =========================================================

  /// Find all points in the same layer that reference [target] as their station.
  List<PointFeatureNode> _findDependents(PointFeatureNode target) => SurveyStation.dependentsOf(target);

  // =========================================================
  // Deletion strategies
  // =========================================================

  /// Simple delete (no dependents).
  Future<void> _deletePoint(PointFeatureNode target) async {
    if (_station == target) _station = null;
    await target.dispose();
    _ref.read(featureRefreshTriggerProvider.notifier).trigger();
    _mapState?.refreshFeatures();
    _notifyUI();
    AppLogger.debug('[TruPulseTool] Point deleted');
  }

  /// Bridge delete: reconnect dependents to target's station, then delete target.
  Future<void> _bridgeDelete(
    PointFeatureNode target,
    List<PointFeatureNode> dependents,
  ) async {
    final targetStn = target.turfFeature.properties?['survey_stn'];

    for (final dep in dependents) {
      if (targetStn != null) {
        await dep.setAttributeValue('survey_stn', targetStn);
      }
    }

    if (_station == target) _station = null;
    await target.dispose();
    _ref.read(featureRefreshTriggerProvider.notifier).trigger();
    _mapState?.refreshFeatures();
    _notifyUI();
    AppLogger.debug('[TruPulseTool] Bridge delete completed');
  }

  /// Shift delete: translate all forward-chain points by -v, then delete target.
  ///
  /// For direct dependents D whose survey_stn = P, shifting by -v gives:
  ///   P - (P - A) = A  — naturally reconnects to target's station.
  /// For indirect dependents whose survey_stn = D_old, shifting gives:
  ///   D_old - v = D_new — correctly tracks the moved reference point.
  Future<void> _shiftDelete(
    PointFeatureNode target,
    List<PointFeatureNode> dependents,
  ) async {
    final targetStnCoords = _parseStnCoords(
      target.turfFeature.properties?['survey_stn'],
    );
    if (targetStnCoords == null) {
      await _bridgeDelete(target, dependents);
      return;
    }

    final vLat = target.point.latitude - targetStnCoords.latitude;
    final vLon = target.point.longitude - targetStnCoords.longitude;

    // Collect chain BEFORE any mutations so dependents are matched on original data.
    final chain = SurveyStation.downstreamOf(target);
    await SurveyStation.translate(chain, -vLat, -vLon);

    if (_station == target) _station = null;
    await target.dispose();
    _ref.read(featureRefreshTriggerProvider.notifier).trigger();
    _mapState?.refreshFeatures();
    _notifyUI();
    AppLogger.debug('[TruPulseTool] Shift delete completed (${chain.length} points shifted)');
  }

  /// 現在のStationが属するレイヤの測量チェーンを取得
  TraverseChain? get currentChain {
    final layer = _station?.parent;
    if (layer is! PointLayerNode) return null;
    final chains = SurveyChainResolver.resolveAll(layer);
    if (chains.isEmpty) return null;
    // Stationを含むチェーンを返す
    for (final chain in chains) {
      if (chain.origin == _station) return chain;
      if (chain.points.any((p) => p.node == _station)) return chain;
    }
    return chains.first;
  }

  // =========================================================
  // PanTool delegation
  // =========================================================

  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) =>
      _panTool.onScaleStart(details, mapState);
  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) =>
      _panTool.onScaleUpdate(details, mapState);
  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) =>
      _panTool.onScaleEnd(details, mapState);
  @override
  void onPointerSignal(PointerEvent event, IMapState mapState) {
    if (event is PointerScrollEvent) {
      _panTool.handleMouseWheelZoom(event, mapState);
    }
  }

  @override
  void onMiddleButtonDown(PointerDownEvent event, IMapState mapState) =>
      _panTool.onMiddleButtonDown(event, mapState);
  @override
  void onMiddleButtonMove(PointerMoveEvent event, IMapState mapState) =>
      _panTool.onMiddleButtonMove(event, mapState);
  @override
  void onMiddleButtonUp(PointerUpEvent event, IMapState mapState) =>
      _panTool.onMiddleButtonUp(event, mapState);

  // =========================================================
  // Overlay drawing (data-driven)
  // =========================================================

  LayerNode? get _overlayLayer {
    final selected = _ref.read(selectedLayerNodeProvider);
    if (selected is PointLayerNode) return selected;
    return _station?.parent;
  }

  @override
  LatLng? get overlayStation => _station?.point;

  /// 基準点 → 計測点の線（描画系に依らない形）
  @override
  List<geo.Feature<geo.LineString>> overlayLines() {
    final layer = _overlayLayer;
    if (layer == null) return [];

    final lines = <geo.Feature<geo.LineString>>[];

    for (final child in layer.children) {
      if (child is! PointFeatureNode) continue;
      final stnGeoJson = child.turfFeature.properties?['survey_stn'];
      if (stnGeoJson == null) continue;

      final coords = _parseStnCoords(stnGeoJson);
      if (coords == null) continue;

      lines.add(geo.Feature<geo.LineString>(
        geometry: geo.LineString.from([
          coords.toGeographic(),
          child.point.toGeographic(),
        ]),
      ));
    }
    return lines;
  }

  @override
  Widget buildStatusPanel(BuildContext context) =>
      TruPulseStatusPanel(tool: this);

  @override
  Widget? buildDetailScreen(BuildContext context) =>
      TruPulseDetailScreen(service: _service);

  // =========================================================
  // GeoJSON parsing
  // =========================================================

  static LatLng? _parseStnCoords(dynamic value) => SurveyStation.parse(value);
}

// =========================================================
// Marker widget
// =========================================================

