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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../providers/selection_providers.dart';

/// グローバルな描画状態とメタデータを管理するクラス
/// GPS測量とペンツールでの描画状態を共有する
class GlobalDrawingState {
  static final GlobalDrawingState instance = GlobalDrawingState._internal();
  factory GlobalDrawingState() => instance;
  GlobalDrawingState._internal();

  Ref? _ref;

  void setRef(Ref ref) {
    _ref = ref;
  }

  /// 線の描画点列（グローバル共有）
  final List<LatLng> _drawingLine = [];

  /// ポリゴンの描画点列（グローバル共有）
  final List<LatLng> _drawingPolygon = [];

  /// 描画点に対応するメタデータのリスト
  /// 各要素は `Map<String, dynamic>` またはnull（pen_toolでタップした点）
  final List<Map<String, dynamic>?> _lineMetadata = [];
  final List<Map<String, dynamic>?> _polygonMetadata = [];

  /// 追記モード関連
  /// 追記対象のFeatureNode（nullの場合は新規作成モード）
  FeatureNode? _editingFeature;

  /// 自動保存機能関連
  Timer? _autoSaveTimer;
  static const Duration _autoSaveInterval = Duration(minutes: 1);
  int _autoSaveCounter = 0;

  /// 追記モードかどうか
  bool get isEditMode => _editingFeature != null;

  /// 追記対象のFeatureNode
  FeatureNode? get editingFeature => _editingFeature;

  /// Getters
  List<LatLng> get drawingLine => List.unmodifiable(_drawingLine);
  List<LatLng> get drawingPolygon => List.unmodifiable(_drawingPolygon);
  List<Map<String, dynamic>?> get lineMetadata =>
      List.unmodifiable(_lineMetadata);
  List<Map<String, dynamic>?> get polygonMetadata =>
      List.unmodifiable(_polygonMetadata);

  /// プレビュー用の点座標（点描画用）
  LatLng? _pointPreview;
  LatLng? get pointPreview => _pointPreview;

  /// 線描画に点を追加
  /// [position] - 追加する座標
  /// [metadata] - GPSメタデータ（nullの場合はpen_toolによる点）
  void addLinePoint(LatLng position, Map<String, dynamic>? metadata) {
    _drawingLine.add(position);
    _lineMetadata.add(metadata);

    AppLogger.debug(
      '[GlobalDrawingState] 線に点追加: $position, メタデータ: ${metadata != null ? 'あり' : 'なし'}',
    );
    AppLogger.debug('[GlobalDrawingState] 現在の線の点数: ${_drawingLine.length}');

    // 自動保存タイマーの開始/リセット
    _resetAutoSaveTimer();
  }

  /// ポリゴン描画に点を追加
  /// [position] - 追加する座標
  /// [metadata] - GPSメタデータ（nullの場合はpen_toolによる点）
  void addPolygonPoint(LatLng position, Map<String, dynamic>? metadata) {
    _drawingPolygon.add(position);
    _polygonMetadata.add(metadata);

    AppLogger.debug(
      '[GlobalDrawingState] ポリゴンに点追加: $position, メタデータ: ${metadata != null ? 'あり' : 'なし'}',
    );
    AppLogger.debug('[GlobalDrawingState] 現在のポリゴンの点数: ${_drawingPolygon.length}');

    // 自動保存タイマーの開始/リセット
    _resetAutoSaveTimer();
  }

  /// 点プレビューの設定
  void setPointPreview(LatLng? position) {
    _pointPreview = position;
  }

  /// 線描画データをクリア
  void clearLine() {
    _drawingLine.clear();
    _lineMetadata.clear();
    AppLogger.debug('[GlobalDrawingState] 線描画データをクリア');
  }

  /// ポリゴン描画データをクリア
  void clearPolygon() {
    _drawingPolygon.clear();
    _polygonMetadata.clear();
    AppLogger.debug('[GlobalDrawingState] ポリゴン描画データをクリア');
  }

