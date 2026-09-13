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
/// 背景地図管理サービス
/// 背景地図の選択、切り替え、オフラインキャッシュ機能を提供
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../core/platform_capabilities.dart';
import '../i18n/strings.g.dart';
import '../models/basemap_layer.dart';
import '../models/basemap_provider.dart';
import 'tile_cache_mbtiles.dart';

/// Isolateで実行するための画像処理関数（トップレベル関数）
Future<Uint8List?> _processTileExtraction(Map<String, dynamic> params) async {
  try {
    final parentTileData = params['parentTileData'] as Uint8List;
    final targetZ = params['targetZ'] as int;
    final targetX = params['targetX'] as int;
    final targetY = params['targetY'] as int;
    final parentZ = params['parentZ'] as int;
    final parentX = params['parentX'] as int;
    final parentY = params['parentY'] as int;

    // 親タイル画像をデコード
    final parentImage = img.decodeImage(parentTileData);
    if (parentImage == null) {
      return null;
    }

    // ズーム差を計算
    final zoomDiff = targetZ - parentZ;
    final scale = 1 << zoomDiff; // 2^(zoom差)

    // 親タイル内での相対座標を計算
    final relativeX = targetX - parentX * scale;
    final relativeY = targetY - parentY * scale;

    // 切り出し範囲を計算（親タイルのサイズを基準）
    final parentTileSize = parentImage.width;
    final cropSize = parentTileSize ~/ scale;
    final cropX = relativeX * cropSize;
    final cropY = relativeY * cropSize;

    // 範囲チェック
    if (cropX < 0 ||
        cropY < 0 ||
        cropX + cropSize > parentTileSize ||
        cropY + cropSize > parentTileSize) {
      // 範囲外の場合は親タイル全体をスケールして返す
      final resizedImage = img.copyResize(
        parentImage,
        width: 256,
        height: 256,
      );
      return Uint8List.fromList(img.encodePng(resizedImage));
    }

    // 指定領域を切り出し
    final croppedImage = img.copyCrop(
      parentImage,
      x: cropX,
      y: cropY,
      width: cropSize,
      height: cropSize,
    );

    // 256x256にリサイズ
    final resizedImage = img.copyResize(
      croppedImage,
      width: 256,
      height: 256,
      interpolation: img.Interpolation.linear,
    );

    // PNG形式でエンコード
    return Uint8List.fromList(img.encodePng(resizedImage));
  } catch (e) {
    AppLogger.debug('[TILE-ISO] ❌ Scaling error: $e');
    return null;
  }
}

/// 背景地図管理サービス
class BaseMapService extends ChangeNotifier {
  /// タイル取得用の HTTP クライアント。1 つを使い回して接続（TLS）を保つ。
  /// `http.get` はそのたびに接続を張り直すので、Pixel 9 で 1 枚 0.4〜1.4 秒掛かっていた
  final http.Client _http = http.Client();

  static final BaseMapService _instance = BaseMapService._internal();
  factory BaseMapService() => _instance;
  BaseMapService._internal();

