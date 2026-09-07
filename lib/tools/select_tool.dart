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
// lib/tools/select_tool.dart
// オブジェクト選択ツール（全レイヤー横断・優先度サイクル選択）
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../interfaces/map_state_interface.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../providers/selection_providers.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../utils/feature_calc_utils.dart';
import 'map_tool.dart';

/// オブジェクト選択ツール
class SelectTool extends MapTool {
  final Ref _ref;
  SelectTool(this._ref);
  @override
  String get name => 'Select';

  @override
  IconData get icon => Icons.select_all;

  int _pointerCount = 0;
  List<Offset> _lassoPoints = [];
  List<Offset> get lassoPoints => _lassoPoints;

  static double _calcSelectRange(IMapState mapState) {
    try {
      final mapController = mapState.mapController;
      final zoom = mapController.camera.zoom;
      const double base = 20.0;
      final range = base * math.pow(2, 16 - zoom);
      return range;
    } catch (e) {
      return 30.0;
    }
  }

  /// タップ位置の選択半径 [m]（ズームに応じて画面上でほぼ一定になる）
  static double selectRangeFor(IMapState mapState) => _calcSelectRange(mapState);

  /// 全可視レイヤー+ImageNodeからタップ範囲内の候補を優先度順にリストアップ
  /// 優先度: 0=Point+Image, 1=Line, 2=Polygon（同グループ内は距離順）
  ///
  /// 消しゴム（PenTool）も同じ当たり判定を使う
  static List<LayerTreeNode> candidatesAt(
    LatLng tapLatLng,
    IMapState mapState,
    double selectRange,
  ) =>
      _buildCandidates(tapLatLng, mapState, selectRange);

  static List<LayerTreeNode> _buildCandidates(
    LatLng tapLatLng,
    IMapState mapState,
    double selectRange,
  ) {
    final candidates = <({int priority, double distance, LayerTreeNode node})>[];

    for (final f in mapState.pointFeatures) {
      if (f.isDisposed) continue;
      final d = FeatureSearch.calcPointToFeatureDistance(
        tapLatLng, f.geometry, 'point',
      );
      if (d <= selectRange) {
        candidates.add((priority: 0, distance: d, node: f));
      }
    }

    for (final photo in mapState.photoNodes) {
      if (!photo.hasLocation) continue;
      final d = GeometryCalc.calcDistance(tapLatLng, photo.location!);
      if (d <= selectRange) {
        candidates.add((priority: 0, distance: d, node: photo));
      }
    }

    // オーバーレイ画像: 矩形領域内のタップ判定
    for (final overlay in mapState.overlayImageNodes) {
      final corners = overlay.cornerCoordinates;
      // 4頂点のリングで簡易ポイントインポリゴン判定
      final ring = [...corners, corners[0]];
      if (GeometryCalc.pointInPolygonWithHoles(tapLatLng, [ring])) {
        final d = GeometryCalc.calcDistance(tapLatLng, overlay.location!);
        candidates.add((priority: 0, distance: d, node: overlay));
      }
    }

    for (final f in mapState.lineFeatures) {
      if (f.isDisposed) continue;
      final d = FeatureSearch.calcPointToFeatureDistance(
        tapLatLng, f.geometry, 'line',
      );
      if (d <= selectRange) {
        candidates.add((priority: 1, distance: d, node: f));
      }
    }

    for (final f in mapState.polygonFeatures) {
      if (f.isDisposed) continue;
      final d = FeatureSearch.calcPointToFeatureDistance(
        tapLatLng, f.geometry, 'polygon',
      );
      if (d <= selectRange) {
        candidates.add((priority: 2, distance: d, node: f));
      }
    }

    candidates.sort((a, b) {
      final cmp = a.priority.compareTo(b.priority);
      return cmp != 0 ? cmp : a.distance.compareTo(b.distance);
    });

    return candidates.map((c) => c.node).toList();
  }

  /// 選択を実行し、FeatureNodeならselectedLayerNodeも更新
  void _applySelection(LayerTreeNode? node) {
    if (node != null) {
      _ref.read(selectedFeaturesProvider.notifier).set([node]);
      if (node is FeatureNode) {
        _ref.read(selectedLayerNodeProvider.notifier).select(node.parent);
      }
    } else {
      _ref.read(selectedFeaturesProvider.notifier).set([]);
    }
    _ref.read(featureRefreshTriggerProvider.notifier).trigger();
  }

  /// タップイベント（全レイヤー横断・優先度サイクル選択）
  @override
  void onTap(TapUpDetails details, IMapState mapState) {
    LatLng? tapLatLng;
    try {
      tapLatLng = mapState.offsetToLatLng(details.localPosition);
    } catch (e) {
      return;
    }

    final selectRange = _calcSelectRange(mapState);
    final candidates = _buildCandidates(tapLatLng, mapState, selectRange);

    // 左下ボタンが有効なら複数選択モード: レイヤをまたいで足し引きする
    if (_ref.read(isFabActiveProvider)) {
      if (candidates.isEmpty) return;
      final node = candidates.first;
      _ref.read(selectedFeaturesProvider.notifier).toggle(node);
      if (node is FeatureNode) {
        _ref.read(selectedLayerNodeProvider.notifier).select(node.parent);
      }
      _ref.read(featureRefreshTriggerProvider.notifier).trigger();
      return;
    }

    if (candidates.isEmpty) {
      _applySelection(null);
      return;
    }

    final current = _ref.read(selectedFeaturesProvider);
    final currentSel = current.isNotEmpty ? current.first : null;

    if (currentSel == null) {
      _applySelection(candidates.first);
      return;
    }

    final idx = candidates.indexOf(currentSel);
    if (idx < 0) {
      // 現在の選択が候補にない → 先頭を選択
      _applySelection(candidates.first);
    } else if (idx + 1 < candidates.length) {
      // 次の候補へサイクル
      _applySelection(candidates[idx + 1]);
    } else {
      // 末尾を超えた → 選択クリア
      _applySelection(null);
    }
  }

