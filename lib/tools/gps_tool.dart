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
// lib/tools/gps_tool.dart
// GPS関連機能を扱うツール（GPS測量機能対応）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../interfaces/map_state_interface.dart';
import '../models/gnss_quality.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../providers/gps_providers.dart';
import '../providers/selection_providers.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/gps_manager_service.dart';
import '../utils/global_drawing_state.dart';
import '../widgets/external_layer_actions.dart';
import 'map_tool.dart';
import 'pan_tool.dart';

/// GPS 測量 1 回の結果
class GpsSurveyResult {
  const GpsSurveyResult._({
    required this.recorded,
    this.rejectReasons = const [],
    this.warnings = const [],
    this.excluded = 0,
    this.excludeReasons = const [],
  });

  /// 位置が取れなかった・保存できなかった
  static const failed = GpsSurveyResult._(recorded: false);

  const GpsSurveyResult.rejected(List<String> reasons) : this._(recorded: false, rejectReasons: reasons);

  const GpsSurveyResult.recorded({
    List<String> warnings = const [],
    int excluded = 0,
    List<String> excludeReasons = const [],
  }) : this._(recorded: true, warnings: warnings, excluded: excluded, excludeReasons: excludeReasons);

  final bool recorded;

  /// 足切りで記録しなかった理由（記録しなかったときだけ）
  final List<String> rejectReasons;

  /// 足切りを警告だけにしていて満たさなかった条件
  final List<String> warnings;

  /// 長押しの平均から外した回数とその理由
  final int excluded;
  final List<String> excludeReasons;

  bool get isRejected => rejectReasons.isNotEmpty;
}

/// GPS関連機能を扱うツール
///
/// GPS測量機能を提供し、現在位置を記録してフィーチャを作成します:
/// - 現在位置の記録によるPoint/Line/Polygonフィーチャ作成
/// - GPS精度情報の記録・表示
/// - GPS測量データの履歴管理
/// - パンツール機能の継承
///
/// Features:
/// - GPS測量機能（Point/Line/Polygon作成）
/// - GPS位置データの詳細記録（精度、時刻、データソース）
/// - パンツールへのプロキシパターン実装
/// - リアルタイムプレビュー表示
class GpsTool extends MapTool with PanDelegation {
  GpsTool(this._ref);
  final Ref _ref;

  @override
  String get name => 'GPS';

  @override
  IconData get icon => Icons.gps_fixed;

  @override
  PanTool get panTool => _ref.read(panToolProvider);

  GlobalDrawingState get drawingState => GlobalDrawingState.instance;

  /// GPS管理サービスインスタンス
  final GpsManagerService _gpsManager = GpsManagerService();

  /// 長押しGPS測量用データ
  bool _isLongPressing = false;
  final List<Map<String, dynamic>> _longPressGpsData = [];
  DateTime? _longPressStartTime;

  /// 長押し中に集めた点の数（増えると通知する）
  int get longPressGpsCount =>
      _isLongPressing ? _gpsManager.continuousSurveyCount : _longPressGpsData.length;

  /// 長押し中に足切りの条件を満たさなかった点の数
  int get longPressRejectedCount => _isLongPressing ? _liveRejected : 0;
  int _liveRejected = 0;

  /// 足切りの条件（設定 → GPS・測位）
  GnssQualityGate get _gate => _ref.read(gnssQualityGateSettingProvider);

  @override
  void onActivate() => _initializeGpsFeatures();

  @override
  void onDeactivate() => _cleanupGpsFeatures();

