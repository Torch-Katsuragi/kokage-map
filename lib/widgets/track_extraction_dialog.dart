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
/// GPS軌跡抽出ダイアログ
///
/// GpsHistoryRecorder から日付別のGPS軌跡を読み取り、
/// 時間範囲の切り取り・Douglas-Peucker簡略化・ライン保存を行う。
/// 保存時は抽出範囲のポイント詳細をsub_table JSONとして付与。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/gps_track.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/gps_history_recorder.dart';
import '../utils/app_logger.dart';
import 'feature_editor/shared/line_preview_painter.dart';
import 'feature_editor/shared/simplification_controls.dart';

/// GPS軌跡抽出ダイアログ
class TrackExtractionDialog extends ConsumerStatefulWidget {
  final GpsHistoryRecorder recorder;

  const TrackExtractionDialog({super.key, required this.recorder});

  @override
  ConsumerState<TrackExtractionDialog> createState() => _TrackExtractionDialogState();
}

class _TrackExtractionDialogState extends ConsumerState<TrackExtractionDialog> {
  // 日付選択
  List<String> _availableDates = [];
  String? _selectedDate;

  // 読み込んだポイント
  List<GpsTrackPoint> _allPoints = [];
  List<GpsTrackPoint> _selectedPoints = [];

  // 時間範囲
  RangeValues? _timeRange;
  double _timeMin = 0;
  double _timeMax = 1;

  // 簡略化結果
  List<LatLng> _simplifiedLine = [];

