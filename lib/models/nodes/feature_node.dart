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
// Root Maps: フィーチャノードクラス
// GeoPackage内のフィーチャに対応するレイヤツリーノード
// turf_dartのFeatureオブジェクトをメインデータとして使用

import 'dart:async';
import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:turf/turf.dart' as turf;

import '../../converters/turf_converter.dart';
import '../../core/node_types.dart';
import '../geopackage/geopackage_file.dart';
import 'layer_node.dart';
import 'layer_tree_node.dart';

/// フィーチャノード基底クラス
/// LayerNodeの子としてfeature単位で生成される
/// データはLayerNode._featureMapに一元管理され、FeatureNodeは参照と操作を提供
abstract class FeatureNode extends LayerTreeNode {
  /// dispose時に呼び出されるコールバック（選択状態からの除去等）
  static void Function(FeatureNode)? _onDispose;

  /// disposeコールバックを設定
  static void setOnDisposeCallback(void Function(FeatureNode) callback) {
    _onDispose = callback;
  }

  /// DB上のrowId（主キー）- データは持たず、IDのみ保持
  final int _rowId;

  /// 変更の追跡フラグ（将来的なバッチ保存最適化用に予約）
  // ignore: unused_field
  bool _isDirty = false;
  
  /// dispose済みフラグ（null参照対策）
  bool _isDisposed = false;

  LatLng? _cachedCentroid;
  bool _metadataCacheValid = false;
  Map<String, dynamic>? _cachedMetadata;

  /// DB上のrowId（主キー）
  int get rowId => _rowId;
  
  /// dispose済みかどうかを取得
  bool get isDisposed => _isDisposed;

  /// turf_dartのFeatureオブジェクトを取得（親のMapから参照）
  turf.Feature get turfFeature {
    if (_isDisposed) {
      throw StateError('FeatureNode is disposed: rowId=$_rowId');
    }
    // 親のLayerNodeがdispose済みの場合もエラーを回避
    if (parent.isDisposed) {
      throw StateError('Parent LayerNode is disposed: rowId=$_rowId, layer=${parent.layerName}');
    }
    final feature = parent.getFeatureById(_rowId);
    if (feature == null) {
      // より詳細なエラー情報を提供
      AppLogger.debug('[ERROR] Feature not found in parent map');
      AppLogger.debug('[ERROR]   rowId: $_rowId');
      AppLogger.debug('[ERROR]   parent layer: ${parent.layerName}');
      AppLogger.debug('[ERROR]   isDisposed: $_isDisposed');
      AppLogger.debug('[ERROR]   parent isDisposed: ${parent.isDisposed}');
      AppLogger.debug('[ERROR]   parent._featureMap size: ${parent.features.length}');
      throw StateError('Feature not found in parent map: rowId=$_rowId, layer=${parent.layerName}');
    }
    return feature;
  }

  /// フィーチャの重心座標（turf_dartで計算、キャッシュあり）
  LatLng get centroid {
    if (_isDisposed || parent.isDisposed) return const LatLng(0, 0);
    return _cachedCentroid ??=
        TurfConverter.calculateCentroid(turfFeature) ?? const LatLng(0, 0);
  }

  /// 座標データをposition型で取得（turf_dart形式）
  List<double> get position {
    if (_isDisposed || parent.isDisposed) return [0, 0];
    final geometry = turfFeature.geometry;
    if (geometry is turf.Point) {
      return TurfConverter.latlngToPosition(
        TurfConverter.pointToLatlng(geometry),
      );
    }
    // Point以外の場合は重心のpositionを返す
    return TurfConverter.latlngToPosition(centroid);
  }

  /// 複数座標データをpositionリストで取得
  List<List<double>> get positions {
    if (_isDisposed || parent.isDisposed) return [];
    final g = turfFeature.geometry;
    if (g is turf.MultiLineString) {
      final lines = TurfConverter.multiLineStringToLatlngs(g);
      return lines.isNotEmpty
          ? TurfConverter.latlngsToPositions(lines.first)
          : [];
    } else if (g is turf.LineString) {
      return TurfConverter.latlngsToPositions(
        TurfConverter.lineStringToLatlngs(g),
      );
    } else if (g is turf.MultiPolygon) {
      final polys = TurfConverter.multiPolygonToLatlngs(g);
      if (polys.isNotEmpty && polys.first.isNotEmpty) {
        return TurfConverter.latlngsToPositions(polys.first.first);
      }
    } else if (g is turf.Polygon) {
      final rings = TurfConverter.polygonToLatlngs(g);
      if (rings.isNotEmpty) {
        return TurfConverter.latlngsToPositions(rings.first);
      }
    }
    return [];
  }

  /// ジオメトリデータ（レガシー互換用、turf_dartから変換して返す）
  /// Multi型 → 最初のサブジオメトリのLatLngを返す（編集ツール互換）
  dynamic get geometry {
    if (_isDisposed || parent.isDisposed) return null;
    final geom = turfFeature.geometry;
    if (geom is turf.Point) {
      return [TurfConverter.pointToLatlng(geom)];
    } else if (geom is turf.MultiLineString) {
      final lines = TurfConverter.multiLineStringToLatlngs(geom);
      return lines.isNotEmpty ? lines.first : <LatLng>[];
    } else if (geom is turf.LineString) {
      return TurfConverter.lineStringToLatlngs(geom);
    } else if (geom is turf.MultiPolygon) {
      final polys = TurfConverter.multiPolygonToLatlngs(geom);
      return polys.isNotEmpty ? polys.first : <List<LatLng>>[];
    } else if (geom is turf.Polygon) {
      return TurfConverter.polygonToLatlngs(geom);
    }
    return null;
  }

