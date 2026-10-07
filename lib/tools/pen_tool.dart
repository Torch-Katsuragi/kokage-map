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
// lib/tools/pen_tool.dart
// ペンツール（レイヤ描画）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../i18n/strings.g.dart';
import '../interfaces/map_state_interface.dart';
import '../models/app_notification.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../providers/notification_providers.dart';
import '../providers/selection_providers.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../tutorial/tutorial.dart';
import '../utils/global_drawing_state.dart';
import 'map_tool.dart';
import 'pan_tool.dart';
import 'select_tool.dart';
/// ペンツール（レイヤ描画）
///
/// 描きかけは [GlobalDrawingState] に持たせる（変わると向こうが通知する）
class PenTool extends MapTool with PanDelegation {
  PenTool(this._ref);
  final Ref _ref;

  /// てのひらツールのグローバルインスタンス（2本指パン・回転・ホイール・中ボタン用）
  @override
  PanTool get panTool => _ref.read(panToolProvider);

  /// グローバル描画状態への参照
  GlobalDrawingState get drawingState => GlobalDrawingState.instance;

  @override
  String get name => 'Pen';

  @override
  IconData get icon => Icons.edit;

  bool _isDrawing = false;
  int _pointerCount = 0;

  /// 指を置いてから 1 本指のドラッグと分かるまでの軌跡（描き始めを取りこぼさないため）
  final List<Offset> _pointerBuffer = [];

  @override
  void addPointerToBuffer(Offset offset) => _pointerBuffer.add(offset);

  @override
  void clearPointerBuffer() => _pointerBuffer.clear();

  void _warn(String title) =>
      _ref.read(notificationCenterProvider.notifier).add(title: title, level: NotificationLevel.warning);

  /// 描き込み先: 選択中のレイヤが見えていればそれ。見えていなければ null（[warn] なら知らせる）
  LayerNode? _targetLayer({bool warn = false}) {
    final selected = _ref.read(selectedLayerNodeProvider);
    if (selected == null) return null;
    if (!selected.isVisibleRecursive()) {
      if (warn) _warn(t.editor.layerInvisible);
      return null;
    }
    return selected;
  }

  /// 線のレイヤなら true、面なら false、点は null（[GlobalDrawingState] の `isLine`）
  static bool? _isLine(LayerNode layer) => switch (layer) {
        LineLayerNode() => true,
        PolygonLayerNode() => false,
        _ => null,
      };

  /// 地物を作り終えたら地図に出す
  static void _showWhenCreated(Future<Object?> created, IMapState mapState, [VoidCallback? then]) {
    created.then((_) {
      mapState.refreshFeatures();
      then?.call();
    });
  }

  /// タップイベント
  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    // フロートボタン押下時は消しゴム動作: タップで候補の出し入れ
    if (_ref.read(isFabActiveProvider)) {
      if (_ref.read(selectedLayerNodeProvider) == null) {
        _warn(t.editor.noLayerSelected);
        return;
      }
      final hit = _eraserTarget(mapState.offsetToLatLng(details.localPosition), mapState);
      if (hit != null) _ref.read(selectedFeaturesProvider.notifier).toggle(hit);
      return;
    }

