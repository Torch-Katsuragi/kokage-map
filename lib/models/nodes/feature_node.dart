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
import '../../i18n/strings.g.dart';
import '../geopackage/feature_repository.dart' show metadataColumn;
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
    if (_isDisposed || parent.isDisposed) return t.featureDetail.disposed;
    return turfFeature.properties?['name'] as String? ?? t.featureDetail.unnamed;
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
    final value = turfFeature.properties?[metadataColumn];
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
    parent.updateFeatureAttribute(_rowId, metadataColumn, value);
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
          final props = (f as Map)['properties'] as Map?;
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

  /// 即座に全ての変更をDBに保存
  Future<void> flushChanges() async {
    await geoPackageFile.flushChanges();
  }

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
        row['name'] as String? ?? t.featureDetail.unnamed,
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
        feature.properties?['name'] as String? ?? t.featureDetail.unnamed,
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

  /// 新しい地物の属性。レイヤに列があるものだけ入れる
  static Future<Map<String, dynamic>> _newAttributes(
    LayerNode parent,
    String name,
    String? description,
    Map<String, dynamic>? metadata,
  ) async {
    final columns = (await parent.geoPackageFile
            .getColumnNames(parent.layerName, getAll: true))
        .toSet();
    return {
      if (columns.contains('name')) 'name': name,
      if (columns.contains('description')) 'description': description,
      if (columns.contains(metadataColumn) && metadata != null)
        metadataColumn: jsonEncode(metadata),
    };
  }

  /// 作った地物を親に入れる（_featureMap にも登録しないと updateFeatureAttribute が効かない）
  static T _adopt<T extends FeatureNode>(T node) {
    node.parent
      ..addChild(node)
      ..addFeatureToMap(node._rowId, node.turfFeature);
    AppLogger.debug('[DEBUG] $T: DB保存完了 - ${node.name} (rowId: ${node._rowId})');
    return node;
  }

  /// DB に形を書けたら親の地物一覧も差し替える。
  /// [properties] を渡さなければ今の属性のまま
  Future<bool> _commitGeometry(
    Future<bool> write,
    turf.GeometryObject geometry, {
    Map<String, dynamic>? properties,
  }) async {
    if (!await write) {
      AppLogger.debug('[ERROR] $runtimeType: 形の更新失敗 - $name');
      return false;
    }
    parent.addFeatureToMap(
      _rowId,
      turf.Feature(
        geometry: geometry,
        properties: properties ?? turfFeature.properties,
      ),
    );
    _markDirty();
    return true;
  }

  Map<String, dynamic> _propertiesWith(
    String name,
    String? description,
    Map<String, dynamic>? metadata,
  ) => {
    ...turfFeature.properties ?? {},
    'id': _rowId,
    'name': name,
    'description': description,
    metadataColumn: metadata,
  };

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
    final properties =
        await FeatureNode._newAttributes(parent, name, description, metadata);
    final rowId = await parent.geoPackageFile
        .addPointWithAttributes(parent.layerName, point, properties);
    if (rowId == null) {
      AppLogger.debug('[ERROR] PointFeatureNode: DB保存に失敗しました - $name');
      return null;
    }
    return FeatureNode._adopt(
      PointFeatureNode.fromTurfFeature(
        turf.Feature(
          geometry: TurfConverter.createPoint(point),
          properties: {...properties, 'id': rowId},
        ),
        parent,
      ),
    );
  }

  Future<bool> _write(
    LatLng shape,
    String name,
    String? description,
    Map<String, dynamic>? metadata,
  ) => geoPackageFile.updatePoint(
    layerName,
    rowId,
    shape,
    name: name,
    description: description ?? '',
    metadata: metadata,
  );

  /// 点フィーチャのジオメトリと属性を更新
  @override
  Future<bool> updateGeometry({
    required String name,
    String? description,
    Map<String, dynamic>? metadata,
    dynamic newGeometry,
  }) {
    final shape = newGeometry as LatLng? ?? point;
    return _commitGeometry(
      _write(shape, name, description, metadata),
      TurfConverter.createPoint(shape),
      properties: _propertiesWith(name, description, metadata),
    );
  }

  /// 点フィーチャのジオメトリのみを更新（位置変更）
  Future<bool> updateLocation(LatLng shape) => _commitGeometry(
    _write(shape, name, description, metadata),
    TurfConverter.createPoint(shape),
  );
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

  /// 線の長さを計算（turf_dartで計算、キャッシュあり）
  double get length {
    if (_isDisposed || parent.isDisposed) return 0.0;
    return _cachedLength ??=
        TurfConverter.calculateLength(turfFeature) ?? 0.0;
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
    final properties =
        await FeatureNode._newAttributes(parent, name, description, metadata);
    final rowId = await parent.geoPackageFile
        .addLineWithAttributes(parent.layerName, line, properties);
    if (rowId == null) {
      AppLogger.debug('[ERROR] LineFeatureNode: DB保存に失敗しました - $name');
      return null;
    }
    return FeatureNode._adopt(
      LineFeatureNode.fromTurfFeature(
        turf.Feature(
          geometry: TurfConverter.createLineString(line),
          properties: {...properties, 'id': rowId},
        ),
        parent,
      ),
    );
  }

  Future<bool> _write(
    List<LatLng> shape,
    String name,
    String? description,
    Map<String, dynamic>? metadata,
  ) => geoPackageFile.updateLine(
    layerName,
    rowId,
    shape,
    name: name,
    description: description ?? '',
    metadata: metadata,
  );

  /// 線フィーチャのジオメトリと属性を更新
  @override
  Future<bool> updateGeometry({
    required String name,
    String? description,
    Map<String, dynamic>? metadata,
    dynamic newGeometry,
  }) {
    final shape = newGeometry as List<LatLng>? ?? line;
    return _commitGeometry(
      _write(shape, name, description, metadata),
      TurfConverter.createLineString(shape),
      properties: _propertiesWith(name, description, metadata),
    );
  }

  /// 線フィーチャのジオメトリのみを更新（頂点変更）
  Future<bool> updateLine(List<LatLng> shape) => _commitGeometry(
    _write(shape, name, description, metadata),
    TurfConverter.createLineString(shape),
  );
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

  /// ポリゴンの面積を計算（turf_dartで計算、キャッシュあり）
  double get area {
    if (_isDisposed || parent.isDisposed) return 0.0;
    return _cachedArea ??=
        TurfConverter.calculateArea(turfFeature) ?? 0.0;
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
  /// 面は保存した行を読み直して作る（既定値の入った列も持たせる）
  static Future<PolygonFeatureNode?> createIn(
    LayerNode parent,
    List<List<LatLng>> polygon,
    String name,
    String? description, {
    Map<String, dynamic>? metadata,
  }) async {
    if (parent is! PolygonLayerNode) return null;
    if (polygon.isEmpty) return null;
    final gpkgFile = parent.geoPackageFile;
    final attributes =
        await FeatureNode._newAttributes(parent, name, description, metadata);
    final rowId = await gpkgFile.addPolygonWithAttributes(
      parent.layerName,
      polygon,
      attributes,
    );
    if (rowId == null) {
      AppLogger.debug('[ERROR] PolygonFeatureNode: DB保存に失敗しました - $name');
      return null;
    }
    final row = await gpkgFile.getFeature(parent.layerName, rowId);
    if (row == null) {
      AppLogger.debug('[ERROR] PolygonFeatureNode: 作成後のrow取得に失敗しました - $name');
      return null;
    }
    return FeatureNode._adopt(PolygonFeatureNode(row, parent));
  }

  Future<bool> _write(
    List<List<LatLng>> shape,
    String name,
    String? description,
    Map<String, dynamic>? metadata,
  ) => geoPackageFile.updatePolygon(
    layerName,
    rowId,
    shape,
    name: name,
    description: description ?? '',
    metadata: metadata,
  );

  /// 面フィーチャのジオメトリと属性を更新
  @override
  Future<bool> updateGeometry({
    required String name,
    String? description,
    Map<String, dynamic>? metadata,
    dynamic newGeometry,
  }) {
    final shape = newGeometry as List<List<LatLng>>? ?? polygon;
    return _commitGeometry(
      _write(shape, name, description, metadata),
      TurfConverter.createPolygon(shape),
      properties: _propertiesWith(name, description, metadata),
    );
  }

  /// 面フィーチャのジオメトリのみを更新（ポリゴン変更）
  Future<bool> updatePolygon(List<List<LatLng>> shape) => _commitGeometry(
    _write(shape, name, description, metadata),
    TurfConverter.createPolygon(shape),
  );
}