  /// 名前のgetter（turf_dartのpropertiesから取得）
  @override
  String get name {
    if (_isDisposed || parent.isDisposed) return 'Disposed Feature';
    return turfFeature.properties?['name'] as String? ?? 'Unnamed Feature';
  }

  /// 名前のsetter（親のMapを更新）
  @override
  set name(String value) {
    if (_isDisposed) return;
    parent.updateFeatureAttribute(_rowId, 'name', value);
    _markDirty();
  }

  /// 説明のgetter（turf_dartのpropertiesから取得）
  String? get description {
    if (_isDisposed || parent.isDisposed) return null;
    return turfFeature.properties?['description'] as String?;
  }

  /// 説明のsetter（親のMapを更新）
  set description(String? value) {
    if (_isDisposed) return;
    parent.updateFeatureAttribute(_rowId, 'description', value);
    _markDirty();
  }

  /// メタデータのgetter（turf_dartのpropertiesから取得、キャッシュあり）
  Map<String, dynamic>? get metadata {
    if (_isDisposed || parent.isDisposed) return null;
    if (_metadataCacheValid) return _cachedMetadata;
    final value = turfFeature.properties?['rmaps_metadata'];
    if (value == null) {
      _cachedMetadata = null;
    } else if (value is Map<String, dynamic>) {
      _cachedMetadata = value;
    } else if (value is String) {
      try {
        _cachedMetadata = Map<String, dynamic>.from(json.decode(value));
      } catch (e) {
        AppLogger.debug('[WARNING] FeatureNode: Failed to parse metadata JSON: $e');
        _cachedMetadata = null;
      }
    } else {
      _cachedMetadata = null;
    }
    _metadataCacheValid = true;
    return _cachedMetadata;
  }

  /// メタデータのsetter（親のMapを更新）
  set metadata(Map<String, dynamic>? value) {
    if (_isDisposed) return;
    parent.updateFeatureAttribute(_rowId, 'rmaps_metadata', value);
    _markDirty();
  }

  void _invalidateCache() {
    _cachedCentroid = null;
    _metadataCacheValid = false;
    _cachedMetadata = null;
  }

  /// 変更フラグをセット
  void _markDirty() {
    AppLogger.debug('[DEBUG] FeatureNode: _markDirty呼び出し - レイヤー:$layerName, 行ID:$rowId');
    _isDirty = true;
    _invalidateCache();
    
    if (_isDisposed) return;
    
    // GeoPackageFileの遅延保存キューに追加
    final rowData = TurfConverter.featureToRowData(turfFeature);
    if (rowData != null) {
      AppLogger.debug('[DEBUG] FeatureNode: rowData変換成功 - 属性数:${rowData.length}');
      AppLogger.debug('[DEBUG] FeatureNode: rowData内容: $rowData');
      geoPackageFile.queueAttributeUpdates(layerName, rowId, rowData);
    } else {
      AppLogger.debug('[ERROR] FeatureNode: rowData変換に失敗しました');
    }
  }

  /// sub_tableからタイムスタンプ範囲を取得する（同期）
  ///
  /// sub_tableが存在し、各エントリにtimestampフィールドがある場合、
  /// 最初と最後のタイムスタンプ、および所要時間を返す。
  /// GeoJSON FeatureCollection形式と旧2D配列形式の両方に対応。
  String? _getSubTableTimeRange() {
    try {
      final subTableValue = turfFeature.properties?['sub_table'];
      if (subTableValue == null || subTableValue is! String || subTableValue.isEmpty) {
        return null;
      }

      final timestamps = <DateTime>[];
      final decoded = jsonDecode(subTableValue);

      // GeoJSON FeatureCollection形式
      if (decoded is Map && decoded['type'] == 'FeatureCollection') {
        final features = decoded['features'] as List;
        for (final f in features) {
          final props = f['properties'] as Map?;
          if (props == null) continue;
          final ts = props['timestamp'] ?? props['time'] ?? props['datetime'];
          if (ts is String && ts.isNotEmpty) {
            final dt = DateTime.tryParse(ts);
            if (dt != null) timestamps.add(dt);
          }
        }
      }
      // 旧2D配列形式: [[headers], [row1], ...]
      else if (decoded is List && decoded.isNotEmpty && decoded.first is List) {
        final headers = (decoded.first as List).cast<String>();
        final tsIndex = headers.indexWhere(
          (h) => h == 'timestamp' || h == 'time' || h == 'datetime',
        );
        if (tsIndex >= 0) {
          for (final row in decoded.skip(1)) {
            if (row is List && tsIndex < row.length) {
              final ts = row[tsIndex];
              if (ts is String && ts.isNotEmpty) {
                final dt = DateTime.tryParse(ts);
                if (dt != null) timestamps.add(dt);
              }
            }
          }
        }
      }

      if (timestamps.length < 2) return null;

      timestamps.sort();
      final first = timestamps.first;
      final last = timestamps.last;
      final duration = last.difference(first);

      // フォーマット
      String fmt(DateTime dt) =>
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';

      String fmtDuration(Duration d) {
        if (d.inHours > 0) {
          return '${d.inHours}時間${d.inMinutes % 60}分';
        } else if (d.inMinutes > 0) {
          return '${d.inMinutes}分${d.inSeconds % 60}秒';
        }
        return '${d.inSeconds}秒';
      }

      return '${fmt(first)} 〜 ${fmt(last)} (${fmtDuration(duration)})';
    } catch (e) {
      // パース失敗時は表示しない
      return null;
    }
  }

