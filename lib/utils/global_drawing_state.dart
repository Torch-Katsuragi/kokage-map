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
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../providers/selection_providers.dart';
import '../widgets/external_layer_actions.dart';

/// グローバルな描画状態とメタデータを管理するクラス
/// GPS測量とペンツールでの描画状態を共有する。
/// 線と面は同じ形の描きかけ（[_Stroke]）を 1 本ずつ持ち、どちらを触るかは `isLine` で選ぶ。
///
/// 描きかけが変わると [notifyListeners] する。描きかけを描く・読む側（地図面、確定ボタン、長さ・面積の札）は
/// これを聞いて描き直す（以前はツールが地図ページ全体を setState していた）
class GlobalDrawingState extends ChangeNotifier {
  static final GlobalDrawingState instance = GlobalDrawingState._internal();
  factory GlobalDrawingState() => instance;
  GlobalDrawingState._internal();

  Ref? _ref;

  void setRef(Ref ref) {
    _ref = ref;
  }

  final _line = _Stroke();
  final _polygon = _Stroke();

  _Stroke _stroke(bool isLine) => isLine ? _line : _polygon;

  /// 追記対象のFeatureNode（nullの場合は新規作成モード）
  FeatureNode? _editingFeature;

  /// 自動保存機能関連
  Timer? _autoSaveTimer;
  static const Duration _autoSaveInterval = Duration(minutes: 1);
  int _autoSaveCounter = 0;

  /// 描きかけの点列と付帯情報（呼んだ側が持っていても後から変わらない複製）
  List<LatLng> get drawingLine => _line.view.$1;
  List<LatLng> get drawingPolygon => _polygon.view.$1;
  List<Map<String, dynamic>?> get lineMetadata => _line.view.$2;
  List<Map<String, dynamic>?> get polygonMetadata => _polygon.view.$2;

  /// プレビュー用の点座標（点描画用）
  LatLng? _pointPreview;
  LatLng? get pointPreview => _pointPreview;

  /// 線（[isLine]）か面に点を追加する。
  /// [metadata] は GPS 測量の値（ペンで打った点は null）
  void addPoint(LatLng position, Map<String, dynamic>? metadata, {required bool isLine}) {
    _stroke(isLine).add(position, metadata);

    // 自動保存タイマーの開始/リセット
    _resetAutoSaveTimer();
    notifyListeners();
  }

  /// 点プレビューの設定
  void setPointPreview(LatLng? position) {
    if (_pointPreview == position) return;
    _pointPreview = position;
    notifyListeners();
  }

  /// 線（[isLine]）か面の描きかけを捨てる
  void clear({required bool isLine}) {
    _stroke(isLine).clear();
    AppLogger.debug('[GlobalDrawingState] ${isLine ? '線' : 'ポリゴン'}描画データをクリア');
    notifyListeners();
  }

  /// 全描画データをクリア
  void clearAll() {
    _line.clear();
    _polygon.clear();
    _pointPreview = null;
    _editingFeature = null; // 追記モードもクリア
    _stopAutoSaveTimer(); // 自動保存タイマーも停止
    AppLogger.debug('[GlobalDrawingState] 全描画データをクリア');
    notifyListeners();
  }

  /// 線描画が進行中かチェック
  bool get isLineDrawing => _line.points.isNotEmpty;

  /// ポリゴン描画が進行中かチェック
  bool get isPolygonDrawing => _polygon.points.isNotEmpty;

  /// 何らかの描画が進行中かチェック
  bool get isDrawing => isLineDrawing || isPolygonDrawing;

  /// 線（[isLine]）か面の最後の点を取り消す
  void undo({required bool isLine}) {
    final removed = _stroke(isLine).removeLast();
    AppLogger.debug(removed == null
        ? '[GlobalDrawingState] Undo: 削除する点がありません'
        : '[GlobalDrawingState] ${isLine ? '線' : 'ポリゴン'}の最後の点を削除: $removed');
    if (removed != null) notifyListeners();
  }

  /// 線（[isLine]）か面の点ごとの付帯情報（GPS 測量の値。ペンの点は座標だけ）
  List<Map<String, dynamic>> pointsWithMetadata({required bool isLine}) => _stroke(isLine).withMetadata();

