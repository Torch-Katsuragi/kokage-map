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
// Root Maps: MapLibre GeoJSONソース直接管理
// layersプロパティを経由せず、StyleController経由でソース/レイヤを管理
// データ変更時のみupdateGeoJsonSourceを呼び出し、OOMを防止
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:maplibre/maplibre.dart' as ml;

import 'package:supercluster/supercluster.dart';
import '../core/constants.dart';
import '../utils/app_logger.dart';
import '../utils/map_icon_generator.dart';

/// スタイルグループ1つぶんの、解決済みの見た目。
///
/// View（またはレイヤ）に固有のスタイルが付いているぶんだけ作られる。
/// グローバル設定との合成は呼び出し側（`map_page`）が済ませてから渡す。
/// ここは「与えられた値でレイヤを積む」だけにして、設定の解決規則を持ち込まない。
class MapStyleGroup {
  const MapStyleGroup({
    required this.key,
    required this.fillHex,
    required this.fillOpacity,
    required this.outlineHex,
    required this.outlineOpacity,
    required this.borderWidth,
    required this.lineHex,
    required this.lineWidth,
    required this.pointHex,
    required this.pointSize,
  });

  /// フィーチャの `k-style` 属性と突き合わせるキー（View のキー）
  final String key;

  final String fillHex;
  final double fillOpacity;
  final String outlineHex;
  final double outlineOpacity;
  final double borderWidth;
  final String lineHex;
  final double lineWidth;
  final String pointHex;
  final double pointSize;

  @override
  bool operator ==(Object other) =>
      other is MapStyleGroup &&
      other.key == key &&
      other.fillHex == fillHex &&
      other.fillOpacity == fillOpacity &&
      other.outlineHex == outlineHex &&
      other.outlineOpacity == outlineOpacity &&
      other.borderWidth == borderWidth &&
      other.lineHex == lineHex &&
      other.lineWidth == lineWidth &&
      other.pointHex == pointHex &&
      other.pointSize == pointSize;

  @override
  int get hashCode => Object.hash(key, fillHex, fillOpacity, outlineHex,
      outlineOpacity, borderWidth, lineHex, lineWidth, pointHex, pointSize);
}

/// GeoJSONソース/スタイルレイヤをStyleController経由で直接管理
/// layers プロパティによる毎rebuild時のGeoJSONシリアライズを回避
class MapSourceManager {
  ml.StyleController? _style;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  // 前回送信したGeoJSON文字列（変更検知用）
  final Map<String, String> _lastData = {};

  bool get isInitialized => _initialized;

  // ソースID定数
  static const kPolygons = 'k-polygons';
  static const kPolygonsSel = 'k-polygons-sel';
  static const kLines = 'k-lines';
  static const kLinesSel = 'k-lines-sel';
  static const kPoints = 'k-points';
  static const kPointsSel = 'k-points-sel';
  static const kClusters = 'k-clusters';
  static const kGpsTrack = 'k-gps-track';
  static const kImages = 'k-images';
  static const kImagesSel = 'k-images-sel';
  static const kImageClusters = 'k-image-clusters';
  static const kLineVertices = 'k-line-vertices';
  static const kLineVerticesSel = 'k-line-vertices-sel';
  static const kPolyVertices = 'k-poly-vertices';
  static const kPolyVerticesSel = 'k-poly-vertices-sel';

  // レイヤID定数
  static const kPolygonsFill = 'k-polygons-fill';
  static const kPolygonsOutline = 'k-polygons-outline';
  static const kPolygonsSelFill = 'k-polygons-sel-fill';
  static const kPolygonsSelOutline = 'k-polygons-sel-outline';
  static const kLinesLine = 'k-lines-line';
  static const kLinesSelLine = 'k-lines-sel-line';
  static const kPolyVerticesCircle = 'k-poly-vertices-circle';
  static const kPolyVerticesSelCircle = 'k-poly-vertices-sel-circle';
  static const kLineVerticesCircle = 'k-line-vertices-circle';
  static const kLineVerticesSelCircle = 'k-line-vertices-sel-circle';
  static const kPointsCircle = 'k-points-circle';
  static const kPointsSelCircle = 'k-points-sel-circle';
  static const kClusterCircle = 'k-cluster-circle';
  static const kClusterCount = 'k-cluster-count';
  static const kGpsTrackLine = 'k-gps-track-line';
  static const kImagesSymbol = 'k-images-symbol';
  static const kImagesSelSymbol = 'k-images-sel-symbol';
  static const kImageClusterCircle = 'k-image-cluster-circle';
  static const kImageClusterCount = 'k-image-cluster-count';
  static const kImageClusterName = 'k-image-cluster-name';

  // アイコン画像ID
  static const _iconPhotoMarker = 'photo-marker';
  static const _iconPhotoMarkerSel = 'photo-marker-sel';
  static const _iconPhotoMarkerNoDir = 'photo-marker-no-dir';
  static const _iconPhotoMarkerNoDirSel = 'photo-marker-no-dir-sel';

  /// フィーチャに載せる「どのスタイルグループのものか」の属性名。
  ///
  /// > [!IMPORTANT] グループが1つも無ければ、この属性は載せない
  /// > 全レイヤのフィーチャは共有ソース（`k-polygons` 等）に流し込まれる。
  /// > グループが無い＝固有スタイルが1つも無い状態では、フィルタも付けないので
  /// > 描画経路は View 導入前とまったく同じになる。既存プロジェクトの
  /// > 見え方を変えないための保険。
  static const kStyleProp = 'k-style';

  /// ラベル文字列を載せる属性名（`FeatureGeoJsonInput.labelPropKey` と同じ）
  static const kLabelProp = 'k-label';
  static const kPointsLabel = 'k-points-label';
  static const kLinesLabel = 'k-lines-label';
  static const kPolygonsLabel = 'k-polygons-label';

  /// スタイルグループ。**並び順が z順**（View の並び）。
  List<MapStyleGroup> _styleGroups = const [];

  /// グループぶんに増やしたレイヤのID（削除用）
  final List<String> _groupLayerIds = [];

  List<MapStyleGroup> get styleGroups => _styleGroups;

  static const _emptyGeoJson =
      '{"type":"FeatureCollection","features":[]}';

  // Isolate化の閾値
  static const _isolateThreshold = 500;

  static const _allSourceIds = [
    kPolygons, kPolygonsSel,
    kLines, kLinesSel,
    kLineVertices, kLineVerticesSel,
    kPolyVertices, kPolyVerticesSel,
    kPoints, kPointsSel,
    kClusters,
    kGpsTrack,
    kImages, kImagesSel,
    kImageClusters,
  ];