  /// 属性値の取得（turf_dartのpropertiesから）
  Future<dynamic> getAttributeValue(String attributeName) async {
    if (_isDisposed) return null;
    return turfFeature.properties?[attributeName];
  }

  /// 属性値の設定（親のMapを更新し、バックグラウンドでDB書き込み）
  Future<void> setAttributeValue(String attributeName, dynamic value) async {
    AppLogger.debug('[DEBUG] FeatureNode: Setting attribute $attributeName = $value');

    if (_isDisposed) {
      AppLogger.debug('[WARNING] FeatureNode is disposed, cannot set attribute');
      return;
    }
    
    // 親のMapを更新（失敗した場合はfalseを返す）
    final success = parent.updateFeatureAttribute(_rowId, attributeName, value);
    if (!success) {
      AppLogger.debug('[WARNING] FeatureNode: updateFeatureAttribute failed for rowId=$_rowId, attribute=$attributeName');
      AppLogger.debug('[WARNING] Feature may not be registered in parent._featureMap yet');
      return;
    }
    
    _markDirty();
  }

  /// 複数の属性値を一括設定
  /// カラムが存在しない場合は自動的に作成する（TEXT型）
  Future<void> setAttributeValues(Map<String, dynamic> attributes) async {
    AppLogger.debug('[DEBUG] FeatureNode: Setting ${attributes.length} attributes');

    if (_isDisposed) {
      AppLogger.debug('[WARNING] FeatureNode is disposed, cannot set attributes');
      return;
    }
    
    // 既存のカラム名を取得
    final existingColumns = await geoPackageFile.getColumnNames(
      layerName,
      getAll: true,
    );
    final existingColumnSet = existingColumns.toSet();
    
    // 存在しないカラムを検出して作成
    final missingColumns = attributes.keys.where((key) => 
      !existingColumnSet.contains(key) && 
      key != 'id' && 
      key != 'geom'
    ).toList();
    
    if (missingColumns.isNotEmpty) {
      AppLogger.debug('[DEBUG] FeatureNode: 以下のカラムを自動作成します: $missingColumns');
      for (final columnName in missingColumns) {
        try {
          await geoPackageFile.addAttributeColumn(
            layerName,
            columnName,
            'TEXT', // デフォルトでTEXT型
          );
          AppLogger.debug('[DEBUG] FeatureNode: カラム作成成功 - $columnName');
        } catch (e) {
          AppLogger.debug('[WARNING] FeatureNode: カラム作成失敗 - $columnName: $e');
          // カラム作成に失敗しても処理は続行（既に存在する場合など）
        }
      }
    }
    
    // 各属性を親のMap経由で更新
    for (final entry in attributes.entries) {
      parent.updateFeatureAttribute(_rowId, entry.key, entry.value);
    }
    _markDirty();
  }

  /// 全属性値を取得
  Future<Map<String, dynamic>> getAllAttributes() async {
    if (_isDisposed) return {};
    return Map<String, dynamic>.from(turfFeature.properties ?? {});
  }

  /// 即座に全ての変更をDBに保存
  Future<void> flushChanges() async {
    await geoPackageFile.flushChanges();
  }

  /// 詳細情報（項目名と値のペア、順序付き）
  List<MapEntry<String, String>> get detailEntries => [
    MapEntry('name', name),
    if (description != null && description!.isNotEmpty)
      MapEntry('description', description!),
    if (metadata != null && metadata!.isNotEmpty)
      ...metadata!.entries.map(
        (e) => MapEntry('metadata.${e.key}', e.value.toString()),
      ),
    MapEntry('id', rowId.toString()),
    MapEntry('latitude', centroid.latitude.toStringAsFixed(6)),
    MapEntry('longitude', centroid.longitude.toStringAsFixed(6)),
  ];

  /// 詳細情報をMap形式で返す（表示用）
  Map<String, String> get infoMap {
    final details = <String, String>{};

    // 基本情報
    details['name'] = name;
    if (description != null && description!.isNotEmpty) {
      details['description'] = description!;
    }

    // メタデータ
    if (metadata != null && metadata!.isNotEmpty) {
      for (final entry in metadata!.entries) {
        details['metadata.${entry.key}'] = entry.value.toString();
      }
    }

    // ID情報
    details['id'] = rowId.toString();

    // 座標情報
    details['latitude'] = centroid.latitude.toStringAsFixed(6);
    details['longitude'] = centroid.longitude.toStringAsFixed(6);

    // カスタム属性（属性テーブルのユーザー定義カラム）
    final systemKeys = details.keys.toSet();
    final props = turfFeature.properties;
    if (props != null) {
      for (final entry in props.entries) {
        if (systemKeys.contains(entry.key)) continue;
        if (entry.value == null) continue;
        details[entry.key] = entry.value.toString();
      }
    }

    return details;
  }

