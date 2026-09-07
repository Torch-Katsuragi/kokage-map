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
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;

import '../../i18n/strings.g.dart';
import '../../interfaces/map_state_interface.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../providers/device_tool_providers.dart';
import '../../providers/notification_providers.dart';
import '../../providers/selection_providers.dart';
import '../../providers/tool_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/survey/survey_chain_resolver.dart';
import '../../tools/pan_tool.dart';
import '../../utils/app_logger.dart';
import '../../utils/geo_converter.dart';
import '../../widgets/radial_action_menu.dart';
import '../base/device_tool.dart';
import 'trupulse_detail_screen.dart';
import 'trupulse_measurement.dart';
import 'trupulse_service.dart';
import 'trupulse_status_panel.dart';

class TruPulseTool extends DeviceTool {
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

  void _notifyUI() {
    notifyListeners();
    _ref.read(deviceToolOverlayRefreshProvider.notifier).trigger();
  }

  PointFeatureNode? _station;
  LatLng? get stationPosition => _station?.point;
  PointFeatureNode? get station => _station;

  IMapState? _mapState;

  static const double _hitRadius = 30.0;

  // ~1mm squared. Absorbs serialization rounding but rejects missing stations.
  static const double _stnMatchThresholdSq = 1e-16;

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

  Future<void> _onMeasurement(TruPulseMeasurement m) async {
    AppLogger.debug('[TruPulseTool] _onMeasurement called: $m');
    try {
      if (_station == null || _mapState == null) {
        AppLogger.debug('[TruPulseTool] Station or mapState not set');
        return;
      }

      final stn = _station!;
      final stnPos = stn.point;
      final target = const Distance().offset(stnPos, m.hd, m.az);

      // --- バックサイト自動検出 ---
      if (await _tryBacksightCorrection(stn, m, target)) return;

      // --- 通常処理: 新規ポイント作成 ---
      AppLogger.debug('[TruPulseTool] Creating point in layer: ${stn.parent.layerName}');

      final newPoint = await PointFeatureNode.createIn(stn.parent, target, '', '');
      if (newPoint == null) {
        AppLogger.debug('[TruPulseTool] Failed to create point');
        return;
      }

      await newPoint.setAttributeValues({
        'survey_az': m.az,
        'survey_inc': m.inc,
        'survey_hd': m.hd,
        'survey_sd': m.sd,
        'survey_vd': m.vd,
        'survey_stn': jsonEncode({
          'type': 'Point',
          'coordinates': [stnPos.longitude, stnPos.latitude],
        }),
        'survey_timestamp': m.timestamp.toIso8601String(),
      });

      _station = newPoint;
      _ref.read(featureRefreshTriggerProvider.notifier).trigger();
      _mapState?.refreshFeatures();
      _notifyUI();
      await _player.setPlaybackRate(1.0);
      await _player.play(AssetSource('sounds/point_created.wav'));

      AppLogger.debug(
        '[TruPulseTool] Point created at '
        '(${target.latitude.toStringAsFixed(6)}, ${target.longitude.toStringAsFixed(6)})',
      );
    } catch (e, st) {
      AppLogger.debug('[TruPulseTool] _onMeasurement error: $e\n$st');
    }
  }

  // =========================================================
  // Backsight auto-detection
  // =========================================================