  // 描画順: polygon → line → gpsTrack → vertices → clusters → points → imageClusters → images
  static const _allLayerIds = [
    kPolygonsFill, kPolygonsOutline,
    kPolygonsSelFill, kPolygonsSelOutline,
    kLinesLine, kLinesSelLine, kGpsTrackLine,
    kPolyVerticesCircle, kPolyVerticesSelCircle,
    kLineVerticesCircle, kLineVerticesSelCircle,
    kClusterCircle, kClusterCount,
    kPointsCircle, kPointsSelCircle,
    kPolygonsLabel, kLinesLabel, kPointsLabel,
    kImageClusterCircle, kImageClusterCount, kImageClusterName,
    kImagesSymbol, kImagesSelSymbol,
  ];

  // --------------------------------------------------
  // クラスタリング
  // --------------------------------------------------
  bool _clusterEnabled = true;
  int _clusterRadius = 25;
  int _clusterMaxZoom = 18;
  int _lastClusterIntZoom = -1;

  // Supercluster インデックス（不変版: rebuild時に丸ごと再生成）
  SuperclusterImmutable<_IndexedPoint>? _clusterIndex;
  SuperclusterImmutable<_IndexedPoint>? _imageClusterIndex;
  int _lastImageClusterIntZoom = -1;

  // 生ポイントデータ保持（クラスタリング用）
  List<geo.Feature<geo.Point>> _rawPoints = [];
  List<geo.Feature<geo.Point>> _rawImages = [];

  /// クラスタリング設定を更新
  void configureClustering({
    required bool enabled,
    required int radius,
    required int maxZoom,
  }) {
    final changed = _clusterEnabled != enabled ||
        _clusterRadius != radius ||
        _clusterMaxZoom != maxZoom;
    _clusterEnabled = enabled;
    _clusterRadius = radius;
    _clusterMaxZoom = maxZoom;
    if (changed) {
      if (_rawPoints.isNotEmpty) _rebuildClusterIndex();
      if (_rawImages.isNotEmpty) _rebuildImageClusterIndex();
    }
  }

  /// クラスタインデックスを再構築
  void _rebuildClusterIndex() {
    if (!_clusterEnabled || _rawPoints.isEmpty) {
      _clusterIndex = null;
      return;
    }
    final indexed = <_IndexedPoint>[];
    for (var i = 0; i < _rawPoints.length; i++) {
      final geom = _rawPoints[i].geometry;
      if (geom == null) continue;
      final coord = geom.position;
      indexed.add(_IndexedPoint(
        index: i,
        longitude: coord.x.toDouble(),
        latitude: coord.y.toDouble(),
      ));
    }
    _clusterIndex = SuperclusterImmutable<_IndexedPoint>(
      getX: (p) => p.longitude,
      getY: (p) => p.latitude,
      radius: _clusterRadius,
      maxZoom: _clusterMaxZoom,
    )..load(indexed);
    _lastClusterIntZoom = -1;
  }

  /// ImageNodeクラスタインデックスを再構築
  void _rebuildImageClusterIndex() {
    if (!_clusterEnabled || _rawImages.isEmpty) {
      _imageClusterIndex = null;
      return;
    }
    final indexed = <_IndexedPoint>[];
    for (var i = 0; i < _rawImages.length; i++) {
      final geom = _rawImages[i].geometry;
      if (geom == null) continue;
      final coord = geom.position;
      indexed.add(_IndexedPoint(
        index: i,
        longitude: coord.x.toDouble(),
        latitude: coord.y.toDouble(),
      ));
    }
    _imageClusterIndex = SuperclusterImmutable<_IndexedPoint>(
      getX: (p) => p.longitude,
      getY: (p) => p.latitude,
      radius: _clusterRadius,
      maxZoom: _clusterMaxZoom,
    )..load(indexed);
    _lastImageClusterIntZoom = -1;
  }

  /// 現在のズームレベルでクラスタ/個別ポイントを再生成しソースに送信
  void refreshClusters(double zoom) {
    if (!_initialized) return;
    _refreshPointClusters(zoom);
    _refreshImageClusters(zoom);
  }

  /// クラスタに入らなかった1点ぶんの GeoJSON を組み立てる。
  ///
  /// > [!WARNING] 元のフィーチャの属性は、ここで明示的に写さないと落ちる
  /// > クラスタリングが有効なとき、`k-points` はこの関数の出力で作り直される。
  /// > スタイルグループのキー（[kStyleProp]）を写し忘れると、
  /// > **クラスタリングが有効なときだけ View のスタイルが効かない**という
  /// > 分かりにくい壊れ方をする（2026-08-26 に実際に踏んだ）。
  @visibleForTesting
  static String clusterPointJson(
    double longitude,
    double latitude,
    Map<String, dynamic> properties,
  ) {
    final name = properties['name'] ?? '';
    final styleKey = properties[kStyleProp];
    return '{"type":"Feature","geometry":{"type":"Point",'
        '"coordinates":[$longitude,$latitude]},'
        '"properties":{"name":${jsonEncode(name)}'
        '${styleKey == null ? '' : ',"$kStyleProp":${jsonEncode(styleKey)}'}}}';
  }

  /// Pointクラスタリング
  void _refreshPointClusters(double zoom) {
    if (!_clusterEnabled || _clusterIndex == null) {
      _updateRaw(kClusters, _emptyGeoJson);
      return;
    }

    final intZoom = zoom.floor();
    if (intZoom == _lastClusterIntZoom) return;
    _lastClusterIntZoom = intZoom;

    final results = _clusterIndex!.search(-180, -90, 180, 90, intZoom);

    final clusterBuf = StringBuffer();
    final pointBuf = StringBuffer();
    var clusterCount = 0;
    var pointCount = 0;

    for (final item in results) {
      item.handle(
        cluster: (cluster) {
          if (clusterCount > 0) clusterBuf.write(',');
          clusterBuf.write(
            '{"type":"Feature","geometry":{"type":"Point",'
            '"coordinates":[${cluster.longitude},${cluster.latitude}]},'
            '"properties":{"point_count":${cluster.childPointCount},'
            '"point_count_abbreviated":"${_abbreviate(cluster.childPointCount)}"}}',
          );
          clusterCount++;
        },
        point: (point) {
          if (pointCount > 0) pointBuf.write(',');
          final raw = _rawPoints[point.originalPoint.index];
          pointBuf.write(clusterPointJson(
            point.originalPoint.longitude,
            point.originalPoint.latitude,
            raw.properties,
          ));
          pointCount++;
        },
      );
    }

    _updateRaw(kClusters,
        '{"type":"FeatureCollection","features":[$clusterBuf]}');
    _updateRaw(kPoints,
        '{"type":"FeatureCollection","features":[$pointBuf]}');
  }

