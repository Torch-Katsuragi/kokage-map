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
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../interfaces/map_state_interface.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../providers/selection_providers.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/gps_manager_service.dart';
import '../utils/global_drawing_state.dart';
import 'map_tool.dart';
import 'pan_tool.dart';
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
class GpsTool extends MapTool {
  final Ref _ref;
  GpsTool(this._ref);

  @override
  String get name => 'GPS';

  @override
  IconData get icon => Icons.gps_fixed;

  PanTool get _panTool => _ref.read(panToolProvider);

  GlobalDrawingState get drawingState => GlobalDrawingState.instance;

  /// GPS管理サービスインスタンス
  final GpsManagerService _gpsManager = GpsManagerService();

  /// 長押しGPS測量用データ
  Timer? _longPressTimer;
  Timer? _gpsCollectionTimer;
  bool _isLongPressing = false;
  final List<Map<String, dynamic>> _longPressGpsData = [];
  DateTime? _longPressStartTime;

  /// GPS測量機能のgetters（GlobalDrawingStateから取得）
  List<LatLng> get surveyLine => drawingState.drawingLine;
  List<LatLng> get surveyPolygon => drawingState.drawingPolygon;
  int get longPressGpsCount => _longPressGpsData.length;

  /// ツール有効化時の初期化処理
  /// パンツールの初期化を呼び出し、GPS関連の初期化も行う
  @override
  void onActivate() {
    _panTool.onActivate();
    _initializeGpsFeatures();
  }

  /// ツール無効化時の終了処理
  /// パンツールの終了処理を呼び出し、GPS関連のクリーンアップも行う
  @override
  void onDeactivate() {
    _panTool.onDeactivate();
    _cleanupGpsFeatures();
  }