  /// フィーチャ削除（親子関係切断・UI更新の最適化）
  /// DBからの削除も基底クラスで統一処理
  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      AppLogger.debug('[WARNING] FeatureNode already disposed');
      return;
    }
    
    // dispose済みフラグを先に設定（エラー回避のため）
    _isDisposed = true;
    
    try {
      // nameアクセス時のエラーを回避するため、try-catchで囲む
      AppLogger.debug('[DEBUG] FeatureNode.dispose: disposing rowId=$rowId ($runtimeType)');
    } catch (e) {
      AppLogger.debug('[DEBUG] FeatureNode.dispose: disposing rowId=$rowId (name取得失敗)');
    }

    try {
      // 保留中の変更を即座に保存（エラーが発生しても続行）
      await flushChanges();
    } catch (e) {
      AppLogger.debug('[WARNING] FeatureNode.dispose: flushChanges failed: $e');
    }

    // 即座に親子関係を切断し、親の_featureMapからも削除（UI更新を優先）
    // LayerNode.removeFeature()を使用することで、childrenと_featureMapの両方から削除される
    try {
      parent.removeFeature(this);
      AppLogger.debug('[DEBUG] FeatureNode.dispose: removed from parent children and featureMap');
    } catch (e) {
      AppLogger.debug('[WARNING] FeatureNode.dispose: removeFeature failed: $e');
      // フォールバック: 直接削除を試みる
      parent.children.remove(this);
      AppLogger.debug('[DEBUG] FeatureNode.dispose: fallback - removed from parent children only');
    }

    _onDispose?.call(this);

    // 子ノードはFeatureNodeにはないが、安全のためクリア
    children.clear();

    // DB からの削除を**待つ**。
    // ⚠ 以前は投げっぱなしだった。削除直後のリフレッシュで「子が空になった
    //   レイヤ」を DB から読み直すと、まだ消えていない行が新しいノードとして
    //   復活していた（「たまに削除したフィーチャが残る」の正体）
    try {
      final removed = await geoPackageFile.removeFeature(layerName, rowId);
      AppLogger.debug(
        '[DEBUG] FeatureNode.dispose: DB deletion ${removed ? 'completed' : 'matched no row'} (rowId=$rowId)',
      );
    } catch (e) {
      // エラーが発生しても処理は続行（壊れたデータでも削除できるようにする）
      AppLogger.debug(
        '[ERROR] FeatureNode.dispose: DB deletion failed (rowId=$rowId): $e',
      );
    }

    AppLogger.debug('[DEBUG] FeatureNode.dispose: base dispose completed');

    // 基底クラスのdisposeを呼び出し
    try {
      await super.dispose();
    } catch (e) {
      AppLogger.debug('[WARNING] FeatureNode.dispose: super.dispose failed: $e');
    }
  }

  /// 親LayerNode
  @override
  // ignore: overridden_fields
  final LayerNode parent;

  /// rowデータとジオメトリタイプを基にFeatureNodeを作成
  FeatureNode(Map<String, dynamic> row, this.parent, String geometryType)
    : _rowId = row['id'] as int? ?? 0,
      super(
        row['name'] as String? ?? 'Unnamed Feature',
        visible: parent.visible,
        parent: parent,
        children: [],
        nodeType: NodeType.feature,
      ) {
    // 親のMapにturfFeatureを登録
    final turfFeature = TurfConverter.createFeatureFromRow(row, geometryType) ??
        turf.Feature(
          geometry: turf.Point(coordinates: turf.Position.of([0, 0])),
          properties: row,
        );
    parent.addFeatureToMap(_rowId, turfFeature);
  }

  /// turf_dartのFeatureオブジェクトから直接FeatureNodeを作成
  FeatureNode.fromTurfFeature(turf.Feature feature, this.parent)
    : _rowId = feature.properties?['id'] as int? ?? 0,
      super(
        feature.properties?['name'] as String? ?? 'Unnamed Feature',
        visible: parent.visible,
        parent: parent,
        children: [],
        nodeType: NodeType.feature,
      ) {
    // 親のMapにturfFeatureを登録
    parent.addFeatureToMap(_rowId, feature);
  }

  /// GeoPackageFile参照
  GeoPackageFile get geoPackageFile => parent.geoPackageFile;

  /// レイヤ名
  String get layerName => parent.layerName;

  /// ジオメトリと属性を更新する抽象メソッド
  /// サブクラスでジオメトリ型に応じた具体的な実装を行う
  Future<bool> updateGeometry({
    required String name,
    String? description,
    Map<String, dynamic>? metadata,
    dynamic newGeometry,
  }) async {
    // 基底クラスでは何もしない（サブクラスでオーバーライド必須）
    throw UnimplementedError('updateGeometry must be implemented by subclass');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FeatureNode &&
        other.rowId == rowId &&
        other.layerName == layerName &&
        other.geoPackageFile == geoPackageFile;
  }

  @override
  int get hashCode => Object.hash(rowId, layerName, geoPackageFile);
}