  /// ターゲットが前測点の近傍であれば後視として補正を適用し true を返す。
  Future<bool> _tryBacksightCorrection(
    PointFeatureNode stn,
    TruPulseMeasurement m,
    LatLng target,
  ) async {
    final props = stn.turfFeature.properties;
    if (props == null) return false;

    // 起点（survey_stnなし）なら後視不可
    final prevStnJson = props['survey_stn'];
    if (prevStnJson == null) return false;

    // 既に後視補正済みならスキップ
    final backsightDone = props['survey_backsight'];
    if (backsightDone == true || backsightDone == 'true') return false;

    final prevStnCoords = _parseStnCoords(prevStnJson);
    if (prevStnCoords == null) return false;

    // 前視HDを取得して閾値を算出
    final forwardHd = _toDouble(props['survey_hd']);
    if (forwardHd <= 0) return false;
    final threshold = (forwardHd * 0.15).clamp(1.0, 5.0);

    // ターゲットと前測点の距離を比較
    final distToPrev = const Distance(roundResult: false)
        .as(LengthUnit.Meter, target, prevStnCoords);

    if (distToPrev > threshold) return false;

    // --- バックサイト検出! 平均化補正を適用 ---
    AppLogger.debug(
      '[TruPulseTool] Backsight detected! dist=${distToPrev.toStringAsFixed(2)}m '
      '(threshold=${threshold.toStringAsFixed(1)}m)',
    );

    final forwardAz = _toDouble(props['survey_az']);
    final forwardSd = _toDouble(props['survey_sd']);
    final forwardInc = _toDouble(props['survey_inc']);

    // 後視AZを前視方向に変換して円周平均
    final backsightAzForward = (m.az + 180) % 360;
    final correctedAz = _circularMeanDeg(forwardAz, backsightAzForward);
    final correctedHd = (forwardHd + m.hd) / 2;
    final correctedSd = (forwardSd + m.sd) / 2;
    final correctedVd = correctedHd * _tanDeg(forwardInc);

    // 座標を再計算
    final newPos = const Distance().offset(prevStnCoords, correctedHd, correctedAz);

    // 属性を上書き
    await stn.setAttributeValues({
      'survey_az': correctedAz,
      'survey_hd': correctedHd,
      'survey_sd': correctedSd,
      'survey_vd': correctedVd,
      'survey_backsight': true,
    });

    // ジオメトリを更新
    await stn.updateGeometry(
      name: stn.name,
      newGeometry: newPos,
    );

    _ref.read(featureRefreshTriggerProvider.notifier).trigger();
    _mapState?.refreshFeatures();
    _notifyUI();
    await _player.setPlaybackRate(0.7);
    await _player.play(AssetSource('sounds/point_created.wav'));

    // 通知
    final azDelta = (correctedAz - forwardAz).abs();
    final hdDelta = (correctedHd - forwardHd).abs();
    _ref.read(notificationCenterProvider.notifier).add(
      title: t.trupulse.backsightApplied,
      detail: t.trupulse.backsightDetail(
          azDelta: azDelta.toStringAsFixed(1),
          hdDelta: hdDelta.toStringAsFixed(2)),
      level: NotificationLevel.success,
    );

    AppLogger.debug(
      '[TruPulseTool] Backsight correction applied: '
      'AZ ${forwardAz.toStringAsFixed(1)} -> ${correctedAz.toStringAsFixed(1)}, '
      'HD ${forwardHd.toStringAsFixed(2)} -> ${correctedHd.toStringAsFixed(2)}',
    );
    return true;
  }

  /// 2つの角度（度）の円周平均を計算する。
  static double _circularMeanDeg(double a, double b) {
    final aRad = a * math.pi / 180;
    final bRad = b * math.pi / 180;
    final sinSum = math.sin(aRad) + math.sin(bRad);
    final cosSum = math.cos(aRad) + math.cos(bRad);
    final mean = math.atan2(sinSum, cosSum) * 180 / math.pi;
    return mean < 0 ? mean + 360 : mean;
  }

  static double _tanDeg(double deg) => math.tan(deg * math.pi / 180);

  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
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
    final dependents = _findDependents(target);