    // 通常は描画: 点はその場で作り、線・面は描きかけに足す
    final selected = _targetLayer(warn: true);
    if (selected == null) return;
    final latlng = mapState.offsetToLatLng(details.localPosition);
    if (selected is PointLayerNode) {
      _showWhenCreated(
        PointFeatureNode.createIn(selected, latlng, '', ''),
        mapState,
        () => _ref.read(tutorialProvider.notifier).report(PointPlaced(selected)),
      );
      return;
    }
    final isLine = _isLine(selected);
    if (isLine != null) drawingState.addPoint(latlng, null, isLine: isLine);
  }

  /// スケール開始イベント
  /// 1本指: ペン描画, 2本指: パンツール処理
  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {
    // 中ボタンドラッグ中は何もしない（意図しない描画を防ぐ）
    if (panTool.isMiddleButtonDragging) return;

    if (_pointerCount == 2) {
      //2本指を離すとき高確率で残った方の指でdetails.pointerCount=1としてonscalestartが呼ばれるので、その場合は一回スキップ(0にするとupdateとendで何もしなくなる)
      _pointerCount = 0;
      return;
    }
    _pointerCount = details.pointerCount;

    // 2本指の場合は、選択レイヤーに関係なくパン操作を許可
    if (_pointerCount == 2) {
      panTool.onScaleStart(details, mapState);
      return;
    }

    // 1本指の場合のみレイヤー選択チェック
    final selected = _targetLayer(warn: true);
    if (selected == null || _pointerCount != 1 || _ref.read(isFabActiveProvider)) return;

    final isLine = _isLine(selected);
    // 指を置いてからの軌跡があれば、描きかけをそれで置き換える
    if (_pointerBuffer.isNotEmpty) {
      if (isLine != null) {
        drawingState.clear(isLine: isLine);
        for (final offset in _pointerBuffer) {
          drawingState.addPoint(mapState.offsetToLatLng(offset), null, isLine: isLine);
        }
      }
      _pointerBuffer.clear();
    }
    final latlng = mapState.offsetToLatLng(details.localFocalPoint);
    if (selected is PointLayerNode) {
      drawingState.setPointPreview(latlng);
    } else if (isLine != null) {
      final empty = isLine ? !drawingState.isLineDrawing : !drawingState.isPolygonDrawing;
      if (empty) drawingState.addPoint(latlng, null, isLine: isLine);
      _isDrawing = true;
    }
  }

  /// スケール更新イベント
  /// 1本指: ペン描画, 2本指: パンツール処理
  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {
    // 中ボタンドラッグ中は何もしない（意図しない描画を防ぐ）
    if (panTool.isMiddleButtonDragging) return;

    // 2本指の場合は、選択レイヤーに関係なくパン操作を許可
    if (_pointerCount == 2) {
      panTool.onScaleUpdate(details, mapState);
      // 2本指終了時に1本指状態で呼ばれるので、_pointercount=2のままにしておく(スキップフラグとして利用)
      return;
    }

    // 1本指の場合のみレイヤー選択チェック
    final selected = _targetLayer();
    if (selected == null || _pointerCount != 1) return;
    final latlng = mapState.offsetToLatLng(details.localFocalPoint);

    // フロートボタン押下時は消しゴム動作: ドラッグ軌跡に触れたものを候補に足す。
    // ⚠ ここでは消さない。候補は選択として光らせ、右下の「削除」で確定する
    //   （線をタップで描くときと同じ、集めてから確定の流れ）
    if (_ref.read(isFabActiveProvider)) {
      final hit = _eraserTarget(latlng, mapState);
      if (hit != null && !_ref.read(selectedFeaturesProvider).contains(hit)) {
        _ref.read(selectedFeaturesProvider.notifier).add(hit);
      }
      return;
    }

    if (selected is PointLayerNode) {
      drawingState.setPointPreview(latlng);
      return;
    }
    final isLine = _isLine(selected);
    if (isLine != null && _isDrawing) drawingState.addPoint(latlng, null, isLine: isLine);
  }

  /// スケール終了イベント
  /// 1本指: 描いた点・線・面をその場で作る, 2本指: パンツール処理
  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) {
    // 中ボタンドラッグ中は何もしない（意図しない描画を防ぐ）
    if (panTool.isMiddleButtonDragging) return;

    // 2本指の場合は、選択レイヤーに関係なくパン操作を許可
    if (_pointerCount == 2) {
      panTool.onScaleEnd(details, mapState);
      return;
    }

    // 1本指の場合のみレイヤー選択チェック
    final selected = _targetLayer();
    if (selected == null) return;
    if (_pointerCount == 1) {
      final preview = drawingState.pointPreview;
      final line = drawingState.drawingLine;
      final polygon = drawingState.drawingPolygon;
      if (selected is PointLayerNode && preview != null) {
        _showWhenCreated(PointFeatureNode.createIn(selected, preview, 'FreeHandPoint', ''), mapState);
        drawingState.setPointPreview(null);
      } else if (selected is LineLayerNode && line.length >= 2) {
        _showWhenCreated(LineFeatureNode.createIn(selected, List<LatLng>.from(line), 'FreeHandLine', ''), mapState);
        drawingState.clear(isLine: true);
      } else if (selected is PolygonLayerNode && polygon.length >= 3) {
        _showWhenCreated(
          PolygonFeatureNode.createIn(selected, [mapState.closeRing(polygon)], 'FreeHandPolygon', ''),
          mapState,
        );
        drawingState.clear(isLine: false);
        _isDrawing = false;
      }
    }
    _pointerCount = 0;
  }

  /// 消しゴムの当たり判定。選択ツールと同じ半径・同じ優先順位だが、
  /// 対象は**選択中レイヤのフィーチャだけ**（ペンで描く先と同じ）。
  /// 写真・オーバーレイ・現在位置は消さない
  FeatureNode? _eraserTarget(LatLng latlng, IMapState mapState) {
    final layer = _ref.read(selectedLayerNodeProvider);
    if (layer == null) return null;
    return SelectTool.candidatesAt(latlng, mapState)
        .whereType<FeatureNode>()
        .where((f) => f.parent == layer)
        .firstOrNull;
  }
}