/// PointFeatureNode: 点フィーチャ用
class PointFeatureNode extends FeatureNode {
  /// rowデータから点フィーチャノードを作成
  PointFeatureNode(Map<String, dynamic> row, LayerNode parent)
    : super(row, parent, 'Point');

  /// turf_dartのFeatureから点フィーチャノードを作成
  PointFeatureNode.fromTurfFeature(super.feature, super.parent)
    : super.fromTurfFeature();

  /// 点座標（単一座標）
  LatLng get point {
    final geometry = turfFeature.geometry;
    if (geometry is turf.Point) {
      return TurfConverter.pointToLatlng(geometry);
    }
    return const LatLng(0, 0);
  }

  /// 点座標をposition形式で取得
  @override
  List<double> get position {
    return TurfConverter.latlngToPosition(point);
  }

  /// 点座標リスト（レガシー互換用）
  List<LatLng> get points => [point];

  @override
  List<MapEntry<String, String>> get detailEntries {
    return [...super.detailEntries];
  }
  
  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動
  
  @override
  Future<void> updateChildren() async {
    children.clear();
  }

  /// 指定したPointLayerNodeの下に新しい点フィーチャを作成し、PointFeatureNodeインスタンスを返す
  /// DBに保存してrowIdを取得してからFeatureNodeを作成
  static Future<PointFeatureNode?> createIn(
    LayerNode parent,
    LatLng point,
    String name,
    String? description, {
    Map<String, dynamic>? metadata,
  }) async {
    if (parent is! PointLayerNode) return null;
    final gpkgFile = parent.geoPackageFile;
    final layerName = parent.layerName;

    // 属性辞書を作成（カラムの存在確認が必要なため、空の辞書から始める）
    final properties = <String, dynamic>{};
    
    // カラムの存在確認
    final columnNames = await gpkgFile.getColumnNames(layerName, getAll: true);
    final columnSet = columnNames.toSet();
    
    // 存在するカラムのみ値を設定
    if (columnSet.contains('name')) {
      properties['name'] = name;
    }
    if (columnSet.contains('description')) {
      properties['description'] = description;
    }
    if (columnSet.contains('rmaps_metadata') && metadata != null) {
      properties['rmaps_metadata'] = jsonEncode(metadata);
    }

    // DBへの保存を実行してrowIdを取得
    final actualRowId = await gpkgFile.addPointWithAttributes(
      layerName,
      point,
      properties,
    );

    if (actualRowId == null) {
      AppLogger.debug('[ERROR] PointFeatureNode: DB保存に失敗しました - $name');
      return null;
    }

    // rowIdを含むFeatureオブジェクトを作成
    properties['id'] = actualRowId;
    final turfFeature = turf.Feature(
      geometry: TurfConverter.createPoint(point),
      properties: properties,
    );

    // FeatureNodeを作成して親に追加
    final node = PointFeatureNode.fromTurfFeature(turfFeature, parent);
    parent.addChild(node);

    // _featureMapにも登録（updateFeatureAttributeが動作するために必要）
    parent.addFeatureToMap(actualRowId, turfFeature);

    AppLogger.debug('[DEBUG] PointFeatureNode: DB保存完了 - $name (rowId: $actualRowId)');
    return node;
  }

  /// 点フィーチャのジオメトリと属性を更新
  @override
  Future<bool> updateGeometry({
    required String name,
    String? description,
    Map<String, dynamic>? metadata,
    dynamic newGeometry,
  }) async {
    // 新しいジオメトリが渡された場合はそれを使用、なければ現在のpointを使用
    final geometryToUpdate = newGeometry as LatLng? ?? point;

    final success = await geoPackageFile.updatePoint(
      layerName,
      rowId,
      geometryToUpdate,
      name: name,
      description: description ?? '',
      metadata: metadata,
    );

    if (success) {
      // 親のMap内のFeatureを更新
      final updatedFeature = turf.Feature(
        geometry: TurfConverter.createPoint(geometryToUpdate),
        properties: {
          ...turfFeature.properties ?? {},
          'id': _rowId,
          'name': name,
          'description': description,
          'rmaps_metadata': metadata,
        },
      );
      parent.addFeatureToMap(_rowId, updatedFeature);
      _markDirty();

      AppLogger.debug('[DEBUG] PointFeatureNode: ジオメトリ更新成功 - $name');
    } else {
      AppLogger.debug('[ERROR] PointFeatureNode: ジオメトリ更新失敗 - $name');
    }

    return success;
  }

  /// 点フィーチャのジオメトリのみを更新（位置変更）
  Future<bool> updateLocation(LatLng newLocation) async {
    final success = await geoPackageFile.updatePoint(
      layerName,
      rowId,
      newLocation,
      name: name,
      description: description ?? '',
      metadata: metadata,
    );

    if (success) {
      // 親のMap内のFeatureのジオメトリを更新
      final updatedFeature = turf.Feature(
        geometry: TurfConverter.createPoint(newLocation),
        properties: turfFeature.properties,
      );
      parent.addFeatureToMap(_rowId, updatedFeature);
      _markDirty();
      AppLogger.debug('[DEBUG] PointFeatureNode: 位置更新成功 - $name to $newLocation');
    } else {
      AppLogger.debug('[ERROR] PointFeatureNode: 位置更新失敗 - $name');
    }

    return success;
  }
}

