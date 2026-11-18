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

/// `System`（`sys`）に追加した公式データの管理・MVT/PMTiles 取得キャッシュ・タップ当たり判定サービス。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/official/mvt_decoder.dart';
import '../../core/official/official_data_catalog.dart';
import '../../core/official/pmtiles_reader.dart';
import '../../core/terrain/web_mercator.dart';
import '../../i18n/strings.g.dart';
import '../../models/basemap_provider.dart';
import '../../models/nodes/global_folder_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/official_layer_node.dart';
import '../../models/nodes/sys_node.dart';
import '../../utils/app_logger.dart';
import '../../utils/feature_calc_utils.dart';
import '../basemap_service.dart';

/// MVT フィーチャに埋め込むスタイル識別キー（国有林・民有林などの描き分け用）
const String kOfficialStyleKeyProp = '__official_style';

/// MVT フィーチャに埋め込むラベル文字列キー
const String kOfficialLabelProp = '__official_label';

class OfficialLayerService extends ChangeNotifier {
  OfficialLayerService._({http.Client? client})
      : _http = client ?? http.Client(),
        usePersistentCache = true;

  @visibleForTesting
  OfficialLayerService.forTesting({
    http.Client? client,
    this.usePersistentCache = false,
  }) : _http = client ?? http.Client();

  static final OfficialLayerService instance = OfficialLayerService._();

  static const String _enabledPrefsKey = 'official_enabled_layers';
  static const String _visibilityPrefsKey = 'official_layer_visibility';
  static const Map<String, String> _headers = {
    if (!kIsWeb) 'User-Agent': kTileUserAgent,
  };

  /// MBTiles 上の公式ベクトルタイル用キャッシュ ID（`official_rinya_forest_plan` など）
  static String persistentCacheId(String specId) => 'official_$specId';

  final http.Client _http;
  final bool usePersistentCache;
  bool _initialized = false;

  /// 追加済みの公式レイヤ ID（追加順）
  final List<String> _enabledIds = [];

  /// 公式レイヤごとの可視状態（未記録は true）
  final Map<String, bool> _visibility = {};

  /// デコード済みベクトルタイルの LRU キャッシュ（`${spec.id}/$z/$x/$y` → features）
  static const int _maxCachedVectorTiles = 96;
  final LinkedHashMap<String, List<geo.Feature<geo.Geometry>>> _vectorCache = LinkedHashMap();

  /// 404 または空だったタイル（同じセッションで何度も取りに行かない）
  static const int _maxEmptyTiles = 256;
  final LinkedHashSet<String> _emptyTiles = LinkedHashSet();

  /// 進行中のタイル取得（同じタイルの重複リクエストを 1 本にまとめる）
  final Map<String, Future<List<geo.Feature<geo.Geometry>>?>> _inflight = {};

  /// PMTiles リーダーのキャッシュ（URL → reader）
  final Map<String, PmTilesReader> _pmReaders = {};

  /// 地質図などの地点 API キャッシュ（`lat4,lon4` → 属性マップ、水域等は空マップ）
  static const int _maxPointApiCache = 64;
  final LinkedHashMap<String, Map<String, String>> _pointApiCache = LinkedHashMap();

  /// 3D シーンのキャッシュ無効化に使う世代カウンタ
  int _revision = 0;
  int get revision => _revision;

  List<String> get enabledIds => List.unmodifiable(_enabledIds);

  List<OfficialLayerSpec> get enabledSpecs => [
        for (final id in _enabledIds) ?OfficialLayerSpec.byId(id),
      ];

  bool isEnabled(String specId) => _enabledIds.contains(specId);

  bool isLayerVisible(String specId) => _visibility[specId] ?? true;

  void _bump() {
    _revision++;
    notifyListeners();
  }

