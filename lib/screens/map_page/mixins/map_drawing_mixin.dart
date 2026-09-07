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
// Root Maps: 描画確定Mixin
// ペンツールでの描画確定と追記モード関連の機能を提供
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/nodes/feature_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/tool_providers.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/global_drawing_state.dart';
import '../map_page_state_base.dart';

/// 描画確定Mixin
/// ペンツールでの描画確定と追記モード機能を提供
mixin MapDrawingMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  
  // =============================================
  // 描画確定処理
  // =============================================
  
  /// ライン/ポリゴン確定処理
  Future<void> onConfirmDrawing() async {
    final selected = ref.read(selectedLayerNodeProvider);
    if (selected == null) return;
    
    final drawingState = GlobalDrawingState.instance;
    
    // 描画データがあるかチェック
    if (!drawingState.isDrawing) {
      AppLogger.debug('[MAP] 確定処理: 描画データがありません');
      return;
    }
    
    // 属性入力ダイアログを表示
    final String? name = await showDialog<String>(
      context: context,
      builder: (context) {
        String text = '';
        return AlertDialog(
          title: const Text('Attribute Input'),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Attribute (Text)'),
            onChanged: (v) => text = v,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, text),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    if (name == null) return;
    
    // GlobalDrawingStateの統一確定処理を使用
    final success = await drawingState.confirmCurrentFeature(
      layerNode: selected,
      name: name.isNotEmpty ? name : t.editor.newFeature,
      description: '',
      closeRing: closeRing,
      refreshCallback: refreshMapUI,
    );
    
    if (success) {
      AppLogger.debug('[MAP] フィーチャ確定成功: $name');
    } else {
      AppLogger.debug('[MAP] フィーチャ確定失敗: $name');
    }
  }
  
  // =============================================
  // 追記モード
  // =============================================
  
  /// 追記モード開始処理
  /// [feature] - 追記対象のFeatureNode
  void startAppendMode(FeatureNode feature) {
    AppLogger.debug('[MAP] 追記モード開始: ${feature.name} (${feature.runtimeType})');
    
    // 1. ツールをPenToolに切り替え
    ref.read(currentToolProvider.notifier).set(ref.read(penToolProvider));
    
    // 2. 選択レイヤーを該当フィーチャのレイヤーに設定
    LayerNode? targetLayer;
    if (feature is LineFeatureNode) {
      targetLayer = feature.parent as LayerNode?;
    } else if (feature is PolygonFeatureNode) {
      targetLayer = feature.parent as LayerNode?;
    }
    
    if (targetLayer != null) {
      ref.read(selectedLayerNodeProvider.notifier).select(targetLayer);
      AppLogger.debug('[MAP] 選択レイヤーを設定: ${targetLayer.name}');
    }
    
    // 3. UI状態を更新
    triggerSetState(() {});
    
    AppLogger.debug('[MAP] 追記モード開始完了');
  }
  
  // =============================================
  // 抽象メソッド（サブクラスで実装）
  // =============================================
  
  /// マップUIを更新
  void refreshMapUI();
}