/// LineFeatureNode: 線フィーチャ用
class LineFeatureNode extends FeatureNode {
  double? _cachedLength;

  /// rowデータから線フィーチャノードを作成
  LineFeatureNode(Map<String, dynamic> row, LayerNode parent)
    : super(row, parent, 'LineString');

  /// turf_dartのFeatureから線フィーチャノードを作成
  LineFeatureNode.fromTurfFeature(super.feature, super.parent)
    : super.fromTurfFeature();

  @override
  void _invalidateCache() {
    super._invalidateCache();
    _cachedLength = null;
  }

  /// 単一の線分（頂点リスト）。Multi の場合は最初のサブラインを返す
  List<LatLng> get line {
    final geometry = turfFeature.geometry;
    if (geometry is turf.MultiLineString) {
      final lines = TurfConverter.multiLineStringToLatlngs(geometry);
      return lines.isNotEmpty ? lines.first : [];
    }
    if (geometry is turf.LineString) {
      return TurfConverter.lineStringToLatlngs(geometry);
    }
    return [];
  }

  /// 線の座標をpositionリストで取得
  @override
  List<List<double>> get positions {
    return TurfConverter.latlngsToPositions(line);
  }

  /// 線の長さを計算（turf_dartで計算、キャッシュあり）
  double get length {
    if (_isDisposed || parent.isDisposed) return 0.0;
    return _cachedLength ??=
        TurfConverter.calculateLength(turfFeature) ?? 0.0;
  }

  @override
  List<MapEntry<String, String>> get detailEntries {
    final len = length;
    String lengthStr;
    if (len >= 10000) {
      lengthStr = '${(len / 1000).toStringAsFixed(2)} km';
    } else {
      lengthStr = '${len.toStringAsFixed(2)} m';
    }
    return [
      ...super.detailEntries,
      MapEntry('length', lengthStr),
      MapEntry('vertex_count', '${line.length}'),
    ];
  }

  @override
  Map<String, String> get infoMap {
    final details = <String, String>{};

    // 基底クラスの情報をコピー
    details.addAll(super.infoMap);

    // 線の長さ情報
    final len = length;
    String lengthStr;
    if (len >= 10000) {
      lengthStr = '${(len / 1000).toStringAsFixed(2)} km';
    } else {
      lengthStr = '${len.toStringAsFixed(2)} m';
    }
    details['length'] = lengthStr;

    // 頂点数情報
    details['vertex_count'] = '${line.length}';

    // sub_tableタイムスタンプ範囲
    final timeRange = _getSubTableTimeRange();
    if (timeRange != null) {
      details['timestamp'] = timeRange;
    }

    return details;
  }
  
  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動
  
  @override
  Future<void> updateChildren() async {
    children.clear();
  }

  /// 指定したLineLayerNodeの下に新しい線フィーチャを作成し、LineFeatureNodeインスタンスを返す
  /// DBに保存してrowIdを取得してからFeatureNodeを作成
  static Future<LineFeatureNode?> createIn(
    LayerNode parent,
    List<LatLng> line,
    String name,
    String? description, {
    Map<String, dynamic>? metadata,
  }) async {
    if (parent is! LineLayerNode) return null;
    final gpkgFile = parent.geoPackageFile;
    final layerName = parent.layerName;

    // 属性辞書を作成（カラムの存在確認が必要なため、空の辞書から始める）
    final properties = <String, dynamic>{};
    
    // カラムの存在確認
    final columnNames = await gpkgFile.getColumnNames(layerName, getAll: true);
    final columnSet = columnNames.toSet();
    
    // 存在するカラムのみ値を設定
    if (columnSet.contains('name')) {
      properties['name'] = name;
    }
    if (columnSet.contains('description')) {
      properties['description'] = description;
    }
    if (columnSet.contains('rmaps_metadata') && metadata != null) {
      properties['rmaps_metadata'] = jsonEncode(metadata);
    }

    // DBへの保存を実行してrowIdを取得
    final actualRowId = await gpkgFile.addLineWithAttributes(
      layerName,
      line,
      properties,
    );

    if (actualRowId == null) {
      AppLogger.debug('[ERROR] LineFeatureNode: DB保存に失敗しました - $name');
      return null;
    }

    // rowIdを含むFeatureオブジェクトを作成
    properties['id'] = actualRowId;
    final turfFeature = turf.Feature(
      geometry: TurfConverter.createLineString(line),
      properties: properties,
    );

    // FeatureNodeを作成して親に追加
    final node = LineFeatureNode.fromTurfFeature(turfFeature, parent);
    parent.addChild(node);

    // _featureMapにも登録（updateFeatureAttributeが動作するために必要）
    parent.addFeatureToMap(actualRowId, turfFeature);

    AppLogger.debug('[DEBUG] LineFeatureNode: DB保存完了 - $name (rowId: $actualRowId)');
    return node;
  }