  /// 全描画データをクリア
  void clearAll() {
    clearLine();
    clearPolygon();
    _pointPreview = null;
    _editingFeature = null; // 追記モードもクリア
    _stopAutoSaveTimer(); // 自動保存タイマーも停止
    AppLogger.debug('[GlobalDrawingState] 全描画データをクリア');
  }

  /// 線描画が進行中かチェック
  bool get isLineDrawing => _drawingLine.isNotEmpty;

  /// ポリゴン描画が進行中かチェック
  bool get isPolygonDrawing => _drawingPolygon.isNotEmpty;

  /// 何らかの描画が進行中かチェック
  bool get isDrawing => isLineDrawing || isPolygonDrawing;

  /// 元に戻す処理（Undo）- 統一インターフェース
  /// [isLine] - true: 線の最後の点を削除, false: ポリゴンの最後の点を削除
  void undo({required bool isLine}) {
    if (isLine && isLineDrawing) {
      if (_drawingLine.isNotEmpty) {
        final removedPoint = _drawingLine.removeLast();
        _lineMetadata.removeLast();
        AppLogger.debug('[GlobalDrawingState] 線の最後の点を削除: $removedPoint');
      }
    } else if (!isLine && isPolygonDrawing) {
      if (_drawingPolygon.isNotEmpty) {
        final removedPoint = _drawingPolygon.removeLast();
        _polygonMetadata.removeLast();
        AppLogger.debug('[GlobalDrawingState] ポリゴンの最後の点を削除: $removedPoint');
      }
    } else {
      AppLogger.debug('[GlobalDrawingState] Undo: 削除する点がありません');
    }
  }

  /// キャンセル処理 - 統一インターフェース
  /// [isLine] - true: 線描画をクリア, false: ポリゴン描画をクリア
  void cancel({required bool isLine}) {
    if (isLine) {
      clearLine();
    } else {
      clearPolygon();
    }
    AppLogger.debug('[GlobalDrawingState] ${isLine ? '線' : 'ポリゴン'}描画をキャンセル');
  }

  /// 線フィーチャの確定作成・更新
  /// [layerNode] - 作成先のLayerNode（新規作成の場合のみ）
  /// [name] - フィーチャ名
  /// [description] - フィーチャ説明
  /// [additionalMetadata] - 追加メタデータ（GPS測量データなど）
  /// [refreshCallback] - フィーチャ作成後のUI更新コールバック
  /// [clearAfterConfirm] - 確定後に描画データをクリアするか（デフォルト: true）
  Future<bool> confirmLineFeature({
    LineLayerNode? layerNode,
    required String name,
    required String description,
    Map<String, dynamic>? additionalMetadata,
    void Function()? refreshCallback,
    bool clearAfterConfirm = true,
  }) async {
    if (_drawingLine.length < 2) {
      AppLogger.debug('[GlobalDrawingState] 線確定: 点数が不足しています（最低2点必要）');
      return false;
    }

    try {
      // メタデータを統合
      final metadata = <String, dynamic>{};
      if (additionalMetadata != null) {
        metadata.addAll(additionalMetadata);
      }

      // GPS測量データまたはpen_toolデータを含める
      final pointsWithMetadata = getLineWithMetadata();
      if (pointsWithMetadata.isNotEmpty) {
        metadata['drawing_points'] = pointsWithMetadata;
      }

      if (isEditMode && _editingFeature is LineFeatureNode) {
        // 追記モード：既存フィーチャを更新
        final feature = _editingFeature as LineFeatureNode;

        // updateGeometryで新しいジオメトリと属性を同時に更新
        final success = await feature.updateGeometry(
          name: name.isNotEmpty ? name : feature.name,
          description: description,
          metadata: metadata.isNotEmpty ? metadata : null,
          newGeometry: List<LatLng>.from(_drawingLine),
        );

        if (success) {
          AppLogger.debug('[GlobalDrawingState] 線フィーチャを更新しました: $name');
        } else {
          AppLogger.debug('[GlobalDrawingState] 線フィーチャ更新エラー');
          return false;
        }
      } else {
        // 新規作成モード
        if (layerNode == null) {
          AppLogger.debug('[GlobalDrawingState] 新規作成にはlayerNodeが必要です');
          return false;
        }

        await LineFeatureNode.createIn(
          layerNode,
          List<LatLng>.from(_drawingLine),
          name.isNotEmpty ? name : t.editor.lineFeature,
          description,
          metadata: metadata.isNotEmpty ? metadata : null,
        );

        AppLogger.debug('[GlobalDrawingState] 線フィーチャを確定作成しました: $name');
      }

      // 描画データをクリア
      if (clearAfterConfirm) {
        clearAll();
      }

      // UI更新（追記モードの場合はより強力な更新を実行）
      refreshCallback?.call();

      // 追記モードの場合はデバッグログ出力
      if (isEditMode) {
        AppLogger.debug('[GlobalDrawingState] 追記モード完了 - UI強制更新を実行');
      }

      return true;
    } catch (e) {
      AppLogger.debug('[GlobalDrawingState] 線フィーチャ処理エラー: $e');
      return false;
    }
  }