  /// スケール開始イベント
  /// 1本指: 投げ縄選択, 2本指: パン
  @override
  void onScaleStart(ScaleStartDetails details, IMapState mapState) {
    if (_ref.read(panToolProvider).isMiddleButtonDragging) return;
    _pointerCount = details.pointerCount;
    if (_pointerCount == 2) {
      _ref.read(panToolProvider).onScaleStart(details, mapState);
      return;
    }
    if (_pointerCount == 1) {
      _lassoPoints = [details.localFocalPoint];
      mapState.setState(() {});
    }
  }

  /// スケール更新イベント
  /// 1本指: 投げ縄選択, 2本指: パン
  @override
  void onScaleUpdate(ScaleUpdateDetails details, IMapState mapState) {
    if (_ref.read(panToolProvider).isMiddleButtonDragging) return;
    if (_pointerCount == 2) {
      _ref.read(panToolProvider).onScaleUpdate(details, mapState);
      return;
    }
    if (_pointerCount == 1) {
      _lassoPoints.add(details.localFocalPoint);
      mapState.setState(() {});
    }
  }

  /// スケール終了イベント
  /// 1本指: 投げ縄選択, 2本指: パン
  @override
  void onScaleEnd(ScaleEndDetails details, IMapState mapState) async {
    if (_ref.read(panToolProvider).isMiddleButtonDragging) return;
    if (_pointerCount == 2) {
      _ref.read(panToolProvider).onScaleEnd(details, mapState);
      _pointerCount = 0;
      return;
    }
    if (_pointerCount == 1 && _lassoPoints.length >= 3) {
      final lassoPolygon =
          _lassoPoints
              .map((offset) => mapState.offsetToLatLng(offset))
              .toList();
      final lassoPolygonLatLng = List<LatLng>.from(lassoPolygon);
      if (lassoPolygonLatLng.first != lassoPolygonLatLng.last) {
        lassoPolygonLatLng.add(lassoPolygonLatLng.first);
      }
      // 左下ボタンが有効なら全可視レイヤーが対象で、既存の選択に足す。
      // 無効なら従来どおり選択中レイヤーだけを対象に置き換える
      final multi = _ref.read(isFabActiveProvider);
      final layer = _ref.read(selectedLayerNodeProvider);
      List<FeatureNode>? features;
      if (multi) {
        features = [
          ...mapState.pointFeatures,
          ...mapState.lineFeatures,
          ...mapState.polygonFeatures,
        ];
      } else if (layer != null) {
        final layerFeatures = layer.children.whereType<FeatureNode>().toList();
        if (layerFeatures.isNotEmpty) {
          features = layerFeatures;
        } else {
          final dbFeatures = layer.features;
          features = dbFeatures.whereType<FeatureNode>().toList();
          for (final feature in features) {
            layer.addChild(feature);
          }
        }
      }
      if (features != null) {
        final selected =
            features.where((f) {
              if (f is PointFeatureNode) {
                return GeometryCalc.pointInPolygonWithHoles(f.centroid, [
                  lassoPolygonLatLng,
                ]);
              }
              if (f is LineFeatureNode) {
                final geom = f.geometry;
                if (geom is List<LatLng>) {
                  return geom.any(
                    (pt) => GeometryCalc.pointInPolygonWithHoles(pt, [
                      lassoPolygonLatLng,
                    ]),
                  );
                }
                return false;
              }
              if (f is PolygonFeatureNode) {
                final geom = f.geometry;
                if (geom is List<List<LatLng>>) {
                  return geom
                          .expand((ring) => ring)
                          .any(
                            (pt) => GeometryCalc.pointInPolygonWithHoles(pt, [
                              lassoPolygonLatLng,
                            ]),
                          ) ||
                      lassoPolygonLatLng.any(
                        (pt) => GeometryCalc.pointInPolygonWithHoles(pt, geom),
                      );
                }
                return false;
              }
              return false;
            }).toList();
        final notifier = _ref.read(selectedFeaturesProvider.notifier);
        if (multi) {
          notifier.set({..._ref.read(selectedFeaturesProvider), ...selected}.toList());
        } else {
          notifier.set(selected);
        }
      }
      _lassoPoints.clear();
      mapState.setState(() {});
    }
    _pointerCount = 0;
  }

  /// マウスホイールスクロールイベント（ズーム機能）
  @override
  void onPointerSignal(PointerEvent event, IMapState mapState) {
    if (event is PointerScrollEvent) {
      _ref.read(panToolProvider).handleMouseWheelZoom(event, mapState);
    }
  }

  @override
  void onMiddleButtonDown(PointerDownEvent event, IMapState mapState) {
    _ref.read(panToolProvider).onMiddleButtonDown(event, mapState);
  }

  @override
  void onMiddleButtonMove(PointerMoveEvent event, IMapState mapState) {
    _ref.read(panToolProvider).onMiddleButtonMove(event, mapState);
  }

  @override
  void onMiddleButtonUp(PointerUpEvent event, IMapState mapState) {
    _ref.read(panToolProvider).onMiddleButtonUp(event, mapState);
  }
}
