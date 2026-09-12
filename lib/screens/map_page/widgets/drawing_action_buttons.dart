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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../models/nodes/feature_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/tool_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../tools/gps_tool.dart';
import '../../../tools/pen_tool.dart';
import '../../../utils/global_drawing_state.dart';

/// 描画・測量操作用のFABボタン群
class DrawingActionButtons extends ConsumerWidget {
  final VoidCallback onConfirmDrawing;
  final VoidCallback onConfirmGpsSurvey;
  final VoidCallback onTriggerSetState;
  final GpsTool? Function() getGpsTool;

  const DrawingActionButtons({
    super.key,
    required this.onConfirmDrawing,
    required this.onConfirmGpsSurvey,
    required this.onTriggerSetState,
    required this.getGpsTool,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedLayerNodeProvider);
    final currentTool = ref.watch(currentToolProvider);
    final drawingState = GlobalDrawingState.instance;
    final gpsTool = currentTool is GpsTool ? currentTool : null;

    // 消しゴム: 集めた候補（＝選択）を確定するまで消さない
    final eraserCandidates =
        currentTool is PenTool && ref.watch(isFabActiveProvider)
            ? ref.watch(selectedFeaturesProvider).whereType<FeatureNode>().length
            : 0;

    final isGpsSurveyLine =
        selected is LineLayerNode &&
        gpsTool != null &&
        gpsTool.surveyLine.isNotEmpty;
    final isGpsSurveyPolygon =
        selected is PolygonLayerNode &&
        gpsTool != null &&
        gpsTool.surveyPolygon.isNotEmpty;

    final isLineDrawing =
        selected is LineLayerNode &&
        currentTool is PenTool &&
        drawingState.drawingLine.isNotEmpty;
    final isPolygonDrawing =
        selected is PolygonLayerNode &&
        currentTool is PenTool &&
        drawingState.drawingPolygon.isNotEmpty;

    if (eraserCandidates > 0) {
      return _buildEraserButtons(ref, eraserCandidates);
    } else if (isGpsSurveyLine || isGpsSurveyPolygon) {
      return _buildGpsSurveyButtons(ref, gpsTool, drawingState);
    } else if (isLineDrawing || isPolygonDrawing) {
      return _buildDrawingButtons(drawingState, isLineDrawing);
    }
    return const SizedBox.shrink();
  }

  Widget _buildEraserButtons(WidgetRef ref, int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: 'eraser_cancel',
          onPressed: () => ref.read(selectedFeaturesProvider.notifier).clear(),
          tooltip: t.map.eraser.cancel,
          child: const Icon(Icons.clear),
        ),
        const SizedBox(width: 12),
        FloatingActionButton.extended(
          heroTag: 'eraser_confirm',
          backgroundColor: Colors.red.shade600,
          foregroundColor: Colors.white,
          onPressed: () =>
              ref.read(selectedFeaturesProvider.notifier).disposeSelectedFeatures(),
          icon: const Icon(Icons.delete_outline),
          label: Text(t.map.eraser.confirm(n: count)),
        ),
      ],
    );
  }

  Widget _buildGpsSurveyButtons(
    WidgetRef ref,
    GpsTool gpsTool,
    GlobalDrawingState drawingState,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: 'gps_undo',
          onPressed: () {
            drawingState.undo(isLine: gpsTool.surveyLine.isNotEmpty);
            onTriggerSetState();
          },
          tooltip: t.gps.undoLastPointTooltip,
          child: const Icon(Icons.undo),
        ),
        const SizedBox(width: 12),
        FloatingActionButton(
          heroTag: 'gps_cancel',
          onPressed: () async {
            await gpsTool.cancelSurveyWithGpsStop();
            onTriggerSetState();
            ref
                .read(notificationCenterProvider.notifier)
                .add(
                  title: t.gps.surveyCancelled,
                  level: NotificationLevel.warning,
                );
          },
          tooltip: t.gps.cancelSurveyTooltip,
          child: const Icon(Icons.clear),
        ),
        const SizedBox(width: 12),
        FloatingActionButton.extended(
          heroTag: 'gps_confirm',
          onPressed: onConfirmGpsSurvey,
          icon: const Icon(Icons.check),
          label: Text(t.gps.confirmSurvey),
        ),
      ],
    );
  }

  Widget _buildDrawingButtons(
    GlobalDrawingState drawingState,
    bool isLineDrawing,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: 'undo',
          onPressed: () {
            drawingState.undo(isLine: isLineDrawing);
            onTriggerSetState();
          },
          tooltip: t.map.drawing.undo,
          child: const Icon(Icons.undo),
        ),
        const SizedBox(width: 12),
        FloatingActionButton(
          heroTag: 'cancel',
          onPressed: () {
            drawingState.cancel(isLine: isLineDrawing);
            onTriggerSetState();
          },
          tooltip: t.map.drawing.cancel,
          child: const Icon(Icons.clear),
        ),
        const SizedBox(width: 12),
        FloatingActionButton.extended(
          heroTag: 'confirm',
          onPressed: onConfirmDrawing,
          icon: const Icon(Icons.check),
          label: Text(t.map.drawing.confirm),
        ),
      ],
    );
  }
}