  /// 描きかけを地物として確定する。追記中は追記先を更新、そうでなければ [layerNode] に作る。
  /// 線か面かは、追記中は追記先の形、新規は [layerNode] の形で決まる
  /// [closeRing] - ポリゴンを閉じる処理
  /// [additionalMetadata] - 追加メタデータ（GPS測量データなど）
  /// [refreshCallback] - フィーチャ作成後のUI更新コールバック
  Future<bool> confirmCurrentFeature({
    LayerNode? layerNode,
    required String name,
    required String description,
    required List<LatLng> Function(List<LatLng>) closeRing,
    Map<String, dynamic>? additionalMetadata,
    void Function()? refreshCallback,
  }) async {
    final shape = _editingFeature ?? layerNode;
    // 読み取り専用レイヤ（shp・GeoJSON など）には書かない（ペン・GPS 測量・自動保存の確定がすべてここを通る）
    final target = _editingFeature?.parent ?? layerNode;
    if (readOnlyLayerOf(target) != null) {
      final ref = _ref;
      if (ref != null) refuseReadOnlyEditBy(ref.read, target);
      return false;
    }
    final isLine = switch (shape) {
      LineFeatureNode() || LineLayerNode() => true,
      PolygonFeatureNode() || PolygonLayerNode() => false,
      _ => null,
    };
    if (isLine == null || _stroke(isLine).points.isEmpty) {
      AppLogger.debug('[GlobalDrawingState] 確定処理: 有効な描画データまたはレイヤーがありません');
      return false;
    }
    return _confirm(
      isLine: isLine,
      layerNode: layerNode,
      name: name,
      description: description,
      closeRing: closeRing,
      additionalMetadata: additionalMetadata,
      refreshCallback: refreshCallback,
    );
  }

  /// 線（[isLine]）か面の確定作成・更新
  /// [clearAfterConfirm] - 確定後に描画データをクリアするか（自動保存はクリアしない）
  Future<bool> _confirm({
    required bool isLine,
    LayerNode? layerNode,
    required String name,
    required String description,
    required List<LatLng> Function(List<LatLng>) closeRing,
    Map<String, dynamic>? additionalMetadata,
    void Function()? refreshCallback,
    bool clearAfterConfirm = true,
  }) async {
    final kind = isLine ? '線' : 'ポリゴン';
    final points = _stroke(isLine).points;
    if (points.length < (isLine ? 2 : 3)) {
      AppLogger.debug('[GlobalDrawingState] $kind確定: 点数が不足しています');
      return false;
    }

    try {
      // 写しを渡す（閉じ済みだと closeRing は描きかけのリストをそのまま返し、確定後の clear で中身が消える）
      final closed = isLine ? null : List<LatLng>.of(closeRing(points));

      // メタデータを統合（GPS測量データまたはpen_toolデータを含める）
      final metadata = <String, dynamic>{...?additionalMetadata};
      final pointsWithMetadata = _stroke(isLine).withMetadata();
      if (pointsWithMetadata.isNotEmpty) {
        metadata['drawing_points'] = pointsWithMetadata;
      }

      final editing = _editingFeature;
      if (editing != null && (isLine ? editing is LineFeatureNode : editing is PolygonFeatureNode)) {
        // 追記モード：updateGeometryで新しいジオメトリと属性を同時に更新
        final success = await editing.updateGeometry(
          name: name.isNotEmpty ? name : editing.name,
          description: description,
          metadata: metadata.isNotEmpty ? metadata : null,
          newGeometry: isLine ? List<LatLng>.from(points) : [closed!],
        );
        if (!success) {
          AppLogger.debug('[GlobalDrawingState] $kindフィーチャ更新エラー');
          return false;
        }
        AppLogger.debug('[GlobalDrawingState] $kindフィーチャを更新しました: $name');
      } else {
        // 新規作成モード
        switch (layerNode) {
          case final LineLayerNode layer when isLine:
            await LineFeatureNode.createIn(
              layer,
              List<LatLng>.from(points),
              name.isNotEmpty ? name : t.editor.lineFeature,
              description,
              metadata: metadata.isNotEmpty ? metadata : null,
            );
          case final PolygonLayerNode layer when !isLine:
            await PolygonFeatureNode.createIn(
              layer,
              [closed!],
              name.isNotEmpty ? name : t.editor.polygonFeature,
              description,
              metadata: metadata.isNotEmpty ? metadata : null,
            );
          default:
            AppLogger.debug('[GlobalDrawingState] 新規作成には$kindのlayerNodeが必要です');
            return false;
        }
        AppLogger.debug('[GlobalDrawingState] $kindフィーチャを確定作成しました: $name');
      }

      if (clearAfterConfirm) {
        clearAll();
      }
      refreshCallback?.call();
      return true;
    } catch (e) {
      AppLogger.debug('[GlobalDrawingState] $kindフィーチャ処理エラー: $e');
      return false;
    }
  }

