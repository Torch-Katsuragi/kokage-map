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
/// ライン切り取りアクション
///
/// 頂点インデックスの範囲を指定してラインを切り取る FeatureEditAction 実装。
/// LineFeatureNode のみ対応。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../models/nodes/feature_node.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../utils/app_logger.dart';
import '../feature_edit_action.dart';
import '../shared/sub_table_helper.dart';

class TrimAction extends FeatureEditAction {
  @override
  String get label => t.trim.label;

  @override
  IconData get icon => Icons.content_cut;

  @override
  bool canApplyTo(FeatureNode feature) => feature is LineFeatureNode;

  @override
  Widget buildControls(
    BuildContext context,
    FeatureNode feature,
    ValueNotifier<PreviewLines> previewLines,
  ) =>
      _TrimControls(
        feature: feature as LineFeatureNode,
        previewLines: previewLines,
      );
}

class _TrimControls extends ConsumerStatefulWidget {
  final LineFeatureNode feature;
  final ValueNotifier<PreviewLines> previewLines;

  const _TrimControls({
    required this.feature,
    required this.previewLines,
  });

  @override
  ConsumerState<_TrimControls> createState() => _TrimControlsState();
}

class _TrimControlsState extends ConsumerState<_TrimControls> {
  late List<LatLng> _fullLine;
  late RangeValues _range;
  List<LatLng> _trimmedLine = [];
  bool _isApplying = false;
  String? _originalSubTableJson;

  @override
  void initState() {
    super.initState();
    _fullLine = widget.feature.line;
    _range = RangeValues(0, (_fullLine.length - 1).toDouble());
    _updateTrimmed();
    _loadSubTable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyPreview();
    });
  }

  Future<void> _loadSubTable() async {
    _originalSubTableJson = await SubTableHelper.getSubTableJson(
      widget.feature,
    );
  }

  void _updateTrimmed() {
    final start = _range.start.round();
    final end = _range.end.round();
    _trimmedLine = _fullLine.sublist(
      start.clamp(0, _fullLine.length - 1),
      (end + 1).clamp(0, _fullLine.length),
    );
  }

  void _notifyPreview() {
    widget.previewLines.value = PreviewLines(
      backgroundLine: _fullLine,
      foregroundLine: _trimmedLine,
    );
  }

  Future<void> _apply() async {
    if (_trimmedLine.length < 2) return;
    setState(() => _isApplying = true);

    try {
      final success = await widget.feature.updateLine(_trimmedLine);
      if (!success) throw Exception(t.featureEditorActions.geometryUpdateFailed);

      // sub_tableもトリム範囲に合わせて更新
      if (_originalSubTableJson != null) {
        final start = _range.start.round();
        final end = _range.end.round();
        final trimmedSubTable = SubTableHelper.trimSubTable(
          _originalSubTableJson!,
          start,
          end,
        );
        if (trimmedSubTable != null) {
          await SubTableHelper.setSubTableJson(
            widget.feature,
            trimmedSubTable,
          );
        }
      }

      AppLogger.debug('[TrimAction] 適用完了: ${widget.feature.name}');

      ref.read(featureRefreshTriggerProvider.notifier).trigger();

      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.trim.applied,
          level: NotificationLevel.success,
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      AppLogger.debug('[TrimAction] 適用失敗: $e');
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.trim.applyFailed(error: '$e'),
          level: NotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fullLine.length < 3) {
      return Center(child: Text(t.trim.minPoints));
    }

    final maxIdx = (_fullLine.length - 1).toDouble();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              t.trim.startIndex(value: '${_range.start.round()}'),
              style: const TextStyle(fontSize: 12),
            ),
            const Spacer(),
            Text(
              t.trim.endIndex(value: '${_range.end.round()}'),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        RangeSlider(
          values: _range,
          min: 0,
          max: maxIdx,
          divisions: _fullLine.length > 1 ? _fullLine.length - 1 : 1,
          onChanged: (values) => setState(() => _range = values),
          onChangeEnd: (_) {
            _updateTrimmed();
            _notifyPreview();
            setState(() {});
          },
        ),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            t.trim.result(trimmed: '${_trimmedLine.length}', total: '${_fullLine.length}'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t.common.cancel),
            ),
            const SizedBox(width: 16),
            ElevatedButton(
              onPressed:
                  _isApplying || _trimmedLine.length < 2 ? null : _apply,
              child: _isApplying
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(t.trim.apply),
            ),
          ],
        ),
      ],
    );
  }
}