  /// ImageNodeクラスタリング
  void _refreshImageClusters(double zoom) {
    if (!_clusterEnabled || _imageClusterIndex == null) {
      _updateRaw(kImageClusters, _emptyGeoJson);
      return;
    }

    final intZoom = zoom.floor();
    if (intZoom == _lastImageClusterIntZoom) return;
    _lastImageClusterIntZoom = intZoom;

    final results = _imageClusterIndex!.search(-180, -90, 180, 90, intZoom);

    final clusterBuf = StringBuffer();
    final imageBuf = StringBuffer();
    var clusterCount = 0;
    var imageCount = 0;

    for (final item in results) {
      item.handle(
        cluster: (cluster) {
          // クラスタ内の最新ファイル名を取得
          final newestName = _findNewestImageName(cluster);
          if (clusterCount > 0) clusterBuf.write(',');
          clusterBuf.write(
            '{"type":"Feature","geometry":{"type":"Point",'
            '"coordinates":[${cluster.longitude},${cluster.latitude}]},'
            '"properties":{"point_count":${cluster.childPointCount},'
            '"point_count_abbreviated":"${_abbreviate(cluster.childPointCount)}"'
            ',"name":${jsonEncode(newestName)}}}',
          );
          clusterCount++;
        },
        point: (point) {
          if (imageCount > 0) imageBuf.write(',');
          final raw = _rawImages[point.originalPoint.index];
          final name = raw.properties['name'] ?? '';
          final dir = raw.properties['direction'];
          final hasDir = dir != null;
          imageBuf.write(
            '{"type":"Feature","geometry":{"type":"Point",'
            '"coordinates":[${point.originalPoint.longitude},${point.originalPoint.latitude}]},'
            '"properties":{"name":${jsonEncode(name)},'
            '"has_direction":$hasDir'
            '${hasDir ? ',"direction":$dir' : ''}}}',
          );
          imageCount++;
        },
      );
    }

    _updateRaw(kImageClusters,
        '{"type":"FeatureCollection","features":[$clusterBuf]}');
    _updateRaw(kImages,
        '{"type":"FeatureCollection","features":[$imageBuf]}');
  }

  /// クラスタ内で最も taken_at が新しいポイントの name を返す
  String _findNewestImageName(LayerCluster cluster) {
    final immCluster = cluster as ImmutableLayerCluster;
    final leaves = _imageClusterIndex!.pointsWithin(
      immCluster.id,
      limit: cluster.childPointCount,
    );
    String newestName = '';
    int newestTs = -1;
    for (final leaf in leaves) {
      final props = _rawImages[leaf.index].properties;
      final ts = props['taken_at'] as int? ?? 0;
      if (ts > newestTs) {
        newestTs = ts;
        newestName = (props['name'] ?? '') as String;
      }
    }
    return newestName;
  }