  // ローディング
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadAvailableDates();
  }

  /// 利用可能な日付を読み込み
  Future<void> _loadAvailableDates() async {
    setState(() => _isLoading = true);

    final dates = await widget.recorder.getAvailableDates();
    if (!mounted) return;

    setState(() {
      _availableDates = dates;
      _selectedDate = dates.isNotEmpty ? dates.first : null;
    });

    if (_selectedDate != null) {
      await _loadPointsForDate(_selectedDate!);
    } else {
      setState(() => _isLoading = false);
    }
  }

  /// 特定日付のポイントを読み込み
  Future<void> _loadPointsForDate(String layerName) async {
    setState(() => _isLoading = true);

    final points = await widget.recorder.getPointsForDate(layerName);
    if (!mounted) return;

    setState(() {
      _allPoints = points;
      _isLoading = false;

      if (points.isNotEmpty) {
        _timeMin = 0;
        _timeMax = (points.length - 1).toDouble();
        _timeRange = RangeValues(_timeMin, _timeMax);
        _updateSelection();
      } else {
        _timeRange = null;
        _selectedPoints = [];
        _simplifiedLine = [];
      }
    });
  }

  /// 選択範囲のポイントと簡略化を更新
  void _updateSelection() {
    if (_allPoints.isEmpty || _timeRange == null) return;

    final start = _timeRange!.start.round();
    final end = _timeRange!.end.round();
    _selectedPoints = _allPoints.sublist(
      start.clamp(0, _allPoints.length - 1),
      (end + 1).clamp(0, _allPoints.length),
    );

    setState(() {});
  }

  /// 距離を計算（メートル）
  double _calculateDistance(List<LatLng> points) {
    if (points.length < 2) return 0;
    double total = 0;
    for (int i = 1; i < points.length; i++) {
      total += _haversineDistance(points[i - 1], points[i]);
    }
    return total;
  }

  double _haversineDistance(LatLng p1, LatLng p2) {
    const R = 6371000.0;
    final dLat = (p2.latitude - p1.latitude) * math.pi / 180;
    final dLon = (p2.longitude - p1.longitude) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(p1.latitude * math.pi / 180) *
            math.cos(p2.latitude * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// 時間を表示用にフォーマット
  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  /// 時間差を表示用にフォーマット
  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return t.track.hours(h: '${d.inHours}', m: '${d.inMinutes % 60}');
    } else if (d.inMinutes > 0) {
      return t.track.minutes(m: '${d.inMinutes}', s: '${d.inSeconds % 60}');
    }
    return t.track.secondsOnly(s: '${d.inSeconds}');
  }

  /// 選択ポイントからsub_table JSON文字列を構築
  String _buildSubTableJson() {
    final header = [
      'timestamp', 'latitude', 'longitude',
      'altitude', 'accuracy', 'speed', 'bearing', 'source_type',
    ];
    final rows = <List<dynamic>>[header];
    for (final pt in _selectedPoints) {
      rows.add([
        pt.timestamp.toIso8601String(),
        pt.latitude,
        pt.longitude,
        pt.altitude,
        pt.accuracy,
        pt.speed,
        pt.bearing,
        pt.sourceType,
      ]);
    }
    return jsonEncode(rows);
  }

  /// 保存処理
  Future<void> _saveTrack() async {
    if (_simplifiedLine.length < 2) return;

    // ラインレイヤ選択ダイアログ
    final lineLayer = await _selectLineLayer();
    if (lineLayer == null || !mounted) return;

    setState(() => _isSaving = true);

    try {
      final dateLabel =
          GpsHistoryRecorder.formatLayerNameAsDate(_selectedDate ?? '');

      final feature = await LineFeatureNode.createIn(
        lineLayer,
        _simplifiedLine,
        t.track.trackLabel(date: dateLabel),
        t.track.trackDesc(total: '${_selectedPoints.length}', simplified: '${_simplifiedLine.length}'),
      );

      // sub_table JSON をフィーチャに付与
      if (feature != null && _selectedPoints.isNotEmpty) {
        try {
          await lineLayer.geoPackageFile.addAttributeColumn(
            lineLayer.layerName,
            'sub_table',
            'TEXT',
          );
        } catch (_) {
          // カラムが既に存在する場合は無視
        }

        final subTableJson = _buildSubTableJson();
        await feature.setAttributeValue('sub_table', subTableJson);
        await feature.flushChanges();
      }

      if (feature != null && mounted) {
        Navigator.of(context).pop(true);
      } else if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.track.saveFailed,
          level: NotificationLevel.error,
        );
      }
    } catch (e) {
      AppLogger.debug('[TrackExtractionDialog] 保存エラー: $e');
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.track.saveError(error: '$e'),
          level: NotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// ラインレイヤ選択ダイアログ
  Future<LineLayerNode?> _selectLineLayer() async {
    final rootNode = ref.read(folderTreeProvider);
    if (rootNode == null) return null;

    // ラインレイヤを検索
    final lineLayers = <LineLayerNode>[];
    void searchLineLayers(LayerTreeNode node) {
      if (node is LineLayerNode) {
        lineLayers.add(node);
      }
      if (node is! FeatureNode) {
        for (final child in node.children) {
          searchLineLayers(child);
        }
      }
    }
    searchLineLayers(rootNode);

    if (lineLayers.isEmpty) {
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.track.noLineLayer,
          level: NotificationLevel.warning,
        );
      }
      return null;
    }

    return showDialog<LineLayerNode>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.track.selectLineLayer),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: lineLayers.length,
            itemBuilder: (context, index) {
              final layer = lineLayers[index];
              return ListTile(
                leading: const Icon(Icons.timeline, color: Colors.blue),
                title: Text(layer.name),
                subtitle: Text(layer.parent?.name ?? ''),
                onTap: () => Navigator.of(context).pop(layer),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: Text(t.common.cancel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 650,
        height: 600,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // タイトル
            Text(
              t.track.extractTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            // 日付選択
            Row(
              children: [
                Text(t.track.dateLabel),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    value: _selectedDate,
                    isExpanded: true,
                    items: _availableDates.map((date) {
                      return DropdownMenuItem(
                        value: date,
                        child: Text(GpsHistoryRecorder.formatLayerNameAsDate(date)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        _selectedDate = value;
                        _loadPointsForDate(value);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  t.track.pointsCount(count: '${_allPoints.length}'),
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // ローディング中
            if (_isLoading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            // データなし
            else if (_allPoints.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    t.track.noTrackData,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              )
            // メインUI
            else ...[
              // 時間範囲スライダー
              if (_timeRange != null) ...[
                Row(
                  children: [
                    Text(
                      t.track.startLabel(time: _formatTime(_allPoints[_timeRange!.start.round().clamp(0, _allPoints.length - 1)].timestamp)),
                      style: const TextStyle(fontSize: 12),
                    ),
                    const Spacer(),
                    Text(
                      t.track.endLabel(time: _formatTime(_allPoints[_timeRange!.end.round().clamp(0, _allPoints.length - 1)].timestamp)),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                RangeSlider(
                  values: _timeRange!,
                  min: _timeMin,
                  max: _timeMax,
                  divisions: _allPoints.length > 1 ? _allPoints.length - 1 : 1,
                  onChanged: (values) {
                    setState(() {
                      _timeRange = values;
                    });
                  },
                  onChangeEnd: (values) {
                    _updateSelection();
                  },
                ),
              ],

              // プレビュー
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CustomPaint(
                      painter: LinePreviewPainter(
                        backgroundLine: _allPoints.map((p) => p.toLatLng()).toList(),
                        foregroundLine: _simplifiedLine,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // GPS固有の統計情報
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.track.selectionRange(selected: '${_selectedPoints.length}', total: '${_allPoints.length}'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (_selectedPoints.length >= 2)
                          Expanded(
                            child: Text(
                              t.track.duration(value: _formatDuration(_selectedPoints.last.timestamp.difference(_selectedPoints.first.timestamp))),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                    if (_selectedPoints.length >= 2)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t.track.distance(value: (_calculateDistance(_selectedPoints.map((p) => p.toLatLng()).toList()) / 1000).toStringAsFixed(2)),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // 簡略化コントロール（共通ウィジェット）
              SimplificationControls(
                originalLine: _selectedPoints.map((p) => p.toLatLng()).toList(),
                initialTolerance: 5.0,
                onChanged: (simplified) =>
                    setState(() => _simplifiedLine = simplified),
              ),

              const SizedBox(height: 4),

              // 凡例
              Row(
                children: [
                  Container(width: 16, height: 2, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text(t.track.allTrack, style: const TextStyle(fontSize: 11)),
                  const SizedBox(width: 16),
                  Container(width: 16, height: 2, color: Colors.black),
                  const SizedBox(width: 4),
                  Text(t.track.selectedRange, style: const TextStyle(fontSize: 11)),
                  const SizedBox(width: 16),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(t.track.vertices, style: const TextStyle(fontSize: 11)),
                ],
              ),
            ],

            const SizedBox(height: 12),

            // ボタン
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: Text(t.common.cancel),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _isSaving || _simplifiedLine.length < 2
                      ? null
                      : _saveTrack,
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(t.track.saveToLayer),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

