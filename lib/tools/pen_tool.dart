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
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

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
class PenTool extends MapTool {
  final Ref _ref;
  PenTool(this._ref);

  /// てのひらツールのグローバルインスタンス（2本指パン・回転用）
  PanTool get panTool => _ref.read(panToolProvider);

  /// グローバル描画状態への参照
  GlobalDrawingState get drawingState => GlobalDrawingState.instance;

  @override
  String get name => 'Pen';

  @override
  IconData get icon => Icons.edit;

  bool _isDrawing = false;
  int _pointerCount = 0;

  /// プレビュー用の点座標（外部参照用getter）
  /// グローバル描画状態から取得
  LatLng? get pointPreview => drawingState.pointPreview;

  /// 線の描画点列（グローバル描画状態から取得）
  List<LatLng> get drawingLine => drawingState.drawingLine;

  /// ポリゴンの描画点列（グローバル描画状態から取得）
  List<LatLng> get drawingPolygon => drawingState.drawingPolygon;

  /// タップイベント
  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    AppLogger.debug('[DEBUG] PenTool.onTap: タップイベント開始');

    // フロートボタン押下時は消しゴム動作: タップで候補の出し入れ
    if (_ref.read(isFabActiveProvider)) {
      if (_ref.read(selectedLayerNodeProvider) == null) {
        _ref.read(notificationCenterProvider.notifier).add(
          title: t.editor.noLayerSelected,
          level: NotificationLevel.warning,
        );
        return;
      }
      final latlng = mapState.offsetToLatLng(details.localPosition);
      final hit = _eraserTarget(latlng, mapState);
      if (hit != null) {
        _ref.read(selectedFeaturesProvider.notifier).toggle(hit);
        _ref.read(featureRefreshTriggerProvider.notifier).trigger();
      }
      return;
    }

    // 通常は描画
    final selected = _ref.read(selectedLayerNodeProvider);
    if (selected == null) {
      AppLogger.debug('[DEBUG] PenTool.onTap: 選択されたレイヤーがありません');
      return;
    }

    if (!selected.isVisibleRecursive()) {
      AppLogger.debug('[DEBUG] PenTool.onTap: レイヤーが不可視のため処理中止');
      _ref.read(notificationCenterProvider.notifier).add(
        title: t.editor.layerInvisible,
        level: NotificationLevel.warning,
      );
      return;
    }

    final latlng = mapState.offsetToLatLng(details.localPosition);
    AppLogger.debug('[DEBUG] PenTool.onTap: 座標取得完了 $latlng');

    if (selected is PointLayerNode) {
      AppLogger.debug('[DEBUG] PenTool.onTap: ポイントレイヤー処理');
      PointFeatureNode.createIn(selected, latlng, '', '').then((_) {
        // フィーチャー作成完了後にUI更新
        mapState.refreshFeatures();
        _ref.read(tutorialProvider.notifier).report(PointPlaced(selected));
      });
    } else if (selected is LineLayerNode) {
      AppLogger.debug('[DEBUG] PenTool.onTap: ラインレイヤー処理');

      drawingState.addPoint(latlng, null, isLine: true);
    } else if (selected is PolygonLayerNode) {
      AppLogger.debug(
        '[DEBUG] PenTool.onTap: ポリゴンレイヤー処理開始 - 現在の点数: ${drawingPolygon.length}',
      );

      // タップ時のポリゴン描画
      try {
        drawingState.addPoint(latlng, null, isLine: false);

        AppLogger.debug(
          '[DEBUG] PenTool.onTap: ポリゴン点追加完了 - 新しい点数: ${drawingPolygon.length}',
        );
      } catch (e) {
        AppLogger.debug('[ERROR] PenTool.onTap: ポリゴン点追加エラー: $e');
      }
    }