  /// 設定を読み込む（何度呼んでも初回のみ実行）
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_enabledPrefsKey) ?? const [];
      _enabledIds
        ..clear()
        ..addAll(ids.where((id) => OfficialLayerSpec.byId(id) != null));
      final visRaw = prefs.getString(_visibilityPrefsKey);
      if (visRaw != null && visRaw.isNotEmpty) {
        final decoded = json.decode(visRaw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            if (e.key is String && e.value is bool) {
              _visibility[e.key as String] = e.value as bool;
            }
          }
        }
      }
    } catch (e) {
      AppLogger.debug('[OfficialLayerService] 設定読み込み失敗: $e');
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_enabledPrefsKey, _enabledIds);
      await prefs.setString(_visibilityPrefsKey, json.encode(_visibility));
    } catch (e) {
      AppLogger.debug('[OfficialLayerService] 設定保存失敗: $e');
    }
  }

  /// ルートツリーの `System`（`sys`）を保証し、追加済みの [OfficialLayerNode] を同期する。
  /// Android でも web でも `sys` がルート直下に置かれ、`Global` があればその下に続く。
  Future<SysNode?> syncToTree(LayerTreeNode? root) async {
    if (root == null) return null;
    await ensureInitialized();
    final sys = SysNode.ensureIn(root);
    final existingById = {
      for (final c in sys.children.whereType<OfficialLayerNode>()) c.spec.id: c,
    };
    final globals = sys.children.whereType<GlobalFolderNode>().toList();
    final officials = <OfficialLayerNode>[
      for (final spec in enabledSpecs)
        (existingById[spec.id] ??
            OfficialLayerNode(
              spec,
              visible: isLayerVisible(spec.id),
              parent: sys,
              onPersistVisibility: (v) => setLayerVisibility(spec.id, v),
            ))
          ..visible = isLayerVisible(spec.id)
          ..parent = sys,
    ];
    for (final c in sys.children.whereType<OfficialLayerNode>()) {
      if (!_enabledIds.contains(c.spec.id)) c.parent = null;
    }
    sys.children
      ..clear()
      ..addAll(globals)
      ..addAll(officials);
    return sys;
  }

  /// [root] の中で現在可視になっている [OfficialLayerNode] 一覧
  List<OfficialLayerNode> visibleNodesIn(LayerTreeNode? root) {
    if (root == null) return const [];
    final sys = root.children.whereType<SysNode>().firstOrNull;
    if (sys == null || !sys.isVisibleRecursive()) return const [];
    return [
      for (final c in sys.children.whereType<OfficialLayerNode>())
        if (c.visible) c,
    ];
  }

  /// 公式データレイヤを追加して [root] に反映する
  Future<void> addLayer(String specId, {LayerTreeNode? root}) async {
    await ensureInitialized();
    if (OfficialLayerSpec.byId(specId) == null) return;
    if (!_enabledIds.contains(specId)) {
      _enabledIds.add(specId);
    }
    _visibility[specId] = true;
    await _savePrefs();
    await syncToTree(root);
    _bump();
  }

  /// 公式データレイヤを一覧から外す
  Future<void> removeLayer(String specId, {LayerTreeNode? root}) async {
    await ensureInitialized();
    _enabledIds.remove(specId);
    _visibility.remove(specId);
    _vectorCache.removeWhere((k, _) => k.startsWith('$specId/'));
    _emptyTiles.removeWhere((k) => k.startsWith('$specId/'));
    await _savePrefs();
    await syncToTree(root);
    _bump();
  }

  /// 個別公式レイヤの表示/非表示を保存し通知する
  Future<void> setLayerVisibility(String specId, bool visible) async {
    await ensureInitialized();
    if (_visibility[specId] == visible) return;
    _visibility[specId] = visible;
    await _savePrefs();
    _bump();
  }

  /// 有効な公式データレイヤの並びを一括で差し替える（用途プリセットの適用など）。
  /// 指定外の公式レイヤは一覧から外して不要な通信を止める。
  Future<void> setEnabledLayers(List<String> specIds, {LayerTreeNode? root}) async {
    await ensureInitialized();
    final seen = <String>{};
    final nextIds = [
      for (final id in specIds)
        if (OfficialLayerSpec.byId(id) != null && seen.add(id)) id,
    ];
    for (final oldId in _enabledIds) {
      if (!seen.contains(oldId)) {
        _visibility.remove(oldId);
        _vectorCache.removeWhere((k, _) => k.startsWith('$oldId/'));
        _emptyTiles.removeWhere((k) => k.startsWith('$oldId/'));
      }
    }
    _enabledIds
      ..clear()
      ..addAll(nextIds);
    for (final id in nextIds) {
      _visibility[id] = true;
    }
    await _savePrefs();
    await syncToTree(root);
    _bump();
  }

  /// SharedPreferences が外部更新された際に設定を再読込する
  Future<void> reloadSettingsFromPrefs({LayerTreeNode? root}) async {
    _initialized = false;
    _visibility.clear();
    await ensureInitialized();
    await syncToTree(root);
    _bump();
  }

  // ── ベクトルタイル取得・キャッシュ ──────────────────────────

  /// 指定した地形タイル `(z, x, y)` に重なる公式ベクトルフィーチャを同期的に返す。
  /// 未取得なら裏で非同期取得を始め、届いた時点で [revision] を進めて再描画を促す。
  List<geo.Feature<geo.Geometry>> featuresForTileSync(
    OfficialLayerSpec spec,
    int z,
    int x,
    int y,
  ) {
    if (spec.kind != OfficialLayerKind.vectorTile || spec.vectorSources.isEmpty) {
      return const [];
    }
    if (z < spec.minDisplayZoom) return const [];

    final maxSrcZoom = spec.vectorSources.fold<int>(0, (m, s) => math.max(m, s.maxZoom));
    final minSrcZoom = spec.vectorSources.fold<int>(24, (m, s) => math.min(m, s.minZoom));
    final targetZ = z.clamp(minSrcZoom, maxSrcZoom);
    final shift = z - targetZ;
    final tx = shift >= 0 ? (x >> shift) : (x << -shift);
    final ty = shift >= 0 ? (y >> shift) : (y << -shift);
    final key = '${spec.id}/$targetZ/$tx/$ty';

    final hit = _vectorCache.remove(key);
    if (hit != null) {
      // LRU 更新
      _vectorCache[key] = hit;
      return hit;
    }
    if (_emptyTiles.contains(key)) return const [];

    unawaited(ensureVectorTile(spec, targetZ, tx, ty));
    return const [];
  }

  /// ベクトルタイル `(z, x, y)` を取得してデコードし、キャッシュへ入れる
  Future<List<geo.Feature<geo.Geometry>>?> ensureVectorTile(
    OfficialLayerSpec spec,
    int z,
    int x,
    int y,
  ) {
    final key = '${spec.id}/$z/$x/$y';
    final cached = _vectorCache[key];
    if (cached != null) return Future.value(cached);
    if (_emptyTiles.contains(key)) return Future.value(const []);

    final running = _inflight[key];
    if (running != null) return running;

    final future = _fetchAndDecodeVectorTile(spec, z, x, y, key);
    _inflight[key] = future;
    future.whenComplete(() => _inflight.remove(key)).ignore();
    return future;
  }

  /// オフライン一括ダウンロード向け: 指定エリア・ズーム範囲で必要になる公式ベクトルタイル座標一覧（重複除外済）
  List<({int z, int x, int y})> tilesForArea(
    OfficialLayerSpec spec, {
    required LatLng center,
    required double radiusMeters,
    required int minZoom,
    required int maxZoom,
  }) {
    if (spec.kind != OfficialLayerKind.vectorTile || spec.vectorSources.isEmpty) {
      return const [];
    }
    final maxSrcZoom = spec.vectorSources.fold<int>(0, (m, s) => math.max(m, s.maxZoom));
    final minSrcZoom = spec.vectorSources.fold<int>(24, (m, s) => math.min(m, s.minZoom));
    final startZ = math.max(minZoom, spec.minDisplayZoom);
    if (startZ > maxZoom) return const [];

    final latDiff = radiusMeters / 111000.0;
    final lonDiff = radiusMeters / (111000.0 * math.cos(center.latitude * math.pi / 180.0));
    final north = (center.latitude + latDiff).clamp(-85.0511, 85.0511);
    final south = (center.latitude - latDiff).clamp(-85.0511, 85.0511);
    final east = (center.longitude + lonDiff).clamp(-180.0, 180.0);
    final west = (center.longitude - lonDiff).clamp(-180.0, 180.0);

    final seen = <String>{};
    final out = <({int z, int x, int y})>[];
    for (var z = startZ; z <= maxZoom; z++) {
      final targetZ = z.clamp(minSrcZoom, maxSrcZoom);
      final maxIdx = (1 << targetZ) - 1;
      final x0 = WebMercator.tileXFraction(west, targetZ).floor().clamp(0, maxIdx);
      final x1 = WebMercator.tileXFraction(east, targetZ).floor().clamp(0, maxIdx);
      final y0 = WebMercator.tileYFraction(north, targetZ).floor().clamp(0, maxIdx);
      final y1 = WebMercator.tileYFraction(south, targetZ).floor().clamp(0, maxIdx);
      for (var x = math.min(x0, x1); x <= math.max(x0, x1); x++) {
        for (var y = math.min(y0, y1); y <= math.max(y0, y1); y++) {
          if (!spec.vectorSources.any((s) => targetZ >= s.minZoom && targetZ <= s.maxZoom && s.coversTile(targetZ, x, y))) {
            continue;
          }
          if (seen.add('$targetZ/$x/$y')) {
            out.add((z: targetZ, x: x, y: y));
          }
        }
      }
    }
    return out;
  }

  /// 公式ベクトルタイル 1 枚を事前取得して永続キャッシュ（MBTiles）へ保存する。
  /// 戻り値: `true`=新規取得（404空タイル確認含む）, `false`=キャッシュ済みスキップ, `null`=通信エラー
  Future<bool?> prefetchVectorTile(OfficialLayerSpec spec, int z, int x, int y) async {
    final key = '${spec.id}/$z/$x/$y';
    if (_emptyTiles.contains(key)) return false;
    final dbCacheId = persistentCacheId(spec.id);
    if (usePersistentCache) {
      final diskHit = await BaseMapService().getCachedRawTile(dbCacheId, z, x, y);
      if (diskHit != null) return false;
    } else if (_vectorCache.containsKey(key)) {
      return false;
    }
    final res = await ensureVectorTile(spec, z, x, y);
    if (res == null) return null;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return true;
  }

  Future<List<geo.Feature<geo.Geometry>>?> _fetchAndDecodeVectorTile(
    OfficialLayerSpec spec,
    int z,
    int x,
    int y,
    String cacheKey,
  ) async {
    final dbCacheId = persistentCacheId(spec.id);
    final persistedBytes =
        usePersistentCache ? await BaseMapService().getCachedRawTile(dbCacheId, z, x, y) : null;

    for (final src in spec.vectorSources) {
      if (z < src.minZoom || z > src.maxZoom || !src.coversTile(z, x, y)) continue;
      try {
        Uint8List? rawBytes = persistedBytes;
        var fetchedFromNetwork = false;
        if (rawBytes == null) {
          if (usePersistentCache && BaseMapService().shouldSkipNetwork) {
            return null;
          }
          if (src.isPmTiles) {
            final reader = _pmReaders.putIfAbsent(
              src.urlTemplate,
              () => PmTilesReader((offset, length) async {
                final end = offset + length - 1;
                final res = await _http
                    .get(
                      Uri.parse(src.urlTemplate),
                      headers: {..._headers, 'Range': 'bytes=$offset-$end'},
                    )
                    .timeout(const Duration(seconds: 10));
                if ((res.statusCode == 206 || res.statusCode == 200) && res.bodyBytes.isNotEmpty) {
                  if (res.statusCode == 200 && res.bodyBytes.length > offset) {
                    final sliceEnd = math.min(offset + length, res.bodyBytes.length);
                    return Uint8List.sublistView(res.bodyBytes, offset, sliceEnd);
                  }
                  return res.bodyBytes;
                }
                return null;
              }),
            );
            rawBytes = await reader.getTile(z, x, y);
            fetchedFromNetwork = rawBytes != null && rawBytes.isNotEmpty;
          } else {
            final url = BaseMapProvider.expandTileUrl(src.urlTemplate, z, x, y);
            final res = await _http
                .get(Uri.parse(url), headers: _headers)
                .timeout(const Duration(seconds: 10));
            if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
              rawBytes = res.bodyBytes;
              fetchedFromNetwork = true;
            } else if (res.statusCode == 404) {
              continue;
            } else {
              return null;
            }
          }
        }

        if (rawBytes == null || rawBytes.isEmpty) continue;
        if (fetchedFromNetwork && usePersistentCache) {
          await BaseMapService().cacheRawTile(dbCacheId, z, x, y, rawBytes);
        }

        final mvt = MvtDecoder.decode(
          rawBytes,
          z: z,
          x: x,
          y: y,
          sourceLayer: src.sourceLayer,
        );
        final rawFeatures = mvt.allFeatures(src.sourceLayer);

        final decorated = [
          for (var i = 0; i < rawFeatures.length; i++)
            _decorateFeature(spec, rawFeatures[i], z, x, y, i),
        ];

        if (decorated.isEmpty) {
          _rememberEmpty(cacheKey);
          return const [];
        }
        _putCache(cacheKey, decorated);
        _bump();
        return decorated;
      } catch (e) {
        AppLogger.debug('[OfficialLayerService] MVT 取得失敗 ($cacheKey): $e');
        return null;
      }
    }

    _rememberEmpty(cacheKey);
    return const [];
  }

  geo.Feature<geo.Geometry> _decorateFeature(
    OfficialLayerSpec spec,
    geo.Feature<geo.Geometry> f,
    int z,
    int x,
    int y,
    int index,
  ) {
    final props = Map<String, Object?>.from(f.properties);
    if (spec.id == 'rinya_forest_plan') {
      final ownerKind = '${props['民国別'] ?? ''}'.trim();
      final rinpan = '${props['林班'] ?? ''}'.trim();
      final isNational = ownerKind.contains('国有林');
      props[kOfficialStyleKeyProp] = isNational ? 'rinya_national' : 'rinya_private';
      // 先頭の 0 を除いた林班番号をラベルにする（"0042" → "42"、"0000" はそのまま "0"）
      if (rinpan.isNotEmpty) {
        final trimmed = rinpan.replaceFirst(RegExp('^0+(?=.)'), '');
        props[kOfficialLabelProp] = isNational ? '国$trimmed' : trimmed;
      }
    }
    return geo.Feature<geo.Geometry>(
      id: f.id ?? '$z/$x/$y#$index',
      geometry: f.geometry,
      properties: props,
    );
  }

  void _putCache(String key, List<geo.Feature<geo.Geometry>> features) {
    _vectorCache.remove(key);
    _vectorCache[key] = features;
    while (_vectorCache.length > _maxCachedVectorTiles) {
      _vectorCache.remove(_vectorCache.keys.first);
    }
  }

  void _rememberEmpty(String key) {
    _emptyTiles.remove(key);
    _emptyTiles.add(key);
    while (_emptyTiles.length > _maxEmptyTiles) {
      _emptyTiles.remove(_emptyTiles.first);
    }
  }

  /// テスト用・手動挿入用キャッシュ登録
  @visibleForTesting
  void putDecodedTileForTesting(
    OfficialLayerSpec spec,
    int z,
    int x,
    int y,
    List<geo.Feature<geo.Geometry>> features,
  ) {
    final decorated = [
      for (var i = 0; i < features.length; i++) _decorateFeature(spec, features[i], z, x, y, i),
    ];
    _putCache('${spec.id}/$z/$x/$y', decorated);
  }

  // ── タップ当たり判定と地点 API ──────────────────────────────

  /// タップ位置 [tapPoint] にある可視公式レイヤの候補を返す（優先度は通常ポリゴンの次）
  List<OfficialFeatureNode> hitTest(
    LatLng tapPoint,
    LayerTreeNode? root, {
    required double zoom,
    double selectRangeMeters = 25.0,
  }) {
    final visibleNodes = visibleNodesIn(root);
    if (visibleNodes.isEmpty) return const [];

    final hits = <OfficialFeatureNode>[];
    for (final layerNode in visibleNodes) {
      final spec = layerNode.spec;
      if (zoom < spec.minDisplayZoom) continue;

      if (spec.kind == OfficialLayerKind.vectorTile && spec.vectorSources.isNotEmpty) {
        final maxSrcZoom = spec.vectorSources.fold<int>(0, (m, s) => math.max(m, s.maxZoom));
        final minSrcZoom = spec.vectorSources.fold<int>(24, (m, s) => math.min(m, s.minZoom));
        final prefZ = zoom.floor().clamp(minSrcZoom, maxSrcZoom);

        List<geo.Feature<geo.Geometry>>? tileFeatures;
        var usedZ = prefZ;
        for (var z = prefZ; z >= minSrcZoom; z--) {
          final (tx, ty) = _lonLatToTileXY(tapPoint.longitude, tapPoint.latitude, z);
          final cached = _vectorCache['${spec.id}/$z/$tx/$ty'];
          if (cached != null) {
            tileFeatures = cached;
            usedZ = z;
            break;
          }
        }
        if (tileFeatures == null) continue;

        final seenIds = <String>{};
        for (var i = 0; i < tileFeatures.length; i++) {
          final f = tileFeatures[i];
          final geom = f.geometry;
          if (geom == null) continue;
          final kind = (geom is geo.Polygon || geom is geo.MultiPolygon)
              ? 'polygon'
              : (geom is geo.LineString || geom is geo.MultiLineString)
                  ? 'line'
                  : 'point';
          final dist = FeatureSearch.calcPointToFeatureDistance(tapPoint, geom, kind);
          if (dist <= (kind == 'polygon' ? 0.0 : selectRangeMeters)) {
            final attrs = _formatAttributes(spec, f.properties);
            final title = _buildFeatureTitle(spec, f.properties);
            final hitId = _stableHitId(spec, f, usedZ, i);
            if (!seenIds.add(hitId)) continue;
            hits.add(
              OfficialFeatureNode(
                spec: spec,
                hitId: hitId,
                title: title,
                tapPoint: tapPoint,
                attributes: attrs,
                geometry: geom,
                parent: layerNode,
              ),
            );
          }
        }
      } else if (spec.kind == OfficialLayerKind.rasterWithPointApi &&
          spec.pointApiUrlTemplate != null) {
        final qKey = '${tapPoint.latitude.toStringAsFixed(4)},${tapPoint.longitude.toStringAsFixed(4)}';
        final cached = _pointApiCache[qKey];
        hits.add(
          OfficialFeatureNode(
            spec: spec,
            hitId: 'gsj:$qKey',
            title: OfficialLayerNode.displayNameOf(spec),
            tapPoint: tapPoint,
            attributes: cached ?? const {},
            lazyAttributesLoader: cached != null ? null : () => queryPointApi(spec, tapPoint),
            parent: layerNode,
          ),
        );
      }
    }
    return hits;
  }

  /// 産総研シームレス地質図 V2 などの地点 JSON API を照会して属性マップに変換する
  Future<Map<String, String>?> queryPointApi(OfficialLayerSpec spec, LatLng point) async {
    final template = spec.pointApiUrlTemplate;
    if (template == null) return null;
    final qKey = '${point.latitude.toStringAsFixed(4)},${point.longitude.toStringAsFixed(4)}';
    final cached = _pointApiCache.remove(qKey);
    if (cached != null) {
      _pointApiCache[qKey] = cached;
      return cached;
    }

    final url = template
        .replaceAll('{lat}', point.latitude.toStringAsFixed(6))
        .replaceAll('{lon}', point.longitude.toStringAsFixed(6));
    try {
      final res = await _http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final decoded = json.decode(utf8.decode(res.bodyBytes));
      if (decoded is! Map) return null;

      final attrs = <String, String>{};
      void putIfNonEmpty(String label, Object? v) {
        final s = '${v ?? ''}'.trim();
        if (s.isNotEmpty && s != 'null') attrs[label] = s;
      }

      putIfNonEmpty(t.officialLayer.attrSymbol, decoded['symbol']);
      putIfNonEmpty(t.officialLayer.attrAge, decoded['formationAge_ja'] ?? decoded['formationAge_en']);
      putIfNonEmpty(t.officialLayer.attrGroup, decoded['group_ja'] ?? decoded['group_en']);
      putIfNonEmpty(t.officialLayer.attrLithology, decoded['lithology_ja'] ?? decoded['lithology_en']);

      _pointApiCache[qKey] = attrs;
      while (_pointApiCache.length > _maxPointApiCache) {
        _pointApiCache.remove(_pointApiCache.keys.first);
      }
      return attrs;
    } catch (e) {
      AppLogger.debug('[OfficialLayerService] 地点 API 取得失敗 ($url): $e');
      return null;
    }
  }

  static (int, int) _lonLatToTileXY(double lon, double lat, int z) {
    final n = 1 << z;
    final mx = WebMercator.xFromLon(lon);
    final my = WebMercator.yFromLat(lat);
    const half = WebMercator.halfCircumference;
    final tx = (((mx + half) / (2 * half)) * n).floor().clamp(0, n - 1);
    final ty = (((half - my) / (2 * half)) * n).floor().clamp(0, n - 1);
    return (tx, ty);
  }

  static String _stableHitId(OfficialLayerSpec spec, geo.Feature f, int z, int idx) {
    if (spec.id == 'rinya_forest_plan') {
      final muni = '${f.properties['市町村コード5桁'] ?? ''}';
      final plan = '${f.properties['森林計画区コード'] ?? ''}';
      final kind = '${f.properties['民国別'] ?? ''}';
      final rinpan = '${f.properties['林班'] ?? ''}';
      if (rinpan.isNotEmpty) return '$muni:$plan:$kind:$rinpan';
    }
    return '${f.id ?? '$z#$idx'}';
  }

  static String _buildFeatureTitle(OfficialLayerSpec spec, Map<String, Object?> props) {
    if (spec.id == 'rinya_forest_plan') {
      final kind = '${props['民国別'] ?? ''}'.trim();
      final rinpan = '${props['林班'] ?? ''}'.trim();
      if (kind.isNotEmpty && rinpan.isNotEmpty) return '$kind 林班 $rinpan';
      if (rinpan.isNotEmpty) return '林班 $rinpan';
    }
    return OfficialLayerNode.displayNameOf(spec);
  }

  static Map<String, String> _formatAttributes(OfficialLayerSpec spec, Map<String, Object?> props) {
    final out = <String, String>{};
    for (final e in props.entries) {
      if (e.key.startsWith('__official_')) continue;
      final val = '${e.value ?? ''}'.trim();
      if (val.isEmpty || val == 'null') continue;
      out[e.key] = val;
    }
    return out;
  }
}