  /// 線・面の地物の追記を始める（今の形と点ごとの付帯情報を描きかけに戻す）。線・面以外は何もしない
  void _resumeEditing(FeatureNode feature) {
    final List<LatLng> points;
    if (feature is LineFeatureNode) {
      points = feature.line;
    } else if (feature is PolygonFeatureNode) {
      // 外環のみ。閉じている（最後の点が最初の点と同じ）なら最後の点は除く
      final outerRing = feature.polygon.firstOrNull ?? const <LatLng>[];
      final closed = outerRing.length > 1 &&
          outerRing.first.latitude == outerRing.last.latitude &&
          outerRing.first.longitude == outerRing.last.longitude;
      points = closed ? outerRing.sublist(0, outerRing.length - 1) : outerRing;
    } else {
      return;
    }

    // 現在の描画データをクリアして追記対象を設定
    clearAll();
    _editingFeature = feature;
    final stroke = _stroke(feature is LineFeatureNode)..restore(points, feature.metadata);
    notifyListeners();

    AppLogger.debug(
      '[GlobalDrawingState] フィーチャの追記開始: ${feature.name} (${stroke.points.length}点)',
    );
  }

  /// 自動保存タイマーをリセット（既存のタイマーを停止して新しくスタート）
  void _resetAutoSaveTimer() {
    _stopAutoSaveTimer();
    _startAutoSaveTimer();
  }

  /// 自動保存タイマーを開始
  void _startAutoSaveTimer() {
    // 描画中の場合のみタイマーを開始
    if (!isDrawing) return;

    _autoSaveTimer = Timer(_autoSaveInterval, () {
      AppLogger.debug('[GlobalDrawingState] 自動保存タイマー満了 - 自動保存を実行');
      _performAutoSave();
    });

    AppLogger.debug('[GlobalDrawingState] 自動保存タイマー開始 (${_autoSaveInterval.inMinutes}分)');
  }

  /// 自動保存タイマーを停止
  void _stopAutoSaveTimer() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    AppLogger.debug('[GlobalDrawingState] 自動保存タイマー停止');
  }

  /// 自動保存処理を実行
  Future<void> _performAutoSave() async {
    if (!isDrawing) {
      AppLogger.debug('[GlobalDrawingState] 自動保存: 描画中ではないためスキップ');
      return;
    }

    // 現在選択されているレイヤーを取得
    final selectedLayer = _ref?.read(selectedLayerNodeProvider);
    if (selectedLayer == null) {
      AppLogger.debug('[GlobalDrawingState] 自動保存エラー: 選択されているレイヤーがありません');
      return;
    }

    _autoSaveCounter++;
    final autoSaveName =
        '${t.editor.autoSavePrefix}_${_autoSaveCounter}_${DateTime.now().millisecondsSinceEpoch}';

    AppLogger.debug('[GlobalDrawingState] 自動保存実行: $autoSaveName');
    AppLogger.debug(
      '[GlobalDrawingState] 自動保存DEBUG - selectedLayer: ${selectedLayer.name} (${selectedLayer.runtimeType}), '
      'isLineDrawing: $isLineDrawing, isPolygonDrawing: $isPolygonDrawing, isEditMode: ${_editingFeature != null}',
    );

    final isLine = isLineDrawing && selectedLayer is LineLayerNode
        ? true
        : isPolygonDrawing && selectedLayer is PolygonLayerNode
            ? false
            : null;
    if (isLine == null) {
      AppLogger.debug(
        '[GlobalDrawingState] 自動保存エラー: レイヤータイプが描画タイプと一致しません '
        '(selectedLayer=${selectedLayer.runtimeType}, isLineDrawing=$isLineDrawing, isPolygonDrawing=$isPolygonDrawing)',
      );
      return;
    }

    try {
      // 追記中なら追記先を更新、そうでなければ新規作成。描画データはクリアしない
      final success = await _confirm(
        isLine: isLine,
        layerNode: selectedLayer,
        name: autoSaveName,
        description: t.editor.autoSaveDescription,
        closeRing: (points) => List<LatLng>.from(points)..add(points.first),
        clearAfterConfirm: false,
      );

      // 作成されたフィーチャを取得
      final savedFeature = success ? selectedLayer.features.lastOrNull : null;
      if (savedFeature != null) {
        // 自動保存成功後、追記モードで描画を継続し、タイマーを再開する
        AppLogger.debug('[GlobalDrawingState] 自動保存成功 - 追記モードで継続開始: ${savedFeature.name}');
        _resumeEditing(savedFeature);
        _resetAutoSaveTimer();
      } else {
        AppLogger.debug(
          '[GlobalDrawingState] 自動保存失敗 - success: $success, savedFeature: $savedFeature',
        );
      }
    } catch (e, stackTrace) {
      AppLogger.debug('[GlobalDrawingState] 自動保存エラー: $e');
      AppLogger.debug('[GlobalDrawingState] 自動保存スタックトレース: $stackTrace');
    }
  }
}