    AppLogger.debug('[DEBUG] PenTool.onTap: タップイベント完了');
  }

  /// スケール開始イベント
  /// 1本指: ペン描画, 2本指: パンツール処理
  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {
    // 中ボタンドラッグ中は何もしない（意図しない描画を防ぐ）
    if (panTool.isMiddleButtonDragging) return;

    final selected = _ref.read(selectedLayerNodeProvider);

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
    if (selected == null || !selected.isVisibleRecursive()) {
      if (selected != null && !selected.isVisibleRecursive()) {
        _ref.read(notificationCenterProvider.notifier).add(
          title: t.editor.layerInvisible,
          level: NotificationLevel.warning,
        );
      }
      return;
    }
    if (_pointerCount == 1) {
      if (_ref.read(isFabActiveProvider)) {
        return;
      }
      // Pointerバッファがあれば最初に反映
      if (pointerBuffer.isNotEmpty) {
        if (selected is LineLayerNode) {
          drawingState.clear(isLine: true);
          for (final offset in pointerBuffer) {
            final latlng = mapState.offsetToLatLng(offset);
            drawingState.addPoint(latlng, null, isLine: true);
          }
        } else if (selected is PolygonLayerNode) {
          drawingState.clear(isLine: false);
          for (final offset in pointerBuffer) {
            final latlng = mapState.offsetToLatLng(offset);
            drawingState.addPoint(latlng, null, isLine: false);
          }
        }
        clearPointerBuffer();
      }
      final latlng = mapState.offsetToLatLng(details.localFocalPoint);
      if (selected is PointLayerNode) {
        drawingState.setPointPreview(latlng);
      } else if (selected is LineLayerNode) {
        if (drawingLine.isEmpty) {
          drawingState.addPoint(latlng, null, isLine: true);
        }
        _isDrawing = true;
      } else if (selected is PolygonLayerNode) {
        if (drawingPolygon.isEmpty) {
          drawingState.addPoint(latlng, null, isLine: false);
        }
        _isDrawing = true;
      }
    }
  }

  /// スケール更新イベント
  /// 1本指: ペン描画, 2本指: パンツール処理
  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {
    // 中ボタンドラッグ中は何もしない（意図しない描画を防ぐ）
    if (panTool.isMiddleButtonDragging) return;

    final selected = _ref.read(selectedLayerNodeProvider);

    // 2本指の場合は、選択レイヤーに関係なくパン操作を許可
    if (_pointerCount == 2) {
      panTool.onScaleUpdate(details, mapState);
      // 2本指終了時に1本指状態で呼ばれるので、_pointercount=2のままにしておく(スキップフラグとして利用)
      return;
    }

    // 1本指の場合のみレイヤー選択チェック
    if (selected == null || !selected.isVisibleRecursive()) return;
    if (_pointerCount == 1) {
      // フロートボタン押下時は消しゴム動作: ドラッグ軌跡に触れたものを候補に足す。
      // ⚠ ここでは消さない。候補は選択として光らせ、右下の「削除」で確定する
      //   （線をタップで描くときと同じ、集めてから確定の流れ）
      if (_ref.read(isFabActiveProvider)) {
        final latlng = mapState.offsetToLatLng(details.localFocalPoint);
        final hit = _eraserTarget(latlng, mapState);
        if (hit != null && !_ref.read(selectedFeaturesProvider).contains(hit)) {
          _ref.read(selectedFeaturesProvider.notifier).add(hit);
          _ref.read(featureRefreshTriggerProvider.notifier).trigger();
        }
        return;
      }
      final latlng = mapState.offsetToLatLng(details.localFocalPoint);
      if (selected is PointLayerNode) {
        drawingState.setPointPreview(latlng);
      } else if (selected is LineLayerNode && _isDrawing) {
        drawingState.addPoint(latlng, null, isLine: true);
      } else if (selected is PolygonLayerNode && _isDrawing) {
        drawingState.addPoint(latlng, null, isLine: false);
      }
    }
  }

  /// スケール終了イベント
  /// 1本指: ペン描画, 2本指: パンツール処理
  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) {
    // 中ボタンドラッグ中は何もしない（意図しない描画を防ぐ）
    if (panTool.isMiddleButtonDragging) return;

    final selected = _ref.read(selectedLayerNodeProvider);

    // 2本指の場合は、選択レイヤーに関係なくパン操作を許可
    if (_pointerCount == 2) {
      panTool.onScaleEnd(details, mapState);
      // _pointerCount = 0;
      return;
    }

    // 1本指の場合のみレイヤー選択チェック
    if (selected == null || !selected.isVisibleRecursive()) return;
    if (_pointerCount == 1) {
      if (selected is PointLayerNode && pointPreview != null) {
        PointFeatureNode.createIn(
          selected,
          pointPreview!,
          'FreeHandPoint',
          '',
        ).then((_) {
          mapState.refreshFeatures();
        });
        drawingState.setPointPreview(null);
      } else if (selected is LineLayerNode && drawingLine.length >= 2) {
        LineFeatureNode.createIn(
          selected,
          List<LatLng>.from(drawingLine),
          'FreeHandLine',
          '',
        ).then((_) {
          mapState.refreshFeatures();
        });
        drawingState.clear(isLine: true);
      } else if (selected is PolygonLayerNode && drawingPolygon.length >= 3) {
        final closed = mapState.closeRing(drawingPolygon);
        PolygonFeatureNode.createIn(
          selected,
          List<List<LatLng>>.from([closed]),
          'FreeHandPolygon',
          '',
        ).then((_) {
          mapState.refreshFeatures();
        });
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
    final candidates = SelectTool.candidatesAt(
      latlng,
      mapState,
      SelectTool.selectRangeFor(mapState),
    );
    return candidates
        .whereType<FeatureNode>()
        .where((f) => f.parent == layer)
        .firstOrNull;
  }

  /// マウスホイールスクロールイベント（ズーム機能）
  /// PanToolの統一処理を呼び出し
  @override
  void onPointerSignal(PointerEvent event, IMapState mapState) {
    if (event is PointerScrollEvent) {
      panTool.handleMouseWheelZoom(event, mapState);
    }
  }

  @override
  void onMiddleButtonDown(PointerDownEvent event, IMapState mapState) {
    panTool.onMiddleButtonDown(event, mapState);
  }

  @override
  void onMiddleButtonMove(PointerMoveEvent event, IMapState mapState) {
    panTool.onMiddleButtonMove(event, mapState);
  }

  @override
  void onMiddleButtonUp(PointerUpEvent event, IMapState mapState) {
    panTool.onMiddleButtonUp(event, mapState);
  }
}