  /// 透明なタイル（256x256 PNG）
  static final Uint8List transparentTile = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00,
    0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x08, 0x04, 0x00, 0x00, 0x00, 0x5C,
    0x72, 0xA8, 0x66, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0xF8, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x02, 0x9A, 0x65, 0x1C, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);

  BaseMapProvider _currentProvider = BaseMapProvider.defaultProvider;
  bool _isOfflineMode = false;
  String? _cacheDirectory;
  TileCacheMBTiles? _tileCacheDb;
  
  // ネットワーク状態監視
  final Connectivity _connectivity = Connectivity();
  bool _isNetworkAvailable = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // キャンセルトークン用
  bool _isDownloading = false;
  bool _cancelDownload = false;

  // --- レイヤ（お絵描きソフトのレイヤと同じ: 並び・可視・不透明度・合成モード） ---
  /// 先頭が一番下。設定画面は上から並べて見せる
  List<BaseMapLayer> _layers = [];

  /// 一番下の見えているレイヤのプロバイダ（互換用。一括ダウンロード・TileServer の既定 URL など）
  BaseMapProvider get currentProvider => _currentProvider;

  /// オフラインモードかどうか
  bool get isOfflineMode => _isOfflineMode;

  /// アプリ内でタイルを作るプロバイダ（[BaseMapType.generated]）の生成器。キャッシュに無ければこれで作って入れる
  final Map<String, Future<Uint8List?> Function(int z, int x, int y)> _generators = {};

  void registerTileGenerator(String providerId, Future<Uint8List?> Function(int z, int x, int y) generate) {
    _generators[providerId] = generate;
  }

  void unregisterTileGenerator(String providerId, Future<Uint8List?> Function(int z, int x, int y) generate) {
    if (identical(_generators[providerId], generate)) _generators.remove(providerId);
  }

  /// 生成プロバイダのタイル: キャッシュ → 生成器 → キャッシュへ（キャッシュは [BaseMapProvider.cacheId]。絵の版ごとに別）
  Future<Uint8List?> _getGeneratedTile(BaseMapProvider provider, int z, int x, int y) async {
    final cached = await _getCachedTile(provider.cacheId, z, x, y);
    if (cached != null) return cached;
    final generate = _generators[provider.id];
    if (generate == null) return null;
    try {
      final data = await generate(z, x, y);
      if (data != null && data.length >= 100) await _cacheTile(provider.cacheId, z, x, y, data);
      return data;
    } catch (e) {
      AppLogger.debug('[TILE] ${provider.id} $z/$x/$y の生成に失敗: $e');
      return null;
    }
  }

  /// 生成プロバイダの古い版のキャッシュ（`contours_v3.mbtiles` など）を消す。版が上がると [BaseMapProvider.cacheId] が変わり、
  /// 古いファイルは誰も引かないまま残るので
  Future<void> _dropStaleGeneratedCaches() async {
    final db = _tileCacheDb;
    if (db == null) return;
    for (final p in BaseMapProvider.availableProviders) {
      if (p.type != BaseMapType.generated || p.cacheId == p.id) continue;
      for (final name in db.cachedProviderIds()) {
        // 本体が無く -wal などの残骸だけのものも拾う（cachedProviderIds は .mbtiles だけ見る）
        if (name != p.cacheId && name.startsWith('${p.id}_v')) {
          AppLogger.debug('[BaseMapService] 古い生成キャッシュを消す: $name');
          await db.clearCache(providerId: name);
        }
      }
    }
  }

  /// ネットワークが利用可能かどうか
  /// ネットが使えるか。「インターフェイスがある」かつ「実際に届いている」
  bool get isNetworkAvailable => _isNetworkAvailable && _reachable;

  /// 実到達性。connectivity_plus は**インターフェイスの有無**しか見ないので、
  /// 圏外でもモバイル回線が「接続中」なら true のまま。タイル取得が
  /// [_failuresToGoOffline] 回続けて失敗（タイムアウト等）したら false に落とし、
  /// [isNetworkAvailable] 経由で地図側に伝える（Android なら mbtiles 直読みに切り替わる）。
  /// false の間は [_probeInterval] ごとに 1 本だけ短いタイムアウトで試し、
  /// 成功したら true に戻す
  bool _reachable = true;
  int _consecutiveFailures = 0;
  DateTime? _unreachableSince;
  static const int _failuresToGoOffline = 3;
  static const Duration _probeInterval = Duration(seconds: 20);

  void _noteFetchSuccess() {
    _consecutiveFailures = 0;
    if (_reachable) return;
    _reachable = true;
    _unreachableSince = null;
    AppLogger.debug('[BaseMapService] Network reachable again');
    notifyListeners();
  }

  void _noteFetchFailure() {
    _consecutiveFailures++;
    if (_reachable && _consecutiveFailures >= _failuresToGoOffline) {
      _reachable = false;
      _unreachableSince = DateTime.now();
      AppLogger.debug('[BaseMapService] Network unreachable (interface up but $_consecutiveFailures fetches failed)');
      notifyListeners();
    } else if (!_reachable) {
      _unreachableSince = DateTime.now();
    }
  }

  /// 到達不能と判定中で、まだ次の試行時刻に達していないか
  bool get _inUnreachableCooldown {
    final since = _unreachableSince;
    return !_reachable &&
        since != null &&
        DateTime.now().difference(since) < _probeInterval;
  }

  /// ダウンロード中かどうか
  bool get isDownloading => _isDownloading;

  /// 指定プロバイダーのMBTilesファイルパスを取得
  String? getMBTilesPath(String providerId) => _tileCacheDb?.getMBTilesPath(providerId);

  /// 利用可能なプロバイダー一覧
  List<BaseMapProvider> get availableProviders =>
      BaseMapProvider.availableProviders;

  /// 背景地図のレイヤ（下から上へ）。変更は [setLayers] / [updateLayer] / [addLayer] / [removeLayer] / [moveLayer]
  List<BaseMapLayer> get layers => List.unmodifiable(_layers);

  /// 絵に効くレイヤ（見えていて不透明度 > 0）とそのプロバイダ。下から上へ。3D のテクスチャ合成と web 2D はこれを重ねる
  List<(BaseMapProvider, BaseMapLayer)> get activeLayers => [
        for (final l in _layers)
          if (l.effective && l.provider != null) (l.provider!, l),
      ];

  /// 一括ダウンロード等の「いま使っている地図」。一番下の見えているレイヤ（無ければ既定）
  void _syncCurrentProvider() {
    final active = activeLayers;
    _currentProvider = active.isNotEmpty ? active.first.$1 : BaseMapProvider.defaultProvider;
  }

  /// サービス初期化
  Future<void> initialize() async {
    try {
      // タイルキャッシュはローカルファイルシステムが前提。
      // web には無いので飛ばす（ブラウザのHTTPキャッシュに任せる）。
      // ⚠ ここで例外を投げると _loadSettings まで到達せず、
      //   _layers が空＝背景地図が1枚も出なくなる。
      if (PlatformCapabilities.hasTileCache) {
        // キャッシュディレクトリの設定
        await _initializeCacheDirectory();

        // GeoPackageキャッシュの初期化
        await _initializeTileCacheDatabase();
      }

      // 設定の読み込み
      await _loadSettings();

      // ネットワーク状態の監視開始（初期状態を確定してから続行）
      await _initConnectivity();
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Init error: $e');
      _currentProvider = BaseMapProvider.defaultProvider;
    }
  }

  /// ネットワーク状態の監視初期化
  Future<void> _initConnectivity() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _updateConnectionStatus(result);
      
      _connectivitySubscription = _connectivity.onConnectivityChanged.listen(_updateConnectionStatus);
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Connectivity init error: $e');
    }
  }

  /// 接続状態更新
  void _updateConnectionStatus(List<ConnectivityResult> result) {
    final hasConnection = !result.contains(ConnectivityResult.none);
    final before = isNetworkAvailable;
    _isNetworkAvailable = hasConnection;
    // インターフェイスが戻ったら到達性は楽観的に true へ（次の取得で確かめる）
    if (hasConnection && !_reachable) {
      _reachable = true;
      _consecutiveFailures = 0;
      _unreachableSince = null;
    }
    if (before != isNetworkAvailable) {
      AppLogger.debug('[BaseMapService] Network status changed: ${isNetworkAvailable ? "Online" : "Offline (No Interface)"}');
      notifyListeners();
    }
  }

  /// キャッシュディレクトリの初期化
  Future<void> _initializeCacheDirectory() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _cacheDirectory = path.join(appDir.path, 'k_maps_tiles');

      final cacheDir = Directory(_cacheDirectory!);
      if (!cacheDir.existsSync()) {
        cacheDir.createSync(recursive: true);
      }
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Cache dir error: $e');
      rethrow;
    }
  }

  /// タイルキャッシュデータベースの初期化
  Future<void> _initializeTileCacheDatabase() async {
    try {
      // 旧GeoPackageからの移行チェック
      await _migrateFromGeoPackage();

      _tileCacheDb = TileCacheMBTiles();
      await _tileCacheDb!.initialize(_cacheDirectory!);
      await _dropStaleGeneratedCaches();
      final total = await _tileCacheDb!.getTotalTileCount();
      AppLogger.debug('[BaseMapService] Cache: $total tiles');
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ TileDB init error: $e');
      rethrow;
    }
  }

  /// 旧GeoPackage形式からMBTiles形式への移行
  Future<void> _migrateFromGeoPackage() async {
    if (_cacheDirectory == null) return;

    final oldDbPath = path.join(_cacheDirectory!, 'tile_cache.gpkg');
    final oldFile = File(oldDbPath);
    if (!oldFile.existsSync()) return;

    AppLogger.debug('[BaseMapService] 🔄 Migrating GeoPackage → MBTiles...');
    try {
      final oldDb = await openDatabase(oldDbPath, readOnly: true);

      // 旧DBからプロバイダー別にタイルを読み出し
      final providers = await oldDb.rawQuery(
        'SELECT DISTINCT provider_id FROM map_tiles',
      );

      final tempMbtiles = TileCacheMBTiles();
      await tempMbtiles.initialize(_cacheDirectory!);

      for (final providerRow in providers) {
        final providerId = providerRow['provider_id'] as String;
        final tiles = await oldDb.query(
          'map_tiles',
          columns: ['zoom_level', 'tile_column', 'tile_row', 'tile_data'],
          where: 'provider_id = ?',
          whereArgs: [providerId],
        );

        AppLogger.debug('[BaseMapService]   $providerId: ${tiles.length} tiles');

        for (final tile in tiles) {
          final z = tile['zoom_level'] as int;
          final tileCol = tile['tile_column'] as int;
          // tile_row は既にTMS形式で格納されているので逆変換してXYZのyに戻す
          final tileRow = tile['tile_row'] as int;
          final y = (1 << z) - 1 - tileRow;
          final data = tile['tile_data'] as Uint8List;

          await tempMbtiles.saveTile(
            providerId: providerId,
            z: z,
            x: tileCol,
            y: y,
            data: data,
          );
        }
      }

      await tempMbtiles.close();
      await oldDb.close();

      // 旧DBを削除
      await oldFile.delete();
      // WALファイルも削除
      final walFile = File('$oldDbPath-wal');
      if (walFile.existsSync()) await walFile.delete();
      final shmFile = File('$oldDbPath-shm');
      if (shmFile.existsSync()) await shmFile.delete();

      AppLogger.debug('[BaseMapService] ✅ Migration complete');
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Migration error: $e');
      // 移行失敗しても続行（旧DBは残す）
    }
  }

  /// 設定の読み込み
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isOfflineMode = prefs.getBool('basemap_offline_mode') ?? false;

      final layersJson = prefs.getString('basemap_layers');
      if (layersJson != null) {
        final decoded = json.decode(layersJson) as List<dynamic>;
        _layers = [
          for (final e in decoded)
            if (e is Map<String, Object?>) ?BaseMapLayer.fromJson(e),
        ];
      } else {
        // 2026-09-13 まで: プロバイダ → 重み（比で混ぜる）。その前: プロバイダ 1 つ
        final weightsJson = prefs.getString('basemap_weights');
        if (weightsJson != null) {
          final decoded = json.decode(weightsJson) as Map<String, dynamic>;
          _layers = BaseMapLayer.fromLegacyWeights(decoded.map((k, v) => MapEntry(k, (v as num).toInt())));
        }
        if (_layers.isEmpty) {
          final id = prefs.getString('basemap_provider_id');
          if (id != null && BaseMapProvider.getProviderById(id) != null) _layers = [BaseMapLayer(providerId: id)];
        }
      }
      if (_layers.isEmpty) _layers = [BaseMapLayer(providerId: BaseMapProvider.defaultProvider.id)];
      _syncCurrentProvider();
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Settings load error: $e');
    }
  }

  /// 設定の保存
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('basemap_provider_id', _currentProvider.id);
      await prefs.setBool('basemap_offline_mode', _isOfflineMode);
      await prefs.setString('basemap_layers', json.encode([for (final l in _layers) l.toJson()]));
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Settings save error: $e');
    }
  }

  Future<void> _commitLayers(List<BaseMapLayer> layers) async {
    _layers = layers;
    _syncCurrentProvider();
    await _saveSettings();
    notifyListeners();
  }

  /// 背景地図を 1 枚だけにする（そのプロバイダの不透明度 100）
  Future<void> setProvider(BaseMapProvider provider) => setLayers([BaseMapLayer(providerId: provider.id)]);

  /// レイヤの並びを丸ごと差し替える（下から上へ）。同じプロバイダが 2 枚あれば後のを落とす
  Future<void> setLayers(List<BaseMapLayer> layers) async {
    final seen = <String>{};
    final cleaned = [for (final l in layers) if (l.provider != null && seen.add(l.providerId)) l];
    if (listEquals(cleaned, _layers)) return;
    await _commitLayers(cleaned);
  }

  /// 一番上に足す（既にあれば何もしない）
  Future<void> addLayer(String providerId, {BaseMapBlend blend = BaseMapBlend.normal, int opacity = 100}) async {
    if (_layers.any((l) => l.providerId == providerId)) return;
    await setLayers([..._layers, BaseMapLayer(providerId: providerId, blend: blend, opacity: opacity)]);
  }

  Future<void> removeLayer(String providerId) => setLayers([for (final l in _layers) if (l.providerId != providerId) l]);

  Future<void> updateLayer(String providerId, BaseMapLayer Function(BaseMapLayer) change) =>
      setLayers([for (final l in _layers) l.providerId == providerId ? change(l) : l]);

  /// [from] 番目を [to] 番目へ（どちらも下からの番号）
  Future<void> moveLayer(int from, int to) async {
    if (from < 0 || from >= _layers.length || to < 0 || to >= _layers.length || from == to) return;
    final next = [..._layers];
    final l = next.removeAt(from);
    next.insert(to, l);
    await setLayers(next);
  }

  /// オフラインモードの切り替え
  Future<void> setOfflineMode(bool offline) async {
    if (_isOfflineMode != offline) {
      _isOfflineMode = offline;
      await _saveSettings();
      notifyListeners();
    }
  }

  /// タイルをキャッシュに保存
  Future<void> _cacheTile(
    String providerId,
    int z,
    int x,
    int y,
    Uint8List data,
  ) async {
    if (_tileCacheDb == null) return;
    
    try {
      await _tileCacheDb!.saveTile(
        providerId: providerId,
        z: z,
        x: x,
        y: y,
        data: data,
      );
    } catch (e) {
      AppLogger.debug('[TILE] ❌ Cache save error: $e');
    }
  }

  /// キャッシュからタイルを取得
  Future<Uint8List?> _getCachedTile(
    String providerId,
    int z,
    int x,
    int y, {
    bool allowCrossPlatformCache = false,
  }) async {
    if (_tileCacheDb == null) return null;
    
    try {
      // 指定プロバイダーのキャッシュを取得
      final data = await _tileCacheDb!.getTile(
        providerId: providerId,
        z: z,
        x: x,
        y: y,
      );
      
      if (data != null) {
        // データサイズチェック
        if (data.length < 100) {
          AppLogger.debug('[TILE] ⚠️ Corrupted cache (too small)');
          return null;
        }
        
        // PNGヘッダーチェック
        if (data.length >= 8) {
          // ヘッダーチェックは行わず、データサイズのみで簡易チェックとする
          // サーバーによっては異なるフォーマット（WebPなど）を返す可能性や、
          // ヘッダーが微妙に異なる場合も考慮して、厳密なチェックは廃止する。
          // decodeImageで失敗すれば最終的に弾かれるため問題ない。
        }
        
        return data;
      }
      
      return null;
    } catch (e) {
      AppLogger.debug('[TILE] ❌ Cache read error: $e');
      return null;
    }
  }

  /// タイルをダウンロード（キャッシュ機能付き・フォールバック対応）
  Future<Uint8List?> getTile(
    BaseMapProvider provider,
    int z,
    int x,
    int y,
  ) async {
    // 同じタイルが同時に何度も頼まれる（等高線の生成が同じ DEM を 4 回、テクスチャの層が同じ地図を…）。
    // キャッシュに書く前に次が来るとみんなネットへ行くので、進行中の要求は 1 本にまとめる（2026-09-13 に同じ DEM が 4〜5 回）
    final inflightKey = '${provider.id}/$z/$x/$y';
    final running = _inflight[inflightKey];
    if (running != null) return running;
    final future = _inflight[inflightKey] = _getTileUncoalesced(provider, z, x, y);
    try {
      return await future;
    } finally {
      final _ = _inflight.remove(inflightKey); // Map.remove は Future を返す（unawaited_futures 避け）
    }
  }

  final Map<String, Future<Uint8List?>> _inflight = {};

  Future<Uint8List?> _getTileUncoalesced(BaseMapProvider provider, int z, int x, int y) async {
    // 標高タイル（Terrarium）は親を拡大して返さない。RGB を拡大すると高さがブロック状の階段になり、
    // 3D の崖にギザギザの溝が出る（Pixel 9 で実測）。3D 側は自前のピラミッドで親タイルを正しい形で描く
    if (provider.type == BaseMapType.generated) {
      return z < provider.minZoom || z > provider.maxZoom ? null : _getGeneratedTile(provider, z, x, y);
    }
    final noFallback = provider.type == BaseMapType.terrain;

    // プロバイダーの最大ズームレベルを超えている場合は直接フォールバック
    if (z > provider.maxZoom) {
      return noFallback ? null : _getTileWithFallback(provider, z, x, y);
    }

    // まず通常のタイル取得を試行
    final normalTile = await _getTileInternal(provider, z, x, y);
    if (normalTile != null) {
      return normalTile;
    }

    // 通常のタイル取得に失敗した場合、フォールバック機能を使用
    return noFallback ? null : _getTileWithFallback(provider, z, x, y);
  }

  /// 内部用のタイル取得メソッド（フォールバックなし）
  Future<Uint8List?> _getTileInternal(
    BaseMapProvider provider,
    int z,
    int x,
    int y, {
    bool allowNetworkAccess = true,
    int retryCount = 0,
  }) async {
    final swTile = Stopwatch()..start();
    try {
      final cachedData = await _getCachedTile(provider.id, z, x, y);
      final cacheMs = swTile.elapsedMilliseconds;
      if (cachedData != null) {
        if (cacheMs > 100) AppLogger.debug('[TILE] cache hit ${provider.id} $z/$x/$y ${cacheMs}ms');
        return cachedData;
      }

      // 明示的オフラインモードまたはネットワークアクセス禁止の場合のみ終了
      if (_isOfflineMode || !allowNetworkAccess) {
        return null;
      }

      // 到達不能と判定中は、次の試行時刻まで待たずに諦める（1タイルごとに
      // タイムアウトを待つと、圏外で画面が分単位で固まる）
      if (_inUnreachableCooldown) return null;

      // ネットワークからダウンロード（connectivity_plusはヒントのみ、短いタイムアウトで実際に試行）
      final timeout = _reachable && _isNetworkAvailable ? 10 : 3;
      final url = provider.urlTemplate
          .replaceAll('{z}', z.toString())
          .replaceAll('{x}', x.toString())
          .replaceAll('{y}', y.toString());

      final response = await _http
          .get(
            Uri.parse(url),
            headers: {
              // アプリを特定できるUAを常に送る（OSMポリシー要件。GSIにも礼儀として）。
              // webはブラウザのUAが付く上、User-Agentは禁止ヘッダなので送らない
              if (!kIsWeb) 'User-Agent': kTileUserAgent,
            },
          )
          .timeout(Duration(seconds: timeout));

      final httpMs = swTile.elapsedMilliseconds - cacheMs;
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        _noteFetchSuccess();
        final data = response.bodyBytes;
        
        // ダウンロードデータの妥当性チェック
        if (data.length < 100) {
          return null;
        }
        
        // PNGヘッダーチェック
        if (data.length >= 8) {
          // ヘッダーチェックは行わず、データサイズのみで簡易チェックとする
          // サーバーによっては異なるフォーマット（WebPなど）を返す可能性や、
          // ヘッダーが微妙に異なる場合も考慮して、厳密なチェックは廃止する。
          // decodeImageで失敗すれば最終的に弾かれるため問題ない。
        }

        await _cacheTile(provider.id, z, x, y, data);
        if (swTile.elapsedMilliseconds > 300) {
          AppLogger.debug('[TILE] ${provider.id} $z/$x/$y cache ${cacheMs}ms http ${httpMs}ms write ${swTile.elapsedMilliseconds - cacheMs - httpMs}ms');
        }

        return data;
      } else if (response.statusCode == 404) {
        if (swTile.elapsedMilliseconds > 300) AppLogger.debug('[TILE] ${provider.id} $z/$x/$y 404 cache ${cacheMs}ms http ${httpMs}ms');
        // 無いものは無い（標高タイルの整備範囲外など）。粘ると 1 枚 1.5 秒になる
        _noteFetchSuccess();
        return null;
      } else {
        // ネットワーク取得失敗時にキャッシュを再確認（別プロバイダーや古いキャッシュの可能性）
        final fallbackCachedData = await _getCachedTile(
          provider.id,
          z,
          x,
          y,
          allowCrossPlatformCache: true,
        );
        if (fallbackCachedData != null) {
          return fallbackCachedData;
        }

        // リトライ機能（最大2回）
        if (retryCount < 2) {
          final delayMs = 500 * (retryCount + 1);
          await Future.delayed(Duration(milliseconds: delayMs));
          return await _getTileInternal(
            provider,
            z,
            x,
            y,
            allowNetworkAccess: allowNetworkAccess,
            retryCount: retryCount + 1,
          );
        }

        return null;
      }
    } catch (e) {
      AppLogger.debug('[TILE] ❌ Network error');
      _noteFetchFailure();
      
      // エラー時もキャッシュを確認（ネットワークエラーでもキャッシュがあれば利用）
      final errorFallbackData = await _getCachedTile(
        provider.id,
        z,
        x,
        y,
        allowCrossPlatformCache: true,
      );
      if (errorFallbackData != null) {
        return errorFallbackData;
      }

      // リトライ機能（エラー時も適用。到達不能と判定したら粘らない）
      if (retryCount < 1 && allowNetworkAccess && _reachable) {
        await Future.delayed(const Duration(milliseconds: 1000));
        return _getTileInternal(
          provider,
          z,
          x,
          y,
          allowNetworkAccess: allowNetworkAccess,
          retryCount: retryCount + 1,
        );
      }

      return null;
    }
  }

  /// フォールバック機能付きタイル取得
  ///
  /// 目的のタイルが取れないとき、先祖のタイル（1〜[maxFallbackLevels] 段上）から
  /// 該当部分を切り出して拡大したものを返す。
  ///
  /// ⚠ 拡大したタイルは**キャッシュに保存しない**。以前は目的の z/x/y の
  ///   正規タイルとして保存していたため、一度でも圏外・404 を踏んだ場所は
  ///   電波が戻っても永久にボケたまま（キャッシュ優先で本物を取りに行かない）
  ///   になっていた。「エリアによってズームが違って見える」の正体。
  /// ⚠ 先祖は常に**目的のタイル**に対して切り出す。以前は親が無いとき
  ///   「親のタイルを祖父から作る」再帰になっていて、別の領域の画像が返っていた。
  Future<Uint8List?> _getTileWithFallback(
    BaseMapProvider provider,
    int z,
    int x,
    int y, {
    int maxFallbackLevels = 5,
  }) async {
    for (var level = 1; level <= maxFallbackLevels; level++) {
      final ancestorZ = z - level;
      if (ancestorZ < provider.minZoom) break;
      final ancestorX = x >> level;
      final ancestorY = y >> level;

      final ancestorTile = await _getTileInternal(
        provider,
        ancestorZ,
        ancestorX,
        ancestorY,
        allowNetworkAccess: !_isOfflineMode,
      );
      if (ancestorTile == null) continue;

      final scaled = await _extractAndScaleTile(
        ancestorTile,
        z,
        x,
        y,
        ancestorZ,
        ancestorX,
        ancestorY,
      );
      if (scaled != null) return scaled;
    }
    return null;
  }

  /// 親タイルから指定領域を切り出してスケールアップ
  /// 
  /// 画像処理はCPU負荷が高いため、compute関数を使用して別Isolateで実行します。
  Future<Uint8List?> _extractAndScaleTile(
    Uint8List parentTileData,
    int targetZ,
    int targetX,
    int targetY,
    int parentZ,
    int parentX,
    int parentY,
  ) async {
    try {
      return await compute(_processTileExtraction, {
        'parentTileData': parentTileData,
        'targetZ': targetZ,
        'targetX': targetX,
        'targetY': targetY,
        'parentZ': parentZ,
        'parentX': parentX,
        'parentY': parentY,
      });
    } catch (e) {
      AppLogger.debug('[TILE] ❌ Scaling error (compute): $e');
      return null;
    }
  }

  /// キャッシュサイズを取得（MB単位）
  Future<double> getCacheSizeMB() async {
    if (_tileCacheDb == null) return 0.0;
    
    try {
      final sizeBytes = await _tileCacheDb!.getCacheSize();
      return sizeBytes / (1024 * 1024);
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Size error: $e');
      return 0.0;
    }
  }

  /// キャッシュクリア
  Future<void> clearCache({String? providerId}) async {
    if (_tileCacheDb == null) return;
    
    try {
      await _tileCacheDb!.clearCache(providerId: providerId);
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Clear error: $e');
    }
  }

  /// キャッシュされているタイル数を取得
  int getCachedTileCount({String? providerId}) {
    return 0;
  }

  /// プロバイダー別のキャッシュ統計を取得
  Future<Map<String, int>> getCacheStatistics() async {
    if (_tileCacheDb == null) return {};
    
    try {
      return await _tileCacheDb!.getStatistics();
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Stats error: $e');
      return {};
    }
  }

  /// 詳細なキャッシュ統計を取得（デバッグ用）
  Future<Map<String, Map<String, dynamic>>> getDetailedCacheStatistics() async {
    if (_tileCacheDb == null) return {};
    
    try {
      final stats = await _tileCacheDb!.getStatistics();
      
      final detailedStats = <String, Map<String, dynamic>>{};
      for (final entry in stats.entries) {
        detailedStats[entry.key] = {
          'count': entry.value,
          'provider': (BaseMapProvider.getProviderByCacheId(entry.key) ?? BaseMapProvider.getProviderById(entry.key))?.name ?? entry.key,
        };
      }
      
      return detailedStats;
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Detailed stats error: $e');
      return {};
    }
  }

  /// キャッシュ検証（破損タイルの確認・修復）
  Future<Map<String, dynamic>> validateAndRepairCache() async {
    if (_tileCacheDb == null) {
      return {
        'totalTiles': 0,
        'validTiles': 0,
        'invalidTiles': 0,
        'removedTiles': 0,
      };
    }
    
    try {
      return await _tileCacheDb!.validateAndRepair();
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Validation error: $e');
      return {
        'totalTiles': 0,
        'validTiles': 0,
        'invalidTiles': 0,
        'removedTiles': 0,
      };
    }
  }

  /// 緯度経度からタイル座標を取得
  math.Point<int> _getTileCoordinates(double lat, double lon, int zoom) {
    final n = math.pow(2, zoom);
    final x = ((lon + 180.0) / 360.0 * n).floor();
    final latRad = lat * math.pi / 180.0;
    final y = ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) / 2.0 * n).floor();
    return math.Point(x, y);
  }

  /// ダウンロードキャンセル
  void cancelDownload() {
    if (_isDownloading) {
      _cancelDownload = true;
      notifyListeners();
    }
  }

  /// エリア推定（タイル数を計算）
  Map<String, int> estimateDownloadSize({
    required LatLng center,
    required double radiusMeters,
    required int minZoom,
    required int maxZoom,
  }) {
    int totalTiles = 0;
    
    // 半径を緯度経度の差分に変換（概算）
    // 緯度1度 ≒ 111km, 経度1度 ≒ 111km * cos(lat)
    final latDiff = radiusMeters / 111000.0;
    final lonDiff = radiusMeters / (111000.0 * math.cos(center.latitude * math.pi / 180.0));

    final north = center.latitude + latDiff;
    final south = center.latitude - latDiff;
    final east = center.longitude + lonDiff;
    final west = center.longitude - lonDiff;

    for (var z = minZoom; z <= maxZoom; z++) {
      final topLeft = _getTileCoordinates(north, west, z);
      final bottomRight = _getTileCoordinates(south, east, z);
      
      final tilesX = (bottomRight.x - topLeft.x).abs() + 1;
      final tilesY = (bottomRight.y - topLeft.y).abs() + 1;
      
      totalTiles += tilesX * tilesY;
    }

    return {
      'totalTiles': totalTiles,
    };
  }

  /// エリア一括ダウンロード実行 (並列処理対応)
  /// 一括ダウンロードの対象: 見えているレイヤのプロバイダ（OSM は方針で除外。等高線などの生成プロバイダは作ってキャッシュに入れる）
  List<BaseMapProvider> get downloadableProviders =>
      [for (final (p, _) in activeLayers) if (p.type != BaseMapType.openStreetMap) p];

  /// [providers] を省くと [downloadableProviders]（見えているレイヤ全部）。タイル数は 枚数 × プロバイダ数
  Stream<Map<String, dynamic>> downloadArea({
    required LatLng center,
    required double radiusMeters,
    required int minZoom,
    required int maxZoom,
    List<BaseMapProvider>? providers,
  }) async* {
    if (_isDownloading) {
      yield {'status': 'error', 'message': t.services.downloadInProgress};
      return;
    }

    _isDownloading = true;
    _cancelDownload = false;
    notifyListeners();

    // 半径を緯度経度の差分に変換
    final latDiff = radiusMeters / 111000.0;
    final lonDiff = radiusMeters / (111000.0 * math.cos(center.latitude * math.pi / 180.0));

    final north = center.latitude + latDiff;
    final south = center.latitude - latDiff;
    final east = center.longitude + lonDiff;
    final west = center.longitude - lonDiff;

    // ダウンロード対象のタイルリストを作成
    final tilesToDownload = <_TileRequest>[];
    
    for (var z = minZoom; z <= maxZoom; z++) {
      final topLeft = _getTileCoordinates(north, west, z);
      final bottomRight = _getTileCoordinates(south, east, z);

      final minX = math.min(topLeft.x, bottomRight.x);
      final maxX = math.max(topLeft.x, bottomRight.x);
      final minY = math.min(topLeft.y, bottomRight.y);
      final maxY = math.max(topLeft.y, bottomRight.y);

      for (var x = minX; x <= maxX; x++) {
        for (var y = minY; y <= maxY; y++) {
          tilesToDownload.add(_TileRequest(z, x, y));
        }
      }
    }

    final targets = providers ?? downloadableProviders;
    final totalTiles = tilesToDownload.length * targets.length;
    int processedTiles = 0;
    int downloadedTiles = 0;
    int skippedTiles = 0;
    int errorTiles = 0;

    yield {
      'status': 'start',
      'total': totalTiles,
      'processed': 0,
    };

    // 並列処理の設定
    // OpenStreetMapの推奨は最大2スレッドだが、ユーザーの要望により4スレッドまで許可
    // 待機時間を短くしてスループットを上げる
    const int maxConcurrentDownloads = 4;
    final activeFutures = <Future<void>>[];
    final queue = [for (final p in targets) for (final t in tilesToDownload) (p, t)];

    try {
      while (queue.isNotEmpty || activeFutures.isNotEmpty) {
        if (_cancelDownload) break;

        // キューから取り出して並列実行数までタスクを追加
        while (activeFutures.length < maxConcurrentDownloads && queue.isNotEmpty) {
          final (provider, tile) = queue.removeAt(0);
          late final Future<void> future;
          future = _processSingleTile(
            provider, 
            tile, 
            (result) {
              // 完了コールバック
              processedTiles++;
              if (result == 'downloaded') {
                downloadedTiles++;
              } else if (result == 'skipped') {
                skippedTiles++;
              } else {
                errorTiles++;
              }
            }
          ).then((_) {
            // 完了したらリストから自分自身を削除
            activeFutures.remove(future);
          });
          
          activeFutures.add(future);
        }
        
        // スロットが空くか、全タスク完了まで待機
        if (activeFutures.isNotEmpty) {
          await Future.any(activeFutures);
          
          // 進捗通知 (高頻度すぎると重くなるので間引く)
          if (processedTiles % 5 == 0 || processedTiles == totalTiles) {
             yield {
              'status': 'progress',
              'total': totalTiles,
              'processed': processedTiles,
              'downloaded': downloadedTiles,
              'skipped': skippedTiles,
              'errors': errorTiles,
              'percent': (processedTiles / totalTiles * 100).toStringAsFixed(1),
            };
          }
        }
      }

      yield {
        'status': _cancelDownload ? 'cancelled' : 'completed',
        'total': totalTiles,
        'processed': processedTiles,
        'downloaded': downloadedTiles,
        'skipped': skippedTiles,
        'errors': errorTiles,
      };

    } catch (e) {
      AppLogger.debug('[Downloader] Critical error: $e');
      yield {
        'status': 'error',
        'message': e.toString(),
      };
    } finally {
      _isDownloading = false;
      _cancelDownload = false;
      notifyListeners();
    }
  }

  /// 単一タイルの処理（並列実行用）
  Future<void> _processSingleTile(
    BaseMapProvider provider, 
    _TileRequest tile,
    Function(String) onComplete,
  ) async {
    try {
      // その段を持たないプロバイダは飛ばす（等高線は z9〜、地理院は z18 まで）
      if (tile.z < provider.minZoom || tile.z > provider.maxZoom) {
        onComplete('skipped');
        return;
      }
      // キャッシュ確認
      final cached = await _getCachedTile(provider.cacheId, tile.z, tile.x, tile.y);
      if (cached != null) {
        onComplete('skipped');
        return;
      }
      // 生成プロバイダ（等高線）は作ってキャッシュに入れる（DEM は取りに行く）
      if (provider.type == BaseMapType.generated) {
        final made = await getTile(provider, tile.z, tile.x, tile.y);
        onComplete(made != null ? 'downloaded' : 'error');
        return;
      }
      // ダウンロード実行
      final data = await _getTileInternal(
        provider, 
        tile.z, tile.x, tile.y, 
        allowNetworkAccess: true,
        retryCount: 2,
      );
      
      if (data != null) {
        // BAN対策: 短い待機時間を入れる
        // 4並列 × 50ms待機 = 理論最大80req/sec (通信時間除く)
        // 実際は通信時間があるため、サーバー負荷はそこまで高くならないはず
        await Future.delayed(const Duration(milliseconds: 50));
        onComplete('downloaded');
      } else {
        onComplete('error');
      }
    } catch (e) {
      AppLogger.debug('[Downloader] ❌ Download failed (Offline/Network Error)');
      onComplete('error');
    }
  }

  @override
  void dispose() {
    _http.close();
    _connectivitySubscription?.cancel();
    _tileCacheDb?.close();
    super.dispose();
  }
}

/// タイルリクエスト管理用クラス
class _TileRequest {
  final int z;
  final int x;
  final int y;
  
  _TileRequest(this.z, this.x, this.y);
}