  /// ポリゴンフィーチャの確定作成・更新
  /// [layerNode] - 作成先のLayerNode（新規作成の場合のみ）
  /// [name] - フィーチャ名
  /// [description] - フィーチャ説明
  /// [closeRing] - ポリゴンを閉じる処理
  /// [additionalMetadata] - 追加メタデータ（GPS測量データなど）
  /// [refreshCallback] - フィーチャ作成後のUI更新コールバック
  /// [clearAfterConfirm] - 確定後に描画データをクリアするか（デフォルト: true）
  Future<bool> confirmPolygonFeature({
    PolygonLayerNode? layerNode,
    required String name,
    required String description,
    required List<LatLng> Function(List<LatLng>) closeRing,
    Map<String, dynamic>? additionalMetadata,
    void Function()? refreshCallback,
    bool clearAfterConfirm = true,
  }) async {
    if (_drawingPolygon.length < 3) {
      AppLogger.debug('[GlobalDrawingState] ポリゴン確定: 点数が不足しています（最低3点必要）');
      return false;
    }

    try {
      // ポリゴンを閉じる
      final closedPolygon = closeRing(_drawingPolygon);

      // メタデータを統合
      final metadata = <String, dynamic>{};
      if (additionalMetadata != null) {
        metadata.addAll(additionalMetadata);
      }

      // GPS測量データまたはpen_toolデータを含める
      final pointsWithMetadata = getPolygonWithMetadata();
      if (pointsWithMetadata.isNotEmpty) {
        metadata['drawing_points'] = pointsWithMetadata;
      }

      if (isEditMode && _editingFeature is PolygonFeatureNode) {
        // 追記モード：既存フィーチャを更新
        final feature = _editingFeature as PolygonFeatureNode;

        // updateGeometryで新しいジオメトリと属性を同時に更新
        final success = await feature.updateGeometry(
          name: name.isNotEmpty ? name : feature.name,
          description: description,
          metadata: metadata.isNotEmpty ? metadata : null,
          newGeometry: [closedPolygon],
        );

        if (success) {
          AppLogger.debug('[GlobalDrawingState] ポリゴンフィーチャを更新しました: $name');
        } else {
          AppLogger.debug('[GlobalDrawingState] ポリゴンフィーチャ更新エラー');
          return false;
        }
      } else {
        // 新規作成モード
        if (layerNode == null) {
          AppLogger.debug('[GlobalDrawingState] 新規作成にはlayerNodeが必要です');
          return false;
        }

        await PolygonFeatureNode.createIn(
          layerNode,
          [closedPolygon],
          name.isNotEmpty ? name : t.editor.polygonFeature,
          description,
          metadata: metadata.isNotEmpty ? metadata : null,
        );

        AppLogger.debug('[GlobalDrawingState] ポリゴンフィーチャを確定作成しました: $name');
      }

      // 描画データをクリア
      if (clearAfterConfirm) {
        clearAll();
      }

      // UI更新（追記モードの場合はより強力な更新を実行）
      refreshCallback?.call();

      // 追記モードの場合はデバッグログ出力
      if (isEditMode) {
        AppLogger.debug('[GlobalDrawingState] 追記モード完了 - UI強制更新を実行');
      }

      return true;
    } catch (e) {
      AppLogger.debug('[GlobalDrawingState] ポリゴンフィーチャ処理エラー: $e');
      return false;
    }
  }