/// 描きかけの線または面 1 本: 点列と点ごとの付帯情報（GPS 測量の値。ペンの点は null）
class _Stroke {
  final points = <LatLng>[];
  final metadata = <Map<String, dynamic>?>[];

  /// 外に渡す複製。中身が変わったときだけ作り直す。
  /// 以前は呼ぶたびに複製していて、描いている間は指の 1 動きで何十回も点の数ぶん複製していた（2026-10-06）。
  /// 変わったかどうかは点の数と最初・最後の点で見る（追加・取消・入れ替えのどれでもどれかが変わる）
  _DrawingView? _view;

  _DrawingView get view {
    final key = (points.length, metadata.length, points.firstOrNull, points.lastOrNull);
    final before = _view;
    if (before != null && before.$3 == key) return before;
    return _view = (List<LatLng>.unmodifiable(points), List<Map<String, dynamic>?>.unmodifiable(metadata), key);
  }

  void add(LatLng position, Map<String, dynamic>? meta) {
    points.add(position);
    metadata.add(meta);
  }

  void clear() {
    points.clear();
    metadata.clear();
  }

  /// 最後の点を外して返す（点が無ければ null）
  LatLng? removeLast() {
    if (points.isEmpty) return null;
    metadata.removeLast();
    return points.removeLast();
  }

  /// 点ごとの付帯情報。GPS 測量の点はその値、ペンの点は座標だけ
  List<Map<String, dynamic>> withMetadata() => [
        for (var i = 0; i < points.length; i++)
          metadata[i] ??
              {
                'latitude': points[i].latitude,
                'longitude': points[i].longitude,
                'data_source': 'pen_tool',
                'timestamp': DateTime.now().toIso8601String(),
              },
      ];

  /// 追記を始めるときに、地物の今の形 [shape] と保存してある点ごとの付帯情報（`drawing_points`）を戻す
  void restore(List<LatLng> shape, Map<String, dynamic>? featureMetadata) {
    points.addAll(shape);
    final drawingPoints = featureMetadata?['drawing_points'] as List<dynamic>?;
    for (final pointData in drawingPoints ?? const []) {
      // pen_tool の点（と形の分からないもの）は null
      metadata.add(pointData is Map<String, dynamic> && pointData['data_source'] != 'pen_tool'
          ? Map<String, dynamic>.from(pointData)
          : null);
    }
    // メタデータの数が足りない場合は pen_tool 扱いで補完
    while (metadata.length < points.length) {
      metadata.add(null);
    }
  }
}

/// 点の一覧と付帯情報の複製、作ったときの中身の鍵（点の数・付帯情報の数・最初と最後の点）
typedef _DrawingView = (List<LatLng>, List<Map<String, dynamic>?>, (int, int, LatLng?, LatLng?));