  /// 線フィーチャのジオメトリと属性を更新
  @override
  Future<bool> updateGeometry({
    required String name,
    String? description,
    Map<String, dynamic>? metadata,
    dynamic newGeometry,
  }) async {
    // 新しいジオメトリが渡された場合はそれを使用、なければ現在のlineを使用
    final geometryToUpdate = newGeometry as List<LatLng>? ?? line;

    final success = await geoPackageFile.updateLine(
      layerName,
      rowId,
      geometryToUpdate,
      name: name,
      description: description ?? '',
      metadata: metadata,
    );

    if (success) {
      // 親のMap内のFeatureを更新
      final updatedFeature = turf.Feature(
        geometry: TurfConverter.createLineString(geometryToUpdate),
        properties: {
          ...turfFeature.properties ?? {},
          'id': _rowId,
          'name': name,
          'description': description,
          'rmaps_metadata': metadata,
        },
      );
      parent.addFeatureToMap(_rowId, updatedFeature);
      _markDirty();

      AppLogger.debug('[DEBUG] LineFeatureNode: ジオメトリ更新成功 - $name');
    } else {
      AppLogger.debug('[ERROR] LineFeatureNode: ジオメトリ更新失敗 - $name');
    }

    return success;
  }

  /// 線フィーチャのジオメトリのみを更新（頂点変更）
  Future<bool> updateLine(List<LatLng> newLine) async {
    final success = await geoPackageFile.updateLine(
      layerName,
      rowId,
      newLine,
      name: name,
      description: description ?? '',
      metadata: metadata,
    );

    if (success) {
      // 親のMap内のFeatureのジオメトリを更新
      final updatedFeature = turf.Feature(
        geometry: TurfConverter.createLineString(newLine),
        properties: turfFeature.properties,
      );
      parent.addFeatureToMap(_rowId, updatedFeature);
      _markDirty();
      AppLogger.debug(
        '[DEBUG] LineFeatureNode: 線更新成功 - $name (${newLine.length} vertices)',
      );
    } else {
      AppLogger.debug('[ERROR] LineFeatureNode: 線更新失敗 - $name');
    }

    return success;
  }
}

/// PolygonFeatureNode: 面フィーチャ用
class PolygonFeatureNode extends FeatureNode {
  double? _cachedArea;

  /// rowデータから面フィーチャノードを作成
  PolygonFeatureNode(Map<String, dynamic> row, LayerNode parent)
    : super(row, parent, 'Polygon');

  /// turf_dartのFeatureから面フィーチャノードを作成
  PolygonFeatureNode.fromTurfFeature(super.feature, super.parent)
    : super.fromTurfFeature();

  @override
  void _invalidateCache() {
    super._invalidateCache();
    _cachedArea = null;
  }

  /// 単一のポリゴン（外環＋穴リスト）。Multi の場合は最初のサブポリゴンを返す
  List<List<LatLng>> get polygon {
    final geometry = turfFeature.geometry;
    if (geometry is turf.MultiPolygon) {
      final polys = TurfConverter.multiPolygonToLatlngs(geometry);
      return polys.isNotEmpty ? polys.first : [];
    }
    if (geometry is turf.Polygon) {
      return TurfConverter.polygonToLatlngs(geometry);
    }
    return [];
  }

  /// ポリゴンの座標をpositionリストで取得（外環のみ）
  @override
  List<List<double>> get positions {
    final rings = polygon;
    if (rings.isNotEmpty) {
      return TurfConverter.latlngsToPositions(rings.first);
    }
    return [];
  }

  /// ポリゴンの面積を計算（turf_dartで計算、キャッシュあり）
  double get area {
    if (_isDisposed || parent.isDisposed) return 0.0;
    return _cachedArea ??=
        TurfConverter.calculateArea(turfFeature) ?? 0.0;
  }

  @override
  List<MapEntry<String, String>> get detailEntries {
    final areaM2 = area; // turf_dartで計算された面積（平方メートル）
    String areaStr;
    if (areaM2 >= 10000) {
      areaStr = '${(areaM2 / 10000).toStringAsFixed(3)} ha';
    } else {
      areaStr = '${areaM2.toStringAsFixed(3)} m²';
    }
    // 全リングの頂点数の合計を計算（閉じたリングの最後の点を除く）
    final totalVertices = polygon.fold<int>(0, (sum, ring) {
      if (ring.isEmpty) return sum;
      // 閉じたリングの場合は最後の点を除く（最初と最後が同じため）
      return sum + (ring.length > 1 ? ring.length - 1 : ring.length);
    });
    return [
      ...super.detailEntries,
      MapEntry('area', areaStr),
      MapEntry('vertex_count', '$totalVertices'),
    ];
  }

  @override
  Map<String, String> get infoMap {
    final details = <String, String>{};

    // 基底クラスの情報をコピー
    details.addAll(super.infoMap);

    // 面積情報
    final areaM2 = area; // turf_dartで計算された面積（平方メートル）
    String areaStr;
    if (areaM2 >= 10000) {
      areaStr = '${(areaM2 / 10000).toStringAsFixed(3)} ha';
    } else {
      areaStr = '${areaM2.toStringAsFixed(3)} m²';
    }
    details['area'] = areaStr;

    // 頂点数情報（閉じたリングの最後の点を除く）
    final totalVertices = polygon.fold<int>(0, (sum, ring) {
      if (ring.isEmpty) return sum;
      // 閉じたリングの場合は最後の点を除く（最初と最後が同じため）
      return sum + (ring.length > 1 ? ring.length - 1 : ring.length);
    });
    details['vertex_count'] = '$totalVertices';

    // sub_tableタイムスタンプ範囲
    final timeRange = _getSubTableTimeRange();
    if (timeRange != null) {
      details['timestamp'] = timeRange;
    }

    return details;
  }
  
  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動
  