  /// 汎用的な確定処理
  /// [layerNode] - 作成先のLayerNode（新規作成の場合のみ）
  /// [name] - フィーチャ名
  /// [description] - フィーチャ説明
  /// [closeRing] - ポリゴンを閉じる処理（PolygonLayerNodeの場合のみ）
  /// [additionalMetadata] - 追加メタデータ
  /// [refreshCallback] - フィーチャ作成後のUI更新コールバック
  Future<bool> confirmCurrentFeature({
    LayerNode? layerNode,
    required String name,
    required String description,
    List<LatLng> Function(List<LatLng>)? closeRing,
    Map<String, dynamic>? additionalMetadata,
    void Function()? refreshCallback,
  }) async {
    // 追記モードの場合、layerNodeは不要
    if (isEditMode) {
      if (_editingFeature is LineFeatureNode && isLineDrawing) {
        return confirmLineFeature(
          name: name,
          description: description,
          additionalMetadata: additionalMetadata,
          refreshCallback: refreshCallback,
        );
      } else if (_editingFeature is PolygonFeatureNode && isPolygonDrawing) {
        if (closeRing == null) {
          AppLogger.debug('[GlobalDrawingState] ポリゴン確定: closeRing関数が必要です');
          return false;
        }
        return confirmPolygonFeature(
          name: name,
          description: description,
          closeRing: closeRing,
          additionalMetadata: additionalMetadata,
          refreshCallback: refreshCallback,
        );
      }
    } else {
      // 新規作成モード
      if (layerNode == null) {
        AppLogger.debug('[GlobalDrawingState] 新規作成にはlayerNodeが必要です');
        return false;
      }

      if (layerNode is LineLayerNode && isLineDrawing) {
        return confirmLineFeature(
          layerNode: layerNode,
          name: name,
          description: description,
          additionalMetadata: additionalMetadata,
          refreshCallback: refreshCallback,
        );
      } else if (layerNode is PolygonLayerNode && isPolygonDrawing) {
        if (closeRing == null) {
          AppLogger.debug('[GlobalDrawingState] ポリゴン確定: closeRing関数が必要です');
          return false;
        }
        return confirmPolygonFeature(
          layerNode: layerNode,
          name: name,
          description: description,
          closeRing: closeRing,
          additionalMetadata: additionalMetadata,
          refreshCallback: refreshCallback,
        );
      }
    }

    AppLogger.debug('[GlobalDrawingState] 確定処理: 有効な描画データまたはレイヤーがありません');
    return false;
  }