    _dismissMenu = showRadialMenu(
      context: context,
      center: center,
      actions: [
        RadialAction(
          icon: Icons.my_location,
          label: 'Station',
          color: Colors.blue.shade100,
          onTap: () {
            _station = target;
            AppLogger.debug('[TruPulseTool] Station set: ${target.name}');
            _notifyUI();
          },
        ),
        RadialAction(
          icon: Icons.delete,
          label: 'Delete',
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
                    label: 'Bridge',
                    color: Colors.orange.shade100,
                    onTap: () => _bridgeDelete(target, dependents),
                  ),
                  RadialAction(
                    icon: Icons.open_with,
                    label: 'Shift',
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
  List<PointFeatureNode> _findDependents(PointFeatureNode target) {
    final layer = target.parent;
    return layer.children.whereType<PointFeatureNode>().where((p) {
      final stnCoords = _parseStnCoords(p.turfFeature.properties?['survey_stn']);
      if (stnCoords == null) return false;
      return _findNearestPoint(stnCoords, layer) == target;
    }).toList();
  }

  /// Collect the entire forward chain starting from [start] (BFS).
  List<PointFeatureNode> _collectChainForward(PointFeatureNode start) {
    final result = <PointFeatureNode>[];
    final visited = <PointFeatureNode>{start};
    var frontier = [start];
    while (frontier.isNotEmpty) {
      final next = <PointFeatureNode>[];
      for (final p in frontier) {
        for (final dep in _findDependents(p)) {
          if (visited.add(dep)) {
            result.add(dep);
            next.add(dep);
          }
        }
      }
      frontier = next;
    }
    return result;
  }

  /// Find the nearest PointFeatureNode in [layer] to [coords], within threshold.
  static PointFeatureNode? _findNearestPoint(LatLng coords, LayerNode layer) {
    PointFeatureNode? nearest;
    double nearestDist = double.infinity;
    for (final child in layer.children) {
      if (child is! PointFeatureNode) continue;
      final d = _sqDist(child.point, coords);
      if (d < nearestDist) {
        nearestDist = d;
        nearest = child;
      }
    }
    return (nearest != null && nearestDist < _stnMatchThresholdSq) ? nearest : null;
  }

  static double _sqDist(LatLng a, LatLng b) {
    final dlat = a.latitude - b.latitude;
    final dlon = a.longitude - b.longitude;
    return dlat * dlat + dlon * dlon;
  }

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

    // Collect chain BEFORE any mutations so _findDependents sees original data.
    final chain = _collectChainForward(target);

    for (final p in chain) {
      await p.updateLocation(LatLng(
        p.point.latitude - vLat,
        p.point.longitude - vLon,
      ));
      final pStn = _parseStnCoords(p.turfFeature.properties?['survey_stn']);
      if (pStn != null) {
        await p.setAttributeValue('survey_stn', jsonEncode({
          'type': 'Point',
          'coordinates': [pStn.longitude - vLon, pStn.latitude - vLat],
        }));
      }
    }

    if (_station == target) _station = null;
    await target.dispose();
    _ref.read(featureRefreshTriggerProvider.notifier).trigger();
    _mapState?.refreshFeatures();
    _notifyUI();
    AppLogger.debug('[TruPulseTool] Shift delete completed (${chain.length} points shifted)');
  }

  // =========================================================
  // Station clear
  // =========================================================

  void clearStation() {
    _station = null;
    _notifyUI();
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
  List<ml.Layer> buildOverlayLayers() {
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

    if (lines.isEmpty) return [];

    return [
      ml.PolylineLayer(polylines: lines, color: Colors.red, width: 2),
    ];
  }

  @override
  List<ml.Marker> buildOverlayMarkers() {
    if (_station == null) return [];
    return [
      ml.Marker(
        point: _station!.point.toGeographic(),
        size: const Size.square(24),
        child: const _StationMarker(),
      ),
    ];
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

  static LatLng? _parseStnCoords(dynamic value) {
    try {
      final map = value is String
          ? jsonDecode(value) as Map<String, dynamic>
          : value as Map;
      final c = map['coordinates'] as List;
      return LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
    } catch (_) {
      return null;
    }
  }
}

// =========================================================
// Marker widget
// =========================================================

class _StationMarker extends StatelessWidget {
  const _StationMarker();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.blue.withValues(alpha: 0.8),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: const Icon(Icons.my_location, color: Colors.white, size: 16),
    );
  }
}