  // 地図の操作はてのひらツールと同じ（タップは選択）
  @override
  void onTap(TapUpDetails details, IMapState mapState) => panTool.onTap(details, mapState);

  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) => panTool.onScaleStart(details, mapState);

  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) => panTool.onScaleUpdate(details, mapState);

  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) => panTool.onScaleEnd(details, mapState);

  // --- GPS測量機能実装 ---

  /// GPS機能の初期化
  void _initializeGpsFeatures() {
    // GPS測量データの初期化（GlobalDrawingStateを使用）
    drawingState.clearAll();
    AppLogger.debug('[GpsTool] GPS測量機能を初期化しました');
  }

  /// GPS機能のクリーンアップ
  void _cleanupGpsFeatures() {
    // GPS測量データのクリア（GlobalDrawingStateを使用）
    drawingState.clearAll();

    // 長押し関連もクリア
    _isLongPressing = false;
    _longPressGpsData.clear();
    _longPressStartTime = null;

    // GPS Manager Service の連続測量もクリア
    _gpsManager.stopContinuousSurvey();
    _gpsManager.clearContinuousSurveyData();

    AppLogger.debug('[GpsTool] GPS測量機能をクリーンアップしました');
  }

  /// 長押しGPS測量開始（位置更新ベース）
  void startLongPressGpsSurvey() {
    AppLogger.debug('[GpsTool] 長押しGPS測量開始（位置更新ベース）');

    _isLongPressing = true;
    _longPressStartTime = DateTime.now();
    _longPressGpsData.clear();
    _liveRejected = 0;

    // GPS測量専用開始
    _gpsManager.startGpsSurveyWithWait().then((_) {
      // GPS Manager Service の連続測量機能を使用（位置更新ベース）
      _gpsManager.startContinuousSurvey(
        onPositionUpdate: _onContinuousSurveyUpdate,
      );
    });
  }

  /// 長押しGPS測量停止と平均化処理（位置更新ベース）。
  /// 足切りの条件があれば、満たさない点を平均から外す（警告だけにしていれば外さずに警告する）
  Future<GpsSurveyResult> stopLongPressGpsSurvey() async {
    AppLogger.debug('[GpsTool] 長押しGPS測量停止 - GPS平均化処理開始（位置更新ベース）');

    _isLongPressing = false;

    // GPS Manager Service の連続測量を停止
    _gpsManager.stopContinuousSurvey();

    // 最終的なデータを取得
    final finalData = _gpsManager.getContinuousSurveyData();
    _longPressGpsData.clear();

    AppLogger.debug('[GpsTool] 位置更新ベース連続測量を停止しました');

    if (finalData.isEmpty) {
      AppLogger.debug('[GpsTool] 長押し中にGPSデータが取得できませんでした');
      return GpsSurveyResult.failed;
    }

    try {
      // 足切り
      final gate = _gate;
      final samples = <GnssSample, Map<String, dynamic>>{
        for (final m in finalData) ?GnssSample.fromMap(m): m,
      };
      final gated = applyGate(gate, samples.keys.toList());
      if (gated.isRejected) {
        _longPressStartTime = null;
        _gpsManager.clearContinuousSurveyData();
        return GpsSurveyResult.rejected(gated.reasons);
      }
      _longPressGpsData.addAll([for (final s in gated.accepted) samples[s]!]);

      // GPS平均化計算
      final averagedResult = _calculateAveragedGpsPosition(_longPressGpsData);
      final position = LatLng(
        averagedResult['latitude'],
        averagedResult['longitude'],
      );
      final warnings = gate.strict ? const <String>[] : gated.reasons;
      final quality = GnssQuality.aggregate(
        gated.accepted,
        seconds: _elapsedSeconds(),
        rejected: gated.rejected,
        warnings: warnings,
      );

      // 最適化されたdescription辞書構造を作成
      final optimizedGpsData = _createOptimizedGpsDescription(
        averagedResult,
        _longPressGpsData,
        quality: quality,
      );

      AppLogger.debug('[GpsTool] 長押し測量 quality: ${quality.toJson()}');

      final result = GpsSurveyResult.recorded(
        warnings: warnings,
        excluded: gated.rejected,
        excludeReasons: gate.strict ? gated.reasons : const [],
      );

      // 現在選択中のレイヤーに応じてデータを追加
      final selected = _ref.read(selectedLayerNodeProvider);
      // 読み取り専用レイヤ（shp・GeoJSON など）には記録しない
      if (refuseReadOnlyEditBy(_ref.read, selected)) return GpsSurveyResult.failed;
      if (selected is PointLayerNode) {
        final ok = await _recordPoint(
          selected,
          position,
          {
            'altitude': averagedResult['altitude'],
            'accuracy': averagedResult['accuracy'],
            ..._gpsAttributes(_longPressGpsData.first),
            'nmea': _longPressGpsData.last['nmea'],
            'sample_count': averagedResult['sampleCount'],
          },
          optimizedGpsData,
        );
        return ok ? result : GpsSurveyResult.failed;
      }
      _addToDrawing(selected, position, optimizedGpsData);

      // クリーンアップ
      _longPressGpsData.clear();
      _longPressStartTime = null;
      _gpsManager.clearContinuousSurveyData();

      return result;
    } catch (e) {
      AppLogger.debug('[GpsTool] 長押しGPS測量エラー: $e');
      return GpsSurveyResult.failed;
    }
  }

  /// 長押しを始めてからの秒数
  double _elapsedSeconds() {
    final start = _longPressStartTime;
    return start == null ? 0 : DateTime.now().difference(start).inMilliseconds / 1000.0;
  }

  /// 現在のGPS位置を記録（単発）。足切りの条件を満たさなければ記録しない（警告だけにしていれば記録して警告）
  ///
  /// [into] を渡すと選択中のレイヤでなくそのレイヤに点を作り、[extra] の属性も書く（毎木調査の記録）
  Future<GpsSurveyResult> recordCurrentGpsPosition({
    PointLayerNode? into,
    Map<String, dynamic> extra = const {},
  }) async {
    // 長押し中の場合は何もしない
    if (_isLongPressing) {
      AppLogger.debug('[GpsTool] 長押し中のため単発GPS記録をスキップ');
      return GpsSurveyResult.failed;
    }

    try {
      // GPS測量専用開始（位置取得まで待機）
      final gpsInfo = (await _gpsManager.startGpsSurveyWithWait())?.toMap();
      AppLogger.debug('[GpsTool] 単発測量 gpsInfo: $gpsInfo');

      if (gpsInfo == null || gpsInfo['isActive'] != true) {
        AppLogger.debug('[GpsTool] GPS位置情報が利用できません。位置情報の許可が必要です。');
        return GpsSurveyResult.failed;
      }

      final latitude = gpsInfo['latitude'] as double;
      final longitude = gpsInfo['longitude'] as double;
      final position = LatLng(latitude, longitude);

      // 通常測量も1つの点の平均として扱う（長押し測量と形式統一）
      final singleGpsData = {
        'latitude': latitude,
        'longitude': longitude,
        'altitude': gpsInfo['altitude'],
        'accuracy': gpsInfo['accuracy'],
        'accuracySource': gpsInfo['accuracySource'],
        'speed': gpsInfo['speed'],
        'bearing': gpsInfo['bearing'],
        'timestamp': gpsInfo['timestamp'],
        'sourceType': gpsInfo['sourceType'],
        'sourceName': gpsInfo['sourceName'],
        'selectedDevice': gpsInfo['selectedDevice'],
        'collectedAt': DateTime.now().toIso8601String(),
        // 拡張属性（外部GNSS用）
        'hdop': gpsInfo['hdop'],
        'pdop': gpsInfo['pdop'],
        'vdop': gpsInfo['vdop'],
        'satelliteCount': gpsInfo['satelliteCount'],
        'gpsQuality': gpsInfo['gpsQuality'],
        'fixType': gpsInfo['fixType'],
        'nmea': gpsInfo['nmea'],
      };
      AppLogger.debug('[GpsTool] 単発測量 singleGpsData: $singleGpsData');

      // 足切り
      final gate = _gate;
      final sample = GnssSample.fromMap(singleGpsData)!;
      final gated = applyGate(gate, [sample]);
      if (gated.isRejected) return GpsSurveyResult.rejected(gated.reasons);
      final warnings = gate.strict ? const <String>[] : gated.reasons;
      final quality = GnssQuality.aggregate([sample], seconds: 0, warnings: warnings);

      // 1つの点から平均を計算（実質的には同じ値）
      final averagedResult = _calculateAveragedGpsPosition([singleGpsData]);
      AppLogger.debug('[GpsTool] 単発測量 averagedResult: $averagedResult');

      // 長押し測量と同じ最適化された辞書構造を作成
      final optimizedGpsData = _createOptimizedGpsDescription(
        averagedResult,
        [singleGpsData],
        quality: quality,
        isSingleTap: true, // 通常測量フラグ
      );

      AppLogger.debug('[GpsTool] 単発測量 optimizedGpsData: $optimizedGpsData');

      // 現在選択中のレイヤーに応じてデータを追加
      final LayerNode? selected = into ?? _ref.read(selectedLayerNodeProvider);
      // 読み取り専用レイヤ（shp・GeoJSON など）には記録しない
      if (refuseReadOnlyEditBy(_ref.read, selected)) return GpsSurveyResult.failed;
      if (selected is PointLayerNode) {
        final ok = await _recordPoint(
          selected,
          position,
          {
            'altitude': gpsInfo['altitude'],
            'accuracy': gpsInfo['accuracy'],
            ..._gpsAttributes(gpsInfo),
            'nmea': gpsInfo['nmea'],
            'sample_count': 1, // 単発測量なので1
            ...extra,
          },
          optimizedGpsData,
        );
        return ok ? GpsSurveyResult.recorded(warnings: warnings) : GpsSurveyResult.failed;
      }
      _addToDrawing(selected, position, optimizedGpsData);

      AppLogger.debug(
        '[GpsTool] GPS位置を記録: Lat ${latitude.toStringAsFixed(6)}, '
        'Lon ${longitude.toStringAsFixed(6)}, '
        'Accuracy ${(gpsInfo['accuracy'] as num?)?.toStringAsFixed(1) ?? 'N/A'}m',
      );

      return GpsSurveyResult.recorded(warnings: warnings);
    } catch (e) {
      AppLogger.debug('[GpsTool] GPS位置記録エラー: $e');
      return GpsSurveyResult.failed;
    }
  }

  /// GPS の値のうち点の属性に写すもの（GPS 側の名前 → 列名）
  static const _gpsAttributeColumns = {
    'speed': 'speed',
    'bearing': 'bearing',
    'sourceType': 'source_type',
    // 拡張属性（外部GNSS用）
    'hdop': 'hdop',
    'satelliteCount': 'satellite_count',
    'fixType': 'fix_type',
    'correctionSource': 'correction_source',
  };

  Map<String, dynamic> _gpsAttributes(Map<String, dynamic> gps) => {
    for (final MapEntry(:key, :value) in _gpsAttributeColumns.entries)
      value: gps[key],
  };

  /// GPS 測量の点を作り、属性を個別カラムに書いて GPS 測量を止める。
  /// 値が null の属性は書かない。測量の記録 [surveyRecord] は線・面の頂点と同じ形でメタデータの列に残す
  Future<bool> _recordPoint(
    PointLayerNode layer,
    LatLng position,
    Map<String, dynamic> attributes,
    Map<String, dynamic> surveyRecord,
  ) async {
    final pointFeature = await PointFeatureNode.createIn(
      layer,
      position,
      '',
      '',
      metadata: {
        'drawing_points': [surveyRecord],
      },
    );
    if (pointFeature == null) {
      AppLogger.debug('[ERROR] GPS測量ポイントフィーチャの作成に失敗しました');
      return false;
    }
    // カラムが存在しない場合は自動作成される
    await pointFeature.setAttributeValues({
      for (final MapEntry(:key, :value) in attributes.entries)
        key: ?value,
      'timestamp': DateTime.now().toIso8601String(),
    });
    _ref.read(featureRefreshTriggerProvider.notifier).trigger();

    // Point測量完了後はGPS測量を止める
    await _gpsManager.stopGpsSurvey();
    return true;
  }

  /// 線・面のレイヤなら、測った点を描きかけに GPS 測量データとして足す
  void _addToDrawing(LayerNode? layer, LatLng position, Map<String, dynamic> surveyData) {
    switch (layer) {
      case LineLayerNode():
        drawingState.addPoint(position, surveyData, isLine: true);
      case PolygonLayerNode():
        drawingState.addPoint(position, surveyData, isLine: false);
      default:
    }
  }

  /// GPS平均化計算
  Map<String, dynamic> _calculateAveragedGpsPosition(
    List<Map<String, dynamic>> gpsDataList,
  ) {
    if (gpsDataList.isEmpty) {
      throw Exception('GPS データが空です');
    }

    double totalLatitude = 0.0;
    double totalLongitude = 0.0;
    double totalAltitude = 0.0;
    double totalAccuracy = 0.0;
    int validAltitudeCount = 0;
    int validAccuracyCount = 0;

    for (final data in gpsDataList) {
      totalLatitude += data['latitude'] as double;
      totalLongitude += data['longitude'] as double;

      if (data['altitude'] != null) {
        totalAltitude += data['altitude'] as double;
        validAltitudeCount++;
      }

      if (data['accuracy'] != null) {
        totalAccuracy += data['accuracy'] as double;
        validAccuracyCount++;
      }
    }

    final count = gpsDataList.length;
    return {
      'latitude': totalLatitude / count,
      'longitude': totalLongitude / count,
      'altitude':
          validAltitudeCount > 0 ? totalAltitude / validAltitudeCount : null,
      'accuracy':
          validAccuracyCount > 0 ? totalAccuracy / validAccuracyCount : null,
      'sampleCount': count,
    };
  }

  /// 最適化されたGPS description辞書構造を作成
  Map<String, dynamic> _createOptimizedGpsDescription(
    Map<String, dynamic> averagedResult,
    List<Map<String, dynamic>> rawGpsDataList, {
    required GnssQuality quality,
    bool isSingleTap = false,
  }) {
    // デバッグ出力
    // AppLogger.debug('[GpsTool] _createOptimizedGpsDescription 入力データ:');
    // AppLogger.debug('  averagedResult: $averagedResult');
    // AppLogger.debug('  rawGpsDataList.length: ${rawGpsDataList.length}');
    // AppLogger.debug('  rawGpsDataList: $rawGpsDataList');

    final duration =
        _longPressStartTime != null && !isSingleTap
            ? DateTime.now().difference(_longPressStartTime!).inMilliseconds /
                1000.0
            : 0.0;

    final result = {
      'pointNumber': _getNextPointNumber(),
      'calculatedPosition': {
        'latitude': averagedResult['latitude'],
        'longitude': averagedResult['longitude'],
        'altitude': averagedResult['altitude'],
        'averagedAccuracy': averagedResult['accuracy'],
      },
      'usedGpsData': List<Map<String, dynamic>>.from(rawGpsDataList),
      'sampleCount': rawGpsDataList.length,
      'point_count': rawGpsDataList.length, // マーカー表示用の点数
      'averagingDuration':
          isSingleTap ? t.gps.instantMeasurement : t.gps.durationSeconds(duration: duration.toStringAsFixed(1)),
      'recordedAt': DateTime.now().toIso8601String(),
      'quality': quality.toJson(),
    };

    // AppLogger.debug('[GpsTool] _createOptimizedGpsDescription 結果: $result');
    return result;
  }

  /// 次のポイント番号を取得
  int _getNextPointNumber() {
    return switch (_ref.read(selectedLayerNodeProvider)) {
      LineLayerNode() => drawingState.drawingLine.length + 1,
      PolygonLayerNode() => drawingState.drawingPolygon.length + 1,
      _ => 1, // PointLayerNode
    };
  }

  /// GPS測量をキャンセル（GPS停止付き）
  Future<void> cancelSurveyWithGpsStop() async {
    _cleanupGpsFeatures();
    await _gpsManager.stopGpsSurvey();
    AppLogger.debug('[GpsTool] GPS測量をキャンセルしてGPS停止しました');
  }

  /// 連続測量位置更新コールバック
  /// 点は GPS Manager Service が持つ（止めたときに受け取る。点が届くたびに一覧を写さない）
  void _onContinuousSurveyUpdate() {
    final gate = _gate;
    final latest = _gpsManager.latestContinuousSample;
    if (gate.isActive && latest != null) {
      final sample = GnssSample.fromMap(latest.toMap());
      if (sample != null && gate.check(sample).isNotEmpty) _liveRejected++;
    }
    notifyListeners(); // 長押し中の点数の表示
  }
}