  @override
  Future<void> updateChildren() async {
    children.clear();
  }

  /// 指定したPolygonLayerNodeの下に新しい面フィーチャを作成し、PolygonFeatureNodeインスタンスを返す
  /// DBへの保存を同期で実行し、実際のrowIdを取得してからFeatureNodeを作成
  static Future<PolygonFeatureNode?> createIn(
    LayerNode parent,
    List<List<LatLng>> polygon,
    String name,
    String? description, {
    Map<String, dynamic>? metadata,
  }) async {
    if (parent is! PolygonLayerNode) return null;
    final gpkgFile = parent.geoPackageFile;
    final layerName = parent.layerName;
    if (polygon.isEmpty) return null;

    // 属性値を辞書として準備（カラムの存在確認が必要なため、空の辞書から始める）
    final attributes = <String, dynamic>{};
    
    // カラムの存在確認
    final columnNames = await gpkgFile.getColumnNames(layerName, getAll: true);
    final columnSet = columnNames.toSet();
    
    // 存在するカラムのみ値を設定
    if (columnSet.contains('name')) {
      attributes['name'] = name;
    }
    if (columnSet.contains('description')) {
      attributes['description'] = description;
    }
    if (columnSet.contains('rmaps_metadata') && metadata != null) {
      attributes['rmaps_metadata'] = jsonEncode(metadata);
    }

    // 新しい辞書ベースAPIを使用してDBへの保存を実行
    final actualRowId = await gpkgFile.addPolygonWithAttributes(
      layerName,
      polygon,
      attributes,
    );

    if (actualRowId == null) {
      AppLogger.debug('[ERROR] PolygonFeatureNode: DB保存に失敗しました - $name');
      return null;
    }

    // DBから実際のrowデータを取得
    final row = await gpkgFile.getFeature(layerName, actualRowId);
    if (row == null) {
      AppLogger.debug('[ERROR] PolygonFeatureNode: 作成後のrow取得に失敗しました - $name');
      return null;
    }

    // rowデータを使用してFeatureNodeを作成
    final node = PolygonFeatureNode(row, parent);
    parent.addChild(node);

    // _featureMapにも登録（updateFeatureAttributeが動作するために必要）
    parent.addFeatureToMap(actualRowId, node.turfFeature);

    AppLogger.debug('[DEBUG] PolygonFeatureNode: DB保存完了 - $name (rowId: $actualRowId)');
    return node;
  }

  /// 面フィーチャのジオメトリと属性を更新
  @override
  Future<bool> updateGeometry({
    required String name,
    String? description,
    Map<String, dynamic>? metadata,
    dynamic newGeometry,
  }) async {
    // 新しいジオメトリが渡された場合はそれを使用、なければ現在のpolygonを使用
    final geometryToUpdate = newGeometry as List<List<LatLng>>? ?? polygon;

    final success = await geoPackageFile.updatePolygon(
      layerName,
      rowId,
      geometryToUpdate,
      name: name,
      description: description ?? '',
      metadata: metadata,
    );

    if (success) {
      // 親のMap内のFeatureを更新
      final updatedFeature = turf.Feature(
        geometry: TurfConverter.createPolygon(geometryToUpdate),
        properties: {
          ...turfFeature.properties ?? {},
          'id': _rowId,
          'name': name,
          'description': description,
          'rmaps_metadata': metadata,
        },
      );
      parent.addFeatureToMap(_rowId, updatedFeature);
      _markDirty();

      AppLogger.debug('[DEBUG] PolygonFeatureNode: ジオメトリ更新成功 - $name');
    } else {
      AppLogger.debug('[ERROR] PolygonFeatureNode: ジオメトリ更新失敗 - $name');
    }

    return success;
  }

  /// 面フィーチャのジオメトリのみを更新（ポリゴン変更）
  Future<bool> updatePolygon(List<List<LatLng>> newPolygon) async {
    final success = await geoPackageFile.updatePolygon(
      layerName,
      rowId,
      newPolygon,
      name: name,
      description: description ?? '',
      metadata: metadata,
    );

    if (success) {
      // 親のMap内のFeatureのジオメトリを更新
      final updatedFeature = turf.Feature(
        geometry: TurfConverter.createPolygon(newPolygon),
        properties: turfFeature.properties,
      );
      parent.addFeatureToMap(_rowId, updatedFeature);
      _markDirty();
      AppLogger.debug(
        '[DEBUG] PolygonFeatureNode: ポリゴン更新成功 - $name (${newPolygon.length} rings)',
      );
    } else {
      AppLogger.debug('[ERROR] PolygonFeatureNode: ポリゴン更新失敗 - $name');
    }

    return success;
  }
}

