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
/// ライン/ポリゴン簡略化アクション
///
/// Douglas-Peucker 簡略化を適用する FeatureEditAction 実装。
/// LineFeatureNode と PolygonFeatureNode に対応。
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
import '../shared/simplification_controls.dart';
import '../shared/sub_table_helper.dart';

class SimplifyAction extends FeatureEditAction {
  @override
  String get label => t.featureEditor.simplifyLabel;

  @override
  IconData get icon => Icons.timeline;

  @override
  bool canApplyTo(FeatureNode feature) =>
      feature is LineFeatureNode || feature is PolygonFeatureNode;

  @override
  Widget buildControls(
    BuildContext context,
    FeatureNode feature,
    ValueNotifier<PreviewLines> previewLines,
  ) =>
      _SimplifyControls(feature: feature, previewLines: previewLines);
}

class _SimplifyControls extends ConsumerStatefulWidget {
  final FeatureNode feature;
  final ValueNotifier<PreviewLines> previewLines;

  const _SimplifyControls({
    required this.feature,
    required this.previewLines,
  });

  @override
  ConsumerState<_SimplifyControls> createState() => _SimplifyControlsState();
}

class _SimplifyControlsState extends ConsumerState<_SimplifyControls> {
  List<LatLng> _originalLine = [];
  List<LatLng> _simplified = [];
  bool _isApplying = false;
  String? _originalSubTableJson;

  @override
  void initState() {
    super.initState();
    _originalLine = _extractLine(widget.feature);
    _loadSubTable();
    // 初期プレビューを設定（フレーム後に通知）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.previewLines.value = PreviewLines(
        backgroundLine: _originalLine,
        foregroundLine: _originalLine,
      );
    });
  }

  Future<void> _loadSubTable() async {
    _originalSubTableJson = await SubTableHelper.getSubTableJson(
      widget.feature,
    );
  }

  List<LatLng> _extractLine(FeatureNode feature) {
    if (feature is LineFeatureNode) return feature.line;
    if (feature is PolygonFeatureNode) {
      final polygon = feature.polygon;
      return polygon.isNotEmpty ? polygon.first : [];
    }
    return [];
  }

  void _onSimplified(List<LatLng> result) {
    setState(() => _simplified = result);
    widget.previewLines.value = PreviewLines(
      backgroundLine: _originalLine,
      foregroundLine: result,
    );
  }

  Future<void> _apply() async {
    if (_simplified.length < 2) return;
    setState(() => _isApplying = true);

    try {
      bool success = false;
      if (widget.feature is LineFeatureNode) {
        success =
            await (widget.feature as LineFeatureNode).updateLine(_simplified);
      } else if (widget.feature is PolygonFeatureNode) {
        final polygon = (widget.feature as PolygonFeatureNode).polygon;
        final updated = [_simplified, ...polygon.skip(1)];
        success = await (widget.feature as PolygonFeatureNode)
            .updatePolygon(updated);
      }

      if (!success) throw Exception(t.featureEditorActions.geometryUpdateFailed);

      // sub_tableも簡略化後の頂点に合わせてフィルタ
      if (_originalSubTableJson != null) {
        final filteredSubTable =
            SubTableHelper.filterSubTableBySimplification(
          _originalSubTableJson!,
          _originalLine,
          _simplified,
        );
        if (filteredSubTable != null) {
          await SubTableHelper.setSubTableJson(
            widget.feature,
            filteredSubTable,
          );
        }
      }

      AppLogger.debug('[SimplifyAction] 適用完了: ${widget.feature.name}');

      ref.read(featureRefreshTriggerProvider.notifier).trigger();

      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.simplification.applied,
          level: NotificationLevel.success,
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      AppLogger.debug('[SimplifyAction] 適用失敗: $e');
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.simplification.applyFailed(error: '$e'),
          level: NotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_originalLine.length < 2) {
      return Center(child: Text(t.simplification.insufficientData));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SimplificationControls(
          originalLine: _originalLine,
          onChanged: _onSimplified,
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
                  _isApplying || _simplified.length < 2 ? null : _apply,
              child: _isApplying
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(t.featureEditor.apply),
            ),
          ],
        ),
      ],
    );
  }
}