  /// タップイベント - パンツールに丸投げ
  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    _panTool.onTap(details, mapState);
  }

  /// スケール開始イベント - パンツールに丸投げ
  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {
    _panTool.onScaleStart(details, mapState);
  }

  /// スケール更新イベント - パンツールに丸投げ
  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {
    _panTool.onScaleUpdate(details, mapState);
  }

  /// スケール終了イベント - パンツールに丸投げ
  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) {
    _panTool.onScaleEnd(details, mapState);
  }

  /// バッファへの座標追加 - パンツールのバッファと同期
  @override
  void addPointerToBuffer(Offset offset) {
    super.addPointerToBuffer(offset);
    _panTool.addPointerToBuffer(offset);
  }

  /// バッファクリア - パンツールのバッファと同期
  @override
  void clearPointerBuffer() {
    super.clearPointerBuffer();
    _panTool.clearPointerBuffer();
  }

  /// バッファ内容取得 - パンツールのバッファを返す
  @override
  List<Offset> getPointerBuffer() {
    return _panTool.getPointerBuffer();
  }

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
    _gpsCollectionTimer?.cancel();
    _gpsCollectionTimer = null;
    _longPressTimer?.cancel();
    _longPressTimer = null;
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

    // GPS測量専用開始
    _gpsManager.startGpsSurveyWithWait().then((_) {
      // GPS Manager Service の連続測量機能を使用（位置更新ベース）
      _gpsManager.startContinuousSurvey(
        onPositionUpdate: _onContinuousSurveyUpdate,
      );
    });
  }

  /// 長押しGPS測量停止と平均化処理（位置更新ベース）
  Future<bool> stopLongPressGpsSurvey() async {
    AppLogger.debug('[GpsTool] 長押しGPS測量停止 - GPS平均化処理開始（位置更新ベース）');

    _isLongPressing = false;

    // GPS Manager Service の連続測量を停止
    _gpsManager.stopContinuousSurvey();

    // 最終的なデータを取得
    final finalData = _gpsManager.getContinuousSurveyData();
    _longPressGpsData.clear();
    _longPressGpsData.addAll(finalData);

    AppLogger.debug('[GpsTool] 位置更新ベース連続測量を停止しました');

    if (_longPressGpsData.isEmpty) {
      AppLogger.debug('[GpsTool] 長押し中にGPSデータが取得できませんでした');
      return false;
    }

    try {
      // GPS平均化計算
      final averagedResult = _calculateAveragedGpsPosition(_longPressGpsData);
      final position = LatLng(
        averagedResult['latitude'],
        averagedResult['longitude'],
      );

      // 最適化されたdescription辞書構造を作成
      final optimizedGpsData = _createOptimizedGpsDescription(
        averagedResult,
        _longPressGpsData,
      );

      AppLogger.debug('[GpsTool] 長押し測量 optimizedGpsData: $optimizedGpsData');

      // 現在選択中のレイヤーに応じてデータを追加
      final selected = _ref.read(selectedLayerNodeProvider);
      if (selected is PointLayerNode) {
        // GPS測量時は即座にPointフィーチャを作成（メタデータなし、個別カラムに保存）
        final pointFeature = await PointFeatureNode.createIn(
          selected,
          position,
          '', // nameは空
          '', // descriptionも空
        );

        if (pointFeature != null) {
          // GPS属性を個別カラムとして設定（拡張版）
          final attributes = <String, dynamic>{};

          // 平均化された結果から属性を設定
          if (averagedResult['altitude'] != null) {
            attributes['altitude'] = averagedResult['altitude'];
          }
          if (averagedResult['accuracy'] != null) {
            attributes['accuracy'] = averagedResult['accuracy'];
          }

          // 最初のGPSデータから追加属性を取得
          if (_longPressGpsData.isNotEmpty) {
            final firstData = _longPressGpsData.first;
            if (firstData['speed'] != null) {
              attributes['speed'] = firstData['speed'];
            }
            if (firstData['bearing'] != null) {
              attributes['bearing'] = firstData['bearing'];
            }
            if (firstData['sourceType'] != null) {
              attributes['source_type'] = firstData['sourceType'];
            }
            // 拡張属性（外部GNSS用）
            if (firstData['hdop'] != null) {
              attributes['hdop'] = firstData['hdop'];
            }
            if (firstData['satelliteCount'] != null) {
              attributes['satellite_count'] = firstData['satelliteCount'];
            }
            if (firstData['fixType'] != null) {
              attributes['fix_type'] = firstData['fixType'];
            }
            if (firstData['correctionSource'] != null) {
              attributes['correction_source'] = firstData['correctionSource'];
            }
          }

          // 全NMEAデータを収集して保存（最後のデータから取得）
          if (_longPressGpsData.isNotEmpty) {
            final lastData = _longPressGpsData.last;
            if (lastData['nmea'] != null) {
              attributes['nmea'] = lastData['nmea'];
            }
          }

          attributes['timestamp'] = DateTime.now().toIso8601String();
          attributes['sample_count'] = averagedResult['sampleCount'];

          // 属性値を設定（カラムが存在しない場合は自動作成される）
          if (attributes.isNotEmpty) {
            await pointFeature.setAttributeValues(attributes);
          }

          _ref.read(featureRefreshTriggerProvider.notifier).trigger();

          // Point測量完了後はGPS測量を停止（リソース効率化）
          await _gpsManager.stopGpsSurvey();

          // データ収集タイマーも確実に停止（念のため）
          _gpsCollectionTimer?.cancel();
          _gpsCollectionTimer = null;

          AppLogger.debug(
            '[GpsTool] GPS測量ポイントフィーチャを即座に作成しました（GPS停止済み・タイマー確認済み）',
          );
          return true; // 成功
        } else {
          AppLogger.debug('[ERROR] GPS測量ポイントフィーチャの作成に失敗しました');
          return false; // 失敗
        }
      } else if (selected is LineLayerNode) {
        // GlobalDrawingStateにGPS測量データとして追加
        drawingState.addLinePoint(position, optimizedGpsData);
      } else if (selected is PolygonLayerNode) {
        // GlobalDrawingStateにGPS測量データとして追加
        drawingState.addPolygonPoint(position, optimizedGpsData);
      }

      // クリーンアップ
      _longPressGpsData.clear();
      _longPressStartTime = null;
      _gpsManager.clearContinuousSurveyData();

      return true;
    } catch (e) {
      AppLogger.debug('[GpsTool] 長押しGPS測量エラー: $e');
      return false;
    }
  }

  /// 現在のGPS位置を記録（単発版・互換性維持）
  Future<bool> recordCurrentGpsPosition() async {
    // 長押し中の場合は何もしない
    if (_isLongPressing) {
      AppLogger.debug('[GpsTool] 長押し中のため単発GPS記録をスキップ');
      return false;
    }

    try {
      // GPS測量専用開始（位置取得まで待機）
      final gpsInfo = await _gpsManager.startGpsSurveyWithWait();
      AppLogger.debug('[GpsTool] 単発測量 gpsInfo: $gpsInfo');

      if (gpsInfo == null || gpsInfo['isActive'] != true) {
        AppLogger.debug('[GpsTool] GPS位置情報が利用できません。位置情報の許可が必要です。');
        return false;
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

      // 1つの点から平均を計算（実質的には同じ値）
      final averagedResult = _calculateAveragedGpsPosition([singleGpsData]);
      AppLogger.debug('[GpsTool] 単発測量 averagedResult: $averagedResult');

      // 長押し測量と同じ最適化された辞書構造を作成
      final optimizedGpsData = _createOptimizedGpsDescription(
        averagedResult,
        [singleGpsData],
        isSingleTap: true, // 通常測量フラグ
      );

      AppLogger.debug('[GpsTool] 単発測量 optimizedGpsData: $optimizedGpsData');

      // 現在選択中のレイヤーに応じてデータを追加
      final selected = _ref.read(selectedLayerNodeProvider);
      if (selected is PointLayerNode) {
        // GPS測量時は即座にPointフィーチャを作成（メタデータなし、個別カラムに保存）
        final pointFeature = await PointFeatureNode.createIn(
          selected,
          position,
          '', // nameは空
          '', // descriptionも空
        );

        if (pointFeature != null) {
          // GPS属性を個別カラムとして設定（拡張版）
          final attributes = <String, dynamic>{};

          // 単発測量の場合はgpsInfoから直接取得
          if (gpsInfo['altitude'] != null) {
            attributes['altitude'] = gpsInfo['altitude'];
          }
          if (gpsInfo['accuracy'] != null) {
            attributes['accuracy'] = gpsInfo['accuracy'];
          }
          if (gpsInfo['speed'] != null) {
            attributes['speed'] = gpsInfo['speed'];
          }
          if (gpsInfo['bearing'] != null) {
            attributes['bearing'] = gpsInfo['bearing'];
          }
          if (gpsInfo['sourceType'] != null) {
            attributes['source_type'] = gpsInfo['sourceType'];
          }
          // 拡張属性（外部GNSS用）
          if (gpsInfo['hdop'] != null) {
            attributes['hdop'] = gpsInfo['hdop'];
          }
          if (gpsInfo['satelliteCount'] != null) {
            attributes['satellite_count'] = gpsInfo['satelliteCount'];
          }
          if (gpsInfo['fixType'] != null) {
            attributes['fix_type'] = gpsInfo['fixType'];
          }
          if (gpsInfo['correctionSource'] != null) {
            attributes['correction_source'] = gpsInfo['correctionSource'];
          }
          if (gpsInfo['nmea'] != null) {
            attributes['nmea'] = gpsInfo['nmea'];
          }

          attributes['timestamp'] = DateTime.now().toIso8601String();
          attributes['sample_count'] = 1; // 単発測量なので1

          // 属性値を設定（カラムが存在しない場合は自動作成される）
          if (attributes.isNotEmpty) {
            await pointFeature.setAttributeValues(attributes);
          }

          _ref.read(featureRefreshTriggerProvider.notifier).trigger();

          // Point測量完了後はGPS測量を停止（リソース効率化）
          await _gpsManager.stopGpsSurvey();

          // データ収集タイマーも確実に停止（念のため）
          _gpsCollectionTimer?.cancel();
          _gpsCollectionTimer = null;

          AppLogger.debug(
            '[GpsTool] GPS測量ポイントフィーチャを即座に作成しました（GPS停止済み・タイマー確認済み）',
          );
          return true; // 成功
        } else {
          AppLogger.debug('[ERROR] GPS測量ポイントフィーチャの作成に失敗しました');
          return false; // 失敗
        }
      } else if (selected is LineLayerNode) {
        // GlobalDrawingStateにGPS測量データとして追加
        drawingState.addLinePoint(position, optimizedGpsData);
      } else if (selected is PolygonLayerNode) {
        // GlobalDrawingStateにGPS測量データとして追加
        drawingState.addPolygonPoint(position, optimizedGpsData);
      }

      AppLogger.debug(
        '[GpsTool] GPS位置を記録: Lat ${latitude.toStringAsFixed(6)}, '
        'Lon ${longitude.toStringAsFixed(6)}, '
        'Accuracy ${(gpsInfo['accuracy'] as num?)?.toStringAsFixed(1) ?? 'N/A'}m',
      );

      return true;
    } catch (e) {
      AppLogger.debug('[GpsTool] GPS位置記録エラー: $e');
      return false;
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
    };

    // AppLogger.debug('[GpsTool] _createOptimizedGpsDescription 結果: $result');
    return result;
  }

  /// 次のポイント番号を取得
  int _getNextPointNumber() {
    final selected = _ref.read(selectedLayerNodeProvider);
    if (selected is LineLayerNode) {
      return surveyLine.length + 1;
    } else if (selected is PolygonLayerNode) {
      return surveyPolygon.length + 1;
    }
    return 1; // PointLayerNode
  }

  /// GPS測量をキャンセル（GPS停止付き）
  Future<void> cancelSurveyWithGpsStop() async {
    _cleanupGpsFeatures();
    await _gpsManager.stopGpsSurvey();
    AppLogger.debug('[GpsTool] GPS測量をキャンセルしてGPS停止しました');
  }

  /// 連続測量位置更新コールバック
  void _onContinuousSurveyUpdate() {
    // GPS Manager Service から収集されたデータを取得してローカルデータと同期
    final continuousData = _gpsManager.getContinuousSurveyData();
    _longPressGpsData.clear();
    _longPressGpsData.addAll(continuousData);

    AppLogger.debug('[GpsTool] 連続測量位置更新 - 現在${_longPressGpsData.length}ポイント');
  }

  /// マウスホイールスクロールイベント（ズーム機能）
  /// PanToolの統一処理を呼び出し
  @override
  void onPointerSignal(PointerEvent event, IMapState mapState) {
    if (event is PointerScrollEvent) {
      _panTool.handleMouseWheelZoom(event, mapState);
    }
  }

  @override
  void onMiddleButtonDown(PointerDownEvent event, IMapState mapState) {
    _panTool.onMiddleButtonDown(event, mapState);
  }

  @override
  void onMiddleButtonMove(PointerMoveEvent event, IMapState mapState) {
    _panTool.onMiddleButtonMove(event, mapState);
  }

  @override
  void onMiddleButtonUp(PointerUpEvent event, IMapState mapState) {
    _panTool.onMiddleButtonUp(event, mapState);
  }
}