  /// 数値を略記（1000 → 1k, 10000 → 10k）
  static String _abbreviate(int n) {
    if (n < 1000) return '$n';
    if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000).round()}k';
  }

  // --------------------------------------------------
  // 初期化
  // --------------------------------------------------

  /// スタイル（MapLibre）が外れた。次の [initialize] で全部登録し直す
  void detachStyle() {
    _style = null;
    _initialized = false;
    _initCompleter = null;
    _lastData.clear();
  }

  /// StyleController にソースとレイヤを一括登録（二重実行防止）
  Future<void> initialize(ml.StyleController style) async {
    if (_initialized) return;

    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    try {
      _style = style;

      // アイコン画像を登録（4枚: 通常/選択 × 方向あり/なし）
      await _registerPhotoIcons(style);

      // 全ソースを空GeoJSONで登録
      for (final id in _allSourceIds) {
        await style.addSource(
          ml.GeoJsonSource(id: id, data: _emptyGeoJson),
        );
        _lastData[id] = _emptyGeoJson;
      }

      // デフォルトスタイルでレイヤを登録（basemap-layerの上に積む）
      await _addDefaultLayers(style);

      _initialized = true;
      AppLogger.debug('[MapSourceManager] initialized: ${_allSourceIds.length} sources, ${_allLayerIds.length} layers');
      _initCompleter!.complete();
    } catch (e, stack) {
      _initCompleter!.completeError(e, stack);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  /// 写真マーカーアイコンをMapLibreに登録（バッファ競合回避のため1枚ずつ生成・登録）
  Future<void> _registerPhotoIcons(ml.StyleController style) async {
    const normalColor = Colors.purple;
    const selColor = Colors.orange;
    const entries = <(String, Future<Uint8List> Function(Color))>[
      (_iconPhotoMarker, MapIconGenerator.generatePhotoMarker),
      (_iconPhotoMarkerSel, MapIconGenerator.generatePhotoMarkerSel),
      (_iconPhotoMarkerNoDir, MapIconGenerator.generatePhotoMarkerNoDir),
      (_iconPhotoMarkerNoDirSel, MapIconGenerator.generatePhotoMarkerNoDirSel),
    ];
    for (final (id, gen) in entries) {
      final color = id.contains('-sel') ? selColor : normalColor;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final bytes = await gen(color);
          await style.addImage(id, bytes);
          break;
        } catch (e) {
          AppLogger.debug('[MapSourceManager] icon registration retry ($id): $e');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }

  /// デフォルトのpaint設定でスタイルレイヤを追加
  Future<void> _addDefaultLayers(ml.StyleController style) async {
    // ポリゴン塗りつぶし（通常）
    await style.addLayer(const ml.FillStyleLayer(
      id: kPolygonsFill,
      sourceId: kPolygons,
      paint: {
        'fill-color': '#4CAF50',
        'fill-opacity': 0.3,
      },
    ));
    // ポリゴン輪郭線（通常） — fill-outline-colorは1px固定のため別途LineStyleLayerで描画
    await style.addLayer(const ml.LineStyleLayer(
      id: kPolygonsOutline,
      sourceId: kPolygons,
      paint: {
        'line-color': '#388E3C',
        'line-width': 2.0,
      },
    ));
    // ポリゴン塗りつぶし（選択）
    await style.addLayer(const ml.FillStyleLayer(
      id: kPolygonsSelFill,
      sourceId: kPolygonsSel,
      paint: {
        'fill-color': '#FF0000',
        'fill-opacity': 0.5,
      },
    ));
    // ポリゴン輪郭線（選択）
    await style.addLayer(const ml.LineStyleLayer(
      id: kPolygonsSelOutline,
      sourceId: kPolygonsSel,
      paint: {
        'line-color': '#FF0000',
        'line-width': 3.0,
      },
    ));
    // ライン（通常）
    await style.addLayer(const ml.LineStyleLayer(
      id: kLinesLine,
      sourceId: kLines,
      paint: {
        'line-color': '#2196F3',
        'line-width': 2.0,
      },
    ));
    // ライン（選択）
    await style.addLayer(const ml.LineStyleLayer(
      id: kLinesSelLine,
      sourceId: kLinesSel,
      paint: {
        'line-color': '#FF0000',
        'line-width': 4.0,
      },
    ));
    // GPS軌跡（ラインと同等の優先度）
    await style.addLayer(ml.LineStyleLayer(
      id: kGpsTrackLine,
      sourceId: kGpsTrack,
      paint: {
        'line-color': _colorToHex(MapColors.trackingRoute),
        'line-width': 3.0,
      },
    ));
    // ポリゴン頂点（通常）
    await style.addLayer(const ml.CircleStyleLayer(
      id: kPolyVerticesCircle,
      sourceId: kPolyVertices,
      paint: {
        'circle-radius': 4.0,
        'circle-color': '#388E3C',
        'circle-stroke-width': 1.0,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // ポリゴン頂点（選択）
    await style.addLayer(const ml.CircleStyleLayer(
      id: kPolyVerticesSelCircle,
      sourceId: kPolyVerticesSel,
      paint: {
        'circle-radius': 5.0,
        'circle-color': '#FF0000',
        'circle-stroke-width': 1.0,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // ライン頂点（通常）
    await style.addLayer(const ml.CircleStyleLayer(
      id: kLineVerticesCircle,
      sourceId: kLineVertices,
      paint: {
        'circle-radius': 4.0,
        'circle-color': '#2196F3',
        'circle-stroke-width': 1.0,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // ライン頂点（選択）
    await style.addLayer(const ml.CircleStyleLayer(
      id: kLineVerticesSelCircle,
      sourceId: kLineVerticesSel,
      paint: {
        'circle-radius': 5.0,
        'circle-color': '#FF0000',
        'circle-stroke-width': 1.0,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // クラスタ円（ポイント数に応じてサイズを段階的に変化、色はポイント設定に準拠）
    // デフォルトのpointSize=6.0に合わせたサイズ
    await style.addLayer(const ml.CircleStyleLayer(
      id: kClusterCircle,
      sourceId: kClusters,
      paint: {
        'circle-color': '#2196F3',
        'circle-radius': <Object>[
          'step', ['get', 'point_count'],
          7.2,
          10, 9.0,
          50, 10.8,
          200, 13.8,
        ],
        'circle-stroke-width': 1.5,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // クラスタ数テキスト
    await style.addLayer(const ml.SymbolStyleLayer(
      id: kClusterCount,
      sourceId: kClusters,
      layout: {
        'text-field': '{point_count_abbreviated}',
        'text-font': ['Open Sans Semibold'],
        'text-size': 9.6,
        'text-allow-overlap': true,
      },
      paint: {
        'text-color': '#000000',
        'text-halo-color': '#FFFFFF',
        'text-halo-width': 1.5,
      },
    ));
    // ポイント（通常） — CircleStyleLayerで高速描画
    await style.addLayer(const ml.CircleStyleLayer(
      id: kPointsCircle,
      sourceId: kPoints,
      paint: {
        'circle-radius': 6.0,
        'circle-color': '#2196F3',
        'circle-stroke-width': 1.5,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // ポイント（選択）
    await style.addLayer(const ml.CircleStyleLayer(
      id: kPointsSelCircle,
      sourceId: kPointsSel,
      paint: {
        'circle-radius': 9.0,
        'circle-color': '#FF0000',
        'circle-stroke-width': 2.0,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // ラベル（見た目は updateLayerStyles で設定値に置き換わる）
    for (final l in _labelLayers(
      size: 12, colorHex: '#000000', haloHex: '#FFFFFF', opacity: 1,
    )) {
      await style.addLayer(l);
    }

    // --- ImageNode レイヤ ---
    // ImageNodeクラスタ円
    await style.addLayer(const ml.CircleStyleLayer(
      id: kImageClusterCircle,
      sourceId: kImageClusters,
      paint: {
        'circle-color': '#9C27B0',
        'circle-radius': <Object>[
          'step', ['get', 'point_count'],
          7.0, 10, 9.0, 50, 11.0, 200, 14.0,
        ],
        'circle-stroke-width': 1.5,
        'circle-stroke-color': '#FFFFFF',
      },
    ));
    // ImageNodeクラスタ数テキスト（円の中央）
    await style.addLayer(const ml.SymbolStyleLayer(
      id: kImageClusterCount,
      sourceId: kImageClusters,
      layout: {
        'text-field': '{point_count_abbreviated}',
        'text-font': ['Open Sans Semibold'],
        'text-size': 10.0,
      },
      paint: {
        'text-color': '#000000',
        'text-halo-color': '#FFFFFF',
        'text-halo-width': 1.5,
      },
    ));
    // ImageNodeクラスタ最新ファイル名（円の右横）
    await style.addLayer(const ml.SymbolStyleLayer(
      id: kImageClusterName,
      sourceId: kImageClusters,
      layout: {
        'text-field': <Object>['get', 'name'],
        'text-font': ['Open Sans Semibold'],
        'text-size': 10.0,
        'text-anchor': 'left',
        'text-offset': <Object>[1.2, 0],
        'text-max-width': 100.0,
      },
      paint: {
        'text-color': '#000000',
        'text-halo-color': '#FFFFFF',
        'text-halo-width': 1.5,
      },
    ));
    // ImageNode（通常）
    await style.addLayer(const ml.SymbolStyleLayer(
      id: kImagesSymbol,
      sourceId: kImages,
      layout: {
        'icon-image': <Object>[
          'case', ['get', 'has_direction'],
          _iconPhotoMarker, _iconPhotoMarkerNoDir,
        ],
        'icon-rotate': <Object>['coalesce', ['get', 'direction'], 0],
        'icon-rotation-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-size': 0.7,
        'text-field': <Object>['get', 'name'],
        'text-font': ['Open Sans Semibold'],
        'text-size': 12.0,
        'text-anchor': 'left',
        'text-offset': <Object>[1.0, 0],
        'text-max-width': 100.0,
        'text-optional': true,
      },
      paint: {
        'text-color': '#000000',
        'text-halo-color': '#FFFFFF',
        'text-halo-width': 1.5,
      },
    ));
    // ImageNode（選択）
    await style.addLayer(const ml.SymbolStyleLayer(
      id: kImagesSelSymbol,
      sourceId: kImagesSel,
      layout: {
        'icon-image': <Object>[
          'case', ['get', 'has_direction'],
          _iconPhotoMarkerSel, _iconPhotoMarkerNoDirSel,
        ],
        'icon-rotate': <Object>['coalesce', ['get', 'direction'], 0],
        'icon-rotation-alignment': 'map',
        'icon-allow-overlap': true,
        'icon-size': 1.0,
        'text-field': <Object>['get', 'name'],
        'text-font': ['Open Sans Semibold'],
        'text-size': 13.0,
        'text-anchor': 'left',
        'text-offset': <Object>[1.0, 0],
        'text-max-width': 100.0,
        'text-optional': true,
      },
      paint: {
        'text-color': '#FF9800',
        'text-halo-color': '#FFFFFF',
        'text-halo-width': 1.5,
      },
    ));
  }

  // --------------------------------------------------
  // データ更新メソッド（変更時のみネイティブに送信）
  // --------------------------------------------------

  /// GeoJSONソースを更新（変更がなければスキップ）
  void _updateRaw(String sourceId, String geoJson) {
    if (!_initialized || _style == null) return;
    if (_lastData[sourceId] == geoJson) return;
    _lastData[sourceId] = geoJson;
    _style!.updateGeoJsonSource(id: sourceId, data: geoJson);
  }

  /// Feature リストからGeoJSONを生成して更新
  /// ポイント(kPoints)の場合はクラスタインデックスも更新
  Future<void> updateFeatures<T extends geo.Geometry>(
    String sourceId,
    List<geo.Feature<T>> features,
  ) async {
    if (!_initialized) return;

    // kPointsの場合: クラスタリング用にrawデータを保持
    if (sourceId == kPoints) {
      _rawPoints = features.cast<geo.Feature<geo.Point>>();
      if (_clusterEnabled) {
        _rebuildClusterIndex();
        return;
      }
    }

    // kImagesの場合: ImageNodeクラスタリング用にrawデータを保持
    if (sourceId == kImages) {
      _rawImages = features.cast<geo.Feature<geo.Point>>();
      if (_clusterEnabled) {
        _rebuildImageClusterIndex();
        return;
      }
    }

    if (features.isEmpty) {
      _updateRaw(sourceId, _emptyGeoJson);
      return;
    }
    final geoJson = features.length > _isolateThreshold
        ? await _serializeInIsolate(features)
        : geo.FeatureCollection(features).toText();
    _updateRaw(sourceId, geoJson);
  }

  /// GPS軌跡を更新
  void updateGpsTrack(List<geo.Position> points) {
    if (!_initialized || points.length < 2) {
      _updateRaw(kGpsTrack, _emptyGeoJson);
      return;
    }
    final feature = geo.Feature(
      geometry: geo.LineString.from(points),
    );
    final geoJson = geo.FeatureCollection([feature]).toText();
    _updateRaw(kGpsTrack, geoJson);
  }

  // --------------------------------------------------
  // スタイル更新（設定変更時にレイヤを再構築）
  // --------------------------------------------------

  /// ユーザー設定のスタイルをレイヤ再登録で反映
  /// removeLayer+addLayerは全プラットフォームで動作する安全な方式
  /// スタイルグループを差し替える。変わっていれば true（呼び出し側が再描画する）。
  ///
  /// 空リストを渡すと View 導入前と同じ描画に戻る。
  bool setStyleGroups(List<MapStyleGroup> groups) {
    if (_listEquals(_styleGroups, groups)) return false;
    _styleGroups = List.unmodifiable(groups);
    return true;
  }

  static bool _listEquals(List<MapStyleGroup> a, List<MapStyleGroup> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// グループに属さないフィーチャだけを通すフィルタ。
  ///
  /// `k-style` が無いフィーチャ（属性を載せていない場合）も通す必要があるので
  /// `coalesce` で空文字に寄せる。
  List<Object>? get _defaultFilter =>
      _styleGroups.isEmpty
          ? null
          : <Object>[
            '==',
            <Object>['coalesce', <Object>['get', kStyleProp], ''],
            '',
          ];

  /// ラベルのレイヤ（面・線・点）。`k-label` を持たないフィーチャは text-field が
  /// 空になるので何も出ない。面は重心に、線は線に沿って、点はマーカーの下に置く。
  ///
  /// ⚠ `filter:` を付けてはいけない。maplibre_android の filter は JNI で
  ///   `Expression$Converter` を使い、release（R8）でクラスが削られて
  ///   `addLayer` が例外になる（2026-09-07 実機で全レイヤが消えた）。
  ///   グループレイヤの filter は proguard の keep で守っている
  List<ml.SymbolStyleLayer> _labelLayers({
    required double size,
    required String colorHex,
    required String haloHex,
    required double opacity,
  }) {
    final paint = <String, Object>{
      'text-color': colorHex,
      'text-halo-color': haloHex,
      'text-halo-width': 1.5,
      'text-opacity': opacity,
    };
    const font = <Object>['Open Sans Semibold'];
    return [
      ml.SymbolStyleLayer(
        id: kPolygonsLabel, sourceId: kPolygons,
        layout: {
          'text-field': <Object>['get', kLabelProp],
          'text-font': font, 'text-size': size, 'text-max-width': 12.0,
        },
        paint: paint),
      ml.SymbolStyleLayer(
        id: kLinesLabel, sourceId: kLines,
        layout: {
          'symbol-placement': 'line',
          'text-field': <Object>['get', kLabelProp],
          'text-font': font, 'text-size': size,
        },
        paint: paint),
      ml.SymbolStyleLayer(
        id: kPointsLabel, sourceId: kPoints,
        layout: {
          'text-field': <Object>['get', kLabelProp],
          'text-font': font, 'text-size': size,
          'text-anchor': 'top', 'text-offset': <Object>[0, 0.9],
          'text-optional': true, 'text-max-width': 12.0,
        },
        paint: paint),
    ];
  }

  List<Object> _groupFilter(MapStyleGroup group) => <Object>[
    '==',
    <Object>['get', kStyleProp],
    group.key,
  ];

  /// グループぶんのレイヤを積む。
  ///
  /// 同じソースを共有し、フィルタとpaintだけを変える。
  /// **データ転送は増えない**（ソースは1本のまま）。
  Future<void> _addGroupLayers(ml.StyleController s) async {
    _groupLayerIds.clear();
    for (var i = 0; i < _styleGroups.length; i++) {
      final g = _styleGroups[i];
      final filter = _groupFilter(g);
      Future<void> add(ml.StyleLayer layer) async {
        await s.addLayer(layer);
        _groupLayerIds.add(layer.id);
      }

      await add(ml.FillStyleLayer(
        id: '$kPolygonsFill#$i', sourceId: kPolygons, filter: filter,
        paint: {'fill-color': g.fillHex, 'fill-opacity': g.fillOpacity}));
      await add(ml.LineStyleLayer(
        id: '$kPolygonsOutline#$i', sourceId: kPolygons, filter: filter,
        paint: {
          'line-color': g.outlineHex,
          'line-opacity': g.outlineOpacity,
          'line-width': g.borderWidth,
        }));
      await add(ml.LineStyleLayer(
        id: '$kLinesLine#$i', sourceId: kLines, filter: filter,
        paint: {'line-color': g.lineHex, 'line-width': g.lineWidth}));
      await add(ml.CircleStyleLayer(
        id: '$kPointsCircle#$i', sourceId: kPoints, filter: filter,
        paint: {
          'circle-radius': g.pointSize,
          'circle-color': g.pointHex,
          'circle-stroke-width': 1.5,
          'circle-stroke-color': '#FFFFFF',
        }));
    }
  }

  Future<void> updateLayerStyles({
    required Color polygonFillColor,
    required double polygonFillOpacity,
    required Color polygonOutlineColor,
    required double polygonOutlineOpacity,
    required double polygonBorderWidth,
    required Color lineColor,
    required double lineWidth,
    required Color pointColor,
    required double pointSize,
    required Color selectedColor,
    required double selectedMultiplier,
    required bool lineVertexEnabled,
    required double lineVertexSizeFactor,
    required bool polygonVertexEnabled,
    required double polygonVertexSizeFactor,
    double labelFontSize = 12,
    Color labelColor = const Color(0xFF000000),
    Color labelHaloColor = const Color(0xFFFFFFFF),
    double labelOpacity = 1,
  }) async {
    if (!_initialized || _style == null) return;
    final s = _style!;

    final fillHex = _colorToHex(polygonFillColor);
    final outlineHex = _colorToHex(polygonOutlineColor);
    final selHex = _colorToHex(selectedColor);
    final lineHex = _colorToHex(lineColor);
    final pointHex = _colorToHex(pointColor);

    // 頂点半径の計算
    final polyVR = polygonVertexEnabled
        ? (polygonBorderWidth * polygonVertexSizeFactor / 2).clamp(2.0, 24.0)
        : 0.0;
    final polyVSelR = polygonVertexEnabled
        ? (polygonBorderWidth * selectedMultiplier * polygonVertexSizeFactor / 2).clamp(2.0, 24.0)
        : 0.0;
    final lineVR = lineVertexEnabled
        ? (lineWidth * lineVertexSizeFactor / 2).clamp(2.0, 24.0)
        : 0.0;
    final lineVSelR = lineVertexEnabled
        ? (lineWidth * selectedMultiplier * lineVertexSizeFactor / 2).clamp(2.0, 24.0)
        : 0.0;

    // クラスタ丸の見た目サイズはpointSizeに比例するが、最低6pxを保証
    final clusterPointSize = pointSize.clamp(6.0, double.infinity);
    final clusterRadius = <Object>['step', ['get', 'point_count'],
      clusterPointSize * 1.2, 10, clusterPointSize * 1.5, 50, clusterPointSize * 1.8, 200, clusterPointSize * 2.3];
    final clusterTextSize = clusterPointSize * 1.6;

    await _removeAndReaddLayers(
      s,
      fillHex: fillHex, outlineHex: outlineHex, selHex: selHex,
      lineHex: lineHex, pointHex: pointHex,
      polygonFillOpacity: polygonFillOpacity,
      polygonOutlineOpacity: polygonOutlineOpacity,
      polygonBorderWidth: polygonBorderWidth,
      lineWidth: lineWidth, pointSize: pointSize,
      selectedMultiplier: selectedMultiplier,
      polygonOutlineColor: polygonOutlineColor,
      polyVR: polyVR, polyVSelR: polyVSelR,
      lineVR: lineVR, lineVSelR: lineVSelR,
      clusterRadius: clusterRadius,
      clusterTextSize: clusterTextSize,
      labelFontSize: labelFontSize,
      labelColorHex: _colorToHex(labelColor),
      labelHaloHex: _colorToHex(labelHaloColor),
      labelOpacity: labelOpacity,
    );

    AppLogger.debug('[MapSourceManager] layer styles updated');
  }



  /// Android/iOS向け: 全レイヤーを削除→再追加でスタイル更新
  Future<void> _removeAndReaddLayers(
    ml.StyleController s, {
    required String fillHex,
    required String outlineHex,
    required String selHex,
    required String lineHex,
    required String pointHex,
    required double polygonFillOpacity,
    required double polygonOutlineOpacity,
    required double polygonBorderWidth,
    required double lineWidth,
    required double pointSize,
    required double selectedMultiplier,
    required Color polygonOutlineColor,
    required double polyVR,
    required double polyVSelR,
    required double lineVR,
    required double lineVSelR,
    required List<Object> clusterRadius,
    required double clusterTextSize,
    required double labelFontSize,
    required String labelColorHex,
    required String labelHaloHex,
    required double labelOpacity,
  }) async {
    // グループぶんに増やしたレイヤも消す。順序は問わない
    for (final id in [..._groupLayerIds, ..._allLayerIds].reversed) {
      try { await s.removeLayer(id); } catch (_) {}
    }
    _groupLayerIds.clear();

    // ⚠ グループがあるときだけフィルタを付ける。無ければ null が渡り、
    //    View 導入前とまったく同じレイヤになる
    final defaultFilter = _defaultFilter;

    await s.addLayer(ml.FillStyleLayer(id: kPolygonsFill, sourceId: kPolygons,
      filter: defaultFilter,
      paint: {'fill-color': fillHex, 'fill-opacity': polygonFillOpacity}));
    await s.addLayer(ml.LineStyleLayer(id: kPolygonsOutline, sourceId: kPolygons,
      filter: defaultFilter,
      paint: {'line-color': outlineHex, 'line-opacity': polygonOutlineOpacity, 'line-width': polygonBorderWidth}));
    await s.addLayer(ml.FillStyleLayer(id: kPolygonsSelFill, sourceId: kPolygonsSel,
      paint: {'fill-color': selHex, 'fill-opacity': 0.5}));
    await s.addLayer(ml.LineStyleLayer(id: kPolygonsSelOutline, sourceId: kPolygonsSel,
      paint: {'line-color': selHex, 'line-width': 3.0}));
    await s.addLayer(ml.LineStyleLayer(id: kLinesLine, sourceId: kLines,
      filter: defaultFilter,
      paint: {'line-color': lineHex, 'line-width': lineWidth}));
    await s.addLayer(ml.LineStyleLayer(id: kLinesSelLine, sourceId: kLinesSel,
      paint: {'line-color': selHex, 'line-width': lineWidth * selectedMultiplier}));
    await s.addLayer(ml.LineStyleLayer(id: kGpsTrackLine, sourceId: kGpsTrack,
      paint: {'line-color': _colorToHex(MapColors.trackingRoute), 'line-width': 3.0}));
    await s.addLayer(ml.CircleStyleLayer(id: kPolyVerticesCircle, sourceId: kPolyVertices,
      paint: {'circle-radius': polyVR, 'circle-color': _colorToHex(polygonOutlineColor), 'circle-stroke-width': 1.0, 'circle-stroke-color': '#FFFFFF'}));
    await s.addLayer(ml.CircleStyleLayer(id: kPolyVerticesSelCircle, sourceId: kPolyVerticesSel,
      paint: {'circle-radius': polyVSelR, 'circle-color': selHex, 'circle-stroke-width': 1.0, 'circle-stroke-color': '#FFFFFF'}));
    await s.addLayer(ml.CircleStyleLayer(id: kLineVerticesCircle, sourceId: kLineVertices,
      paint: {'circle-radius': lineVR, 'circle-color': lineHex, 'circle-stroke-width': 1.0, 'circle-stroke-color': '#FFFFFF'}));
    await s.addLayer(ml.CircleStyleLayer(id: kLineVerticesSelCircle, sourceId: kLineVerticesSel,
      paint: {'circle-radius': lineVSelR, 'circle-color': selHex, 'circle-stroke-width': 1.0, 'circle-stroke-color': '#FFFFFF'}));
    await s.addLayer(ml.CircleStyleLayer(id: kClusterCircle, sourceId: kClusters,
      paint: {'circle-color': pointHex, 'circle-radius': clusterRadius, 'circle-stroke-width': 1.5, 'circle-stroke-color': '#FFFFFF'}));
    await s.addLayer(ml.SymbolStyleLayer(id: kClusterCount, sourceId: kClusters,
      layout: {'text-field': '{point_count_abbreviated}', 'text-font': ['Open Sans Semibold'], 'text-size': clusterTextSize, 'text-allow-overlap': true},
      paint: {'text-color': '#000000', 'text-halo-color': '#FFFFFF', 'text-halo-width': 1.5}));
    await s.addLayer(ml.CircleStyleLayer(id: kPointsCircle, sourceId: kPoints,
      filter: defaultFilter,
      paint: {'circle-radius': pointSize, 'circle-color': pointHex, 'circle-stroke-width': 1.5, 'circle-stroke-color': '#FFFFFF'}));
    await s.addLayer(ml.CircleStyleLayer(id: kPointsSelCircle, sourceId: kPointsSel,
      paint: {'circle-radius': pointSize * selectedMultiplier, 'circle-color': selHex, 'circle-stroke-width': 2.0, 'circle-stroke-color': '#FFFFFF'}));
    for (final l in _labelLayers(
      size: labelFontSize, colorHex: labelColorHex, haloHex: labelHaloHex, opacity: labelOpacity,
    )) {
      await s.addLayer(l);
    }
    await s.addLayer(ml.CircleStyleLayer(id: kImageClusterCircle, sourceId: kImageClusters,
      paint: {'circle-color': '#9C27B0', 'circle-radius': clusterRadius, 'circle-stroke-width': 1.5, 'circle-stroke-color': '#FFFFFF'}));
    await s.addLayer(ml.SymbolStyleLayer(id: kImageClusterCount, sourceId: kImageClusters,
      layout: {'text-field': '{point_count_abbreviated}', 'text-font': ['Open Sans Semibold'], 'text-size': clusterTextSize, 'text-allow-overlap': true},
      paint: {'text-color': '#000000', 'text-halo-color': '#FFFFFF', 'text-halo-width': 1.5}));
    await s.addLayer(const ml.SymbolStyleLayer(id: kImageClusterName, sourceId: kImageClusters,
      layout: {'text-field': <Object>['get', 'name'], 'text-font': ['Open Sans Semibold'], 'text-size': 10.0, 'text-anchor': 'left', 'text-offset': <Object>[1.2, 0], 'text-max-width': 100.0},
      paint: {'text-color': '#000000', 'text-halo-color': '#FFFFFF', 'text-halo-width': 1.5}));
    await s.addLayer(const ml.SymbolStyleLayer(id: kImagesSymbol, sourceId: kImages,
      layout: {
        'icon-image': <Object>['case', ['get', 'has_direction'], _iconPhotoMarker, _iconPhotoMarkerNoDir],
        'icon-rotate': <Object>['coalesce', ['get', 'direction'], 0],
        'icon-rotation-alignment': 'map', 'icon-allow-overlap': true, 'icon-size': 0.7,
        'text-field': <Object>['get', 'name'], 'text-font': ['Open Sans Semibold'], 'text-size': 12.0,
        'text-anchor': 'left', 'text-offset': <Object>[1.0, 0], 'text-max-width': 100.0, 'text-optional': true,
      },
      paint: {'text-color': '#000000', 'text-halo-color': '#FFFFFF', 'text-halo-width': 1.5}));
    await s.addLayer(const ml.SymbolStyleLayer(id: kImagesSelSymbol, sourceId: kImagesSel,
      layout: {
        'icon-image': <Object>['case', ['get', 'has_direction'], _iconPhotoMarkerSel, _iconPhotoMarkerNoDirSel],
        'icon-rotate': <Object>['coalesce', ['get', 'direction'], 0],
        'icon-rotation-alignment': 'map', 'icon-allow-overlap': true, 'icon-size': 1.0,
        'text-field': <Object>['get', 'name'], 'text-font': ['Open Sans Semibold'], 'text-size': 13.0,
        'text-anchor': 'left', 'text-offset': <Object>[1.0, 0], 'text-max-width': 100.0, 'text-optional': true,
      },
      paint: {'text-color': '#FF9800', 'text-halo-color': '#FFFFFF', 'text-halo-width': 1.5}));

    // 固有スタイルを持つぶんを最後に積む。
    //
    // ⚠ z順は「共有ソース1本」という作りの制約で、**レイヤ間の前後は表現できない**。
    //   ここで保証できるのは「固有スタイルのフィーチャは既定スタイルより前面」
    //   までで、それは View 以前から同じ。dir構造どおりの z順にするには
    //   ソースを分ける必要がある（未着手）。
    await _addGroupLayers(s);
  }

  /// 全ソースをクリア
  void clearAll() {
    for (final id in _allSourceIds) {
      _updateRaw(id, _emptyGeoJson);
    }
  }

  // --------------------------------------------------
  // オーバーレイ画像管理
  // --------------------------------------------------

  /// 管理中のオーバーレイ画像ソースID
  final Set<String> _overlaySourceIds = {};

  /// Native パスの排他制御: ソースIDごとの処理中フラグ
  final Map<String, bool> _overlayUpdateLocks = {};

  /// Native パスの pending キュー: 処理中に来た最新リクエストを保持
  final Map<String, _OverlayUpdateRequest> _pendingOverlayUpdates = {};

  /// オーバーレイ画像を追加
  /// basemap-layerの直上、k-polygons-fillの直下に配置
  Future<void> addOverlayImage({
    required String sourceId,
    required String layerId,
    required String imageUrl,
    required ml.LngLatQuad coordinates,

  }) async {
    final s = _style;
    if (s == null) return;

    try {
      await s.addSource(ml.ImageSource(
        id: sourceId,
        url: imageUrl,
        coordinates: coordinates,
      ));
      await s.addLayer(
        ml.RasterStyleLayer(id: layerId, sourceId: sourceId),
        belowLayerId: kPolygonsFill,
      );
      _overlaySourceIds.add(sourceId);

      AppLogger.debug('[MapSourceManager] addOverlayImage: $sourceId');
    } catch (e) {
      AppLogger.debug('[MapSourceManager] addOverlayImage error: $e');
    }
  }

  /// オーバーレイ画像の座標を更新
  ///
  /// remove+addが非同期のため、排他制御+最新値drain loopで競合を防止
  Future<void> updateOverlayCoordinates(
    String sourceId,
    ml.LngLatQuad coords, {
    String? imageUrl,
    String? layerId,
  }) async {
    final s = _style;
    if (s == null) return;

    if (imageUrl != null && layerId != null) {
      // Native: 排他制御付き drain loop で競合を防止
      // pending に最新値を保存（前の pending は上書き＝最新値のみ保持）
      _pendingOverlayUpdates[sourceId] = _OverlayUpdateRequest(
        coords: coords,
        imageUrl: imageUrl,
        layerId: layerId,

      );

      // 既に drain loop が動いていればスキップ（最新値は pending に保存済み）
      if (_overlayUpdateLocks[sourceId] == true) return;
      _overlayUpdateLocks[sourceId] = true;

      try {
        // pending が空になるまで最新値を消化し続ける
        while (_pendingOverlayUpdates.containsKey(sourceId)) {
          final req = _pendingOverlayUpdates.remove(sourceId)!;
          try {
            await s.removeLayer(req.layerId);
            await s.removeSource(sourceId);
          } catch (_) {
            // 初回やすでに削除済みの場合は無視
          }
          // drain loop 中に新しいリクエストが来ていたら、add をスキップして
          // 次のイテレーションで最新値を使う（無駄な add を避ける）
          if (_pendingOverlayUpdates.containsKey(sourceId)) continue;
          try {
            await s.addSource(ml.ImageSource(
              id: sourceId,
              url: req.imageUrl,
              coordinates: req.coords,
            ));
            await s.addLayer(
              ml.RasterStyleLayer(id: req.layerId, sourceId: sourceId),
              belowLayerId: kPolygonsFill,
            );
            _overlaySourceIds.add(sourceId);

          } catch (e) {
            AppLogger.debug(
              '[MapSourceManager] updateOverlayCoordinates native error: $e',
            );
          }
        }
      } finally {
        _overlayUpdateLocks[sourceId] = false;
      }
    }
  }



  /// オーバーレイ画像を削除
  Future<void> removeOverlayImage(String sourceId, String layerId) async {
    final s = _style;
    if (s == null) return;
    try {
      await s.removeLayer(layerId);
    } catch (_) {}
    try {
      await s.removeSource(sourceId);
    } catch (_) {}
    _overlaySourceIds.remove(sourceId);
    AppLogger.debug('[MapSourceManager] removeOverlayImage: $sourceId');
  }

  /// 管理中のオーバーレイソースIDを取得
  Set<String> get activeOverlaySourceIds => Set.unmodifiable(_overlaySourceIds);


  // --------------------------------------------------
  // ユーティリティ
  // --------------------------------------------------

  /// Color → MapLibre paint用 #RRGGBB 文字列
  /// `#RRGGBB`。スタイルグループを組み立てる側でも使う（[MapStyleGroup]）
  static String colorToHex(Color c) => _colorToHex(c);

  static String _colorToHex(Color c) {
    final r = (c.r * 255.0).round() & 0xff;
    final g = (c.g * 255.0).round() & 0xff;
    final b = (c.b * 255.0).round() & 0xff;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  /// Isolateでのシリアライズ（大量フィーチャ用）
  static Future<String> _serializeInIsolate<T extends geo.Geometry>(
    List<geo.Feature<T>> features,
  ) async {
    return Isolate.run(
      () => geo.FeatureCollection(features).toText(),
    );
  }
}

/// supercluster用ポイントラッパー（元フィーチャのインデックスと座標を保持）
class _IndexedPoint {
  final int index;
  final double longitude;
  final double latitude;

  const _IndexedPoint({
    required this.index,
    required this.longitude,
    required this.latitude,
  });
}

/// オーバーレイ座標更新リクエスト（drain loop の pending キュー用）
class _OverlayUpdateRequest {
  final ml.LngLatQuad coords;
  final String imageUrl;
  final String layerId;


  const _OverlayUpdateRequest({
    required this.coords,
    required this.imageUrl,
    required this.layerId,

  });
}