  /// メタデータ付きの線座標リストを取得
  /// 戻り値: `List<Map<String, dynamic>>` - 座標とメタデータを含む構造
  List<Map<String, dynamic>> getLineWithMetadata() {
    final result = <Map<String, dynamic>>[];
    for (int i = 0; i < _drawingLine.length; i++) {
      final point = _drawingLine[i];
      final metadata = _lineMetadata[i];

      if (metadata != null) {
        // GPS測量データの場合、既存のメタデータを使用
        result.add(metadata);
      } else {
        // pen_toolでタップした点の場合、座標のみのデータを作成
        result.add({
          'latitude': point.latitude,
          'longitude': point.longitude,
          'data_source': 'pen_tool',
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
    }
    return result;
  }

  /// メタデータ付きのポリゴン座標リストを取得
  /// 戻り値: `List<Map<String, dynamic>>` - 座標とメタデータを含む構造
  List<Map<String, dynamic>> getPolygonWithMetadata() {
    final result = <Map<String, dynamic>>[];
    for (int i = 0; i < _drawingPolygon.length; i++) {
      final point = _drawingPolygon[i];
      final metadata = _polygonMetadata[i];

      if (metadata != null) {
        // GPS測量データの場合、既存のメタデータを使用
        result.add(metadata);
      } else {
        // pen_toolでタップした点の場合、座標のみのデータを作成
        result.add({
          'latitude': point.latitude,
          'longitude': point.longitude,
          'data_source': 'pen_tool',
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
    }
    return result;
  }

  /// 線フィーチャの追記を開始
  /// [feature] - 追記対象のLineFeatureNode
  void startEditingLineFeature(LineFeatureNode feature) {
    // 現在の描画データをクリア
    clearAll();

    // 追記対象を設定
    _editingFeature = feature;

    // 既存の線データを復元
    final existingLine = feature.line;
    _drawingLine.addAll(existingLine);

    // 既存のメタデータを復元（drawing_pointsから復元を試行）
    final existingMetadata = feature.metadata;
    if (existingMetadata != null &&
        existingMetadata.containsKey('drawing_points')) {
      final drawingPoints =
          existingMetadata['drawing_points'] as List<dynamic>?;
      if (drawingPoints != null) {
        // メタデータから復元
        for (final pointData in drawingPoints) {
          if (pointData is Map<String, dynamic>) {
            if (pointData['data_source'] == 'pen_tool') {
              _lineMetadata.add(null); // pen_toolの点はnull
            } else {
              _lineMetadata.add(Map<String, dynamic>.from(pointData));
            }
          } else {
            _lineMetadata.add(null); // デフォルトはpen_tool扱い
          }
        }
      }
    }

    // メタデータの数が足りない場合は補完
    while (_lineMetadata.length < _drawingLine.length) {
      _lineMetadata.add(null); // pen_tool扱いで補完
    }

    AppLogger.debug(
      '[GlobalDrawingState] 線フィーチャの追記開始: ${feature.name} (${_drawingLine.length}点)',
    );
  }

  /// ポリゴンフィーチャの追記を開始
  /// [feature] - 追記対象のPolygonFeatureNode
  void startEditingPolygonFeature(PolygonFeatureNode feature) {
    // 現在の描画データをクリア
    clearAll();

    // 追記対象を設定
    _editingFeature = feature;

    // 既存のポリゴンデータを復元（外環のみ）
    if (feature.polygon.isNotEmpty) {
      final outerRing = feature.polygon[0];
      // 最後の点が最初の点と同じ場合（閉じられている場合）は除外
      if (outerRing.length > 1 &&
          outerRing.first.latitude == outerRing.last.latitude &&
          outerRing.first.longitude == outerRing.last.longitude) {
        _drawingPolygon.addAll(outerRing.sublist(0, outerRing.length - 1));
      } else {
        _drawingPolygon.addAll(outerRing);
      }
    }

    // 既存のメタデータを復元（drawing_pointsから復元を試行）
    final existingMetadata = feature.metadata;
    if (existingMetadata != null &&
        existingMetadata.containsKey('drawing_points')) {
      final drawingPoints =
          existingMetadata['drawing_points'] as List<dynamic>?;
      if (drawingPoints != null) {
        // メタデータから復元
        for (final pointData in drawingPoints) {
          if (pointData is Map<String, dynamic>) {
            if (pointData['data_source'] == 'pen_tool') {
              _polygonMetadata.add(null); // pen_toolの点はnull
            } else {
              _polygonMetadata.add(Map<String, dynamic>.from(pointData));
            }
          } else {
            _polygonMetadata.add(null); // デフォルトはpen_tool扱い
          }
        }
      }
    }

    // メタデータの数が足りない場合は補完
    while (_polygonMetadata.length < _drawingPolygon.length) {
      _polygonMetadata.add(null); // pen_tool扱いで補完
    }

    AppLogger.debug(
      '[GlobalDrawingState] ポリゴンフィーチャの追記開始: ${feature.name} (${_drawingPolygon.length}点)',
    );
  }

  /// 汎用的な追記開始メソッド
  /// [feature] - 追記対象のFeatureNode
  bool startEditingFeature(FeatureNode feature) {
    if (feature is LineFeatureNode) {
      startEditingLineFeature(feature);
      return true;
    } else if (feature is PolygonFeatureNode) {
      startEditingPolygonFeature(feature);
      return true;
    } else {
      AppLogger.debug(
        '[GlobalDrawingState] サポートされていないフィーチャタイプです: ${feature.runtimeType}',
      );
      return false;
    }
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
    final autoSaveDescription = t.editor.autoSaveDescription;

    AppLogger.debug('[GlobalDrawingState] 自動保存実行: $autoSaveName');
    AppLogger.debug(
      '[GlobalDrawingState] 自動保存DEBUG - selectedLayer: ${selectedLayer.name} (${selectedLayer.runtimeType})',
    );
    AppLogger.debug(
      '[GlobalDrawingState] 自動保存DEBUG - isLineDrawing: $isLineDrawing, isPolygonDrawing: $isPolygonDrawing',
    );
    AppLogger.debug('[GlobalDrawingState] 自動保存DEBUG - isEditMode: $isEditMode');

    try {
      bool success = false;
      FeatureNode? savedFeature;

      if (isLineDrawing && selectedLayer is LineLayerNode) {
        AppLogger.debug('[GlobalDrawingState] 自動保存: 線の処理開始 - 点数: ${_drawingLine.length}');

        // 線の自動保存（常に新規作成、描画データはクリアしない）
        success = await confirmLineFeature(
          layerNode: selectedLayer,
          name: autoSaveName,
          description: autoSaveDescription,
          refreshCallback: () {},
          clearAfterConfirm: false,
        );

        // 作成されたフィーチャを取得
        if (success) {
          final features = selectedLayer.features;
          if (features.isNotEmpty) {
            savedFeature = features.last;
            AppLogger.debug(
              '[GlobalDrawingState] 自動保存: 作成された線フィーチャを取得 - ${savedFeature.name}',
            );
          }
        }
      } else if (isPolygonDrawing && selectedLayer is PolygonLayerNode) {
        AppLogger.debug(
          '[GlobalDrawingState] 自動保存: ポリゴンの処理開始 - 点数: ${_drawingPolygon.length}',
        );

        // ポリゴンの自動保存（常に新規作成、描画データはクリアしない）
        success = await confirmPolygonFeature(
          layerNode: selectedLayer,
          name: autoSaveName,
          description: autoSaveDescription,
          closeRing: (points) => List<LatLng>.from(points)..add(points.first),
          refreshCallback: () {},
          clearAfterConfirm: false,
        );

        // 作成されたフィーチャを取得
        if (success) {
          final features = selectedLayer.features;
          if (features.isNotEmpty) {
            savedFeature = features.last;
            AppLogger.debug(
              '[GlobalDrawingState] 自動保存: 作成されたポリゴンフィーチャを取得 - ${savedFeature.name}',
            );
          }
        }
      } else {
        AppLogger.debug('[GlobalDrawingState] 自動保存エラー: レイヤータイプが描画タイプと一致しません');
        AppLogger.debug(
          '[GlobalDrawingState] 自動保存エラー: selectedLayer=${selectedLayer.runtimeType}, isLineDrawing=$isLineDrawing, isPolygonDrawing=$isPolygonDrawing',
        );
      }

      if (success && savedFeature != null) {
        // 自動保存成功後、追記モードで描画を継続（clearAll()は呼ばない）
        AppLogger.debug('[GlobalDrawingState] 自動保存成功 - 追記モードで継続開始');

        if (savedFeature is LineFeatureNode) {
          startEditingLineFeature(savedFeature);
        } else if (savedFeature is PolygonFeatureNode) {
          startEditingPolygonFeature(savedFeature);
        }

        // タイマーを再開（追記モードでの継続）
        _resetAutoSaveTimer();
        AppLogger.debug('[GlobalDrawingState] 自動保存: 追記モードでタイマー再開');
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

