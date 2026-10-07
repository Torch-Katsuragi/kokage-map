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
import '../core/terrain/terrain_worker.dart';
import '../i18n/strings.g.dart';
import '../models/basemap_layer.dart';
import '../models/basemap_provider.dart';
import 'tile_cache_mbtiles.dart';

/// Isolateで実行するための画像処理関数（トップレベル関数・同期。常駐の TerrainWorker で回す）
Uint8List? _processTileExtraction(Map<String, dynamic> params) {
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
      return Uint8List.fromList(img.encodePng(resizedImage, level: 1));
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
    return Uint8List.fromList(img.encodePng(resizedImage, level: 1));
  } catch (e) {
    AppLogger.debug('[TILE-ISO] ❌ Scaling error: $e');
    return null;
  }
}

/// 一括ダウンロードの 1 枚の結果
enum _DownloadResult { downloaded, skipped, error }

/// 背景地図管理サービス
class BaseMapService extends ChangeNotifier {
  /// タイル取得用の HTTP クライアント。1 つを使い回して接続（TLS）を保つ。
  /// `http.get` はそのたびに接続を張り直すので、Pixel 9 で 1 枚 0.4〜1.4 秒掛かっていた
  final http.Client _http = http.Client();

  /// アプリを特定できるUAを常に送る（OSMポリシー要件。GSIにも礼儀として）。
  /// webはブラウザのUAが付く上、User-Agentは禁止ヘッダなので送らない
  static const Map<String, String> _tileHeaders = {if (!kIsWeb) 'User-Agent': kTileUserAgent};

  static final BaseMapService _instance = BaseMapService._internal();
  factory BaseMapService() => _instance;
  BaseMapService._internal();

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

  /// 一番下の見えているレイヤのプロバイダ（互換用。一括ダウンロードの既定 URL など）
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
      if (data != null && TileCacheMBTiles.isPlausibleTile(data)) await _cacheTile(provider.cacheId, z, x, y, data);
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
    // 本体が無く -wal などの残骸だけのものも拾う
    final cached = await db.cachedProviderIds();
    for (final p in BaseMapProvider.availableProviders) {
      if (p.type != BaseMapType.generated || p.cacheId == p.id) continue;
      for (final name in cached) {
        if (name != p.cacheId && name.startsWith('${p.id}_v')) {
          AppLogger.debug('[BaseMapService] 古い生成キャッシュを消す: $name');
          await db.clearCache(providerId: name);
        }
      }
    }
  }

  /// ネットが使えるか。「インターフェイスがある」かつ「実際に届いている」
  bool get isNetworkAvailable => _isNetworkAvailable && _reachable;

  /// 実到達性。connectivity_plus は**インターフェイスの有無**しか見ないので、
  /// 圏外でもモバイル回線が「接続中」なら true のまま。タイル取得が
  /// [_failuresToGoOffline] 回続けて失敗（タイムアウト等）したら false に落とす。
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

  /// 初期化の実行中・済みの印。起動時（main）と地図ページの両方から呼ばれるので、2 回目以降は同じ Future を返す
  /// （以前は呼ばれるたびにキャッシュ DB を開き直し、全タイルを数え、ネットワークの購読を足していた）
  Future<void>? _initialization;

  /// サービス初期化。何度呼んでもよい（初期化は 1 回だけ。失敗していたら次の呼び出しでやり直す）
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      // タイルキャッシュはローカルファイルシステムが前提。
      // web には無いので飛ばす（ブラウザのHTTPキャッシュに任せる）。
      // ⚠ ここで例外を投げると _loadSettings まで到達せず、
      //   _layers が空＝背景地図が1枚も出なくなる。
      if (PlatformCapabilities.hasTileCache) {
        // キャッシュディレクトリの設定
        await _initializeCacheDirectory();

        // タイルキャッシュの初期化
        await _initializeTileCacheDatabase();
      }

      // 設定の読み込み
      await _loadSettings();

      // ネットワーク状態の監視開始（初期状態を確定してから続行）
      await _initConnectivity();
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Init error: $e');
      _currentProvider = BaseMapProvider.defaultProvider;
      _initialization = null;
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
      final dir = path.join(appDir.path, 'k_maps_tiles');
      await Directory(dir).create(recursive: true);
      _cacheDirectory = dir;
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

      final db = TileCacheMBTiles();
      await db.initialize(_cacheDirectory!);
      _tileCacheDb = db;
      await _dropStaleGeneratedCaches();
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
    if (!await oldFile.exists()) return;

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
          // tile_row は既にTMS形式で格納されているので逆変換してXYZのyに戻す
          final y = (1 << z) - 1 - (tile['tile_row'] as int);
          await tempMbtiles.saveTile(
            providerId: providerId,
            z: z,
            x: tile['tile_column'] as int,
            y: y,
            data: tile['tile_data'] as Uint8List,
          );
        }
      }

      await tempMbtiles.close();
      await oldDb.close();

      // 旧DBを削除（WAL の相方も）
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = File('$oldDbPath$suffix');
        if (await file.exists()) await file.delete();
      }

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

  // =============================================
  // タイルの取得
  // =============================================

  /// タイルをキャッシュに保存
  Future<void> _cacheTile(String cacheId, int z, int x, int y, Uint8List data) async {
    try {
      await _tileCacheDb?.saveTile(providerId: cacheId, z: z, x: x, y: y, data: data);
    } catch (e) {
      AppLogger.debug('[TILE] ❌ Cache save error: $e');
    }
  }

  /// キャッシュからタイルを取得（壊れたタイルはキャッシュ側で弾いて消す）
  Future<Uint8List?> _getCachedTile(String cacheId, int z, int x, int y) async =>
      _tileCacheDb?.getTile(providerId: cacheId, z: z, x: x, y: y);

  /// 進行中の要求。同じ鍵の要求が重なったら 1 本にまとめる
  final Map<String, Future<Uint8List?>> _inflight = {};

  Future<Uint8List?> _coalesce(String key, Future<Uint8List?> Function() run) {
    final running = _inflight[key];
    if (running != null) return running;
    final future = _inflight[key] = run();
    future.whenComplete(() {
      _inflight.remove(key);
    }).ignore();
    return future;
  }

  /// タイルを取得（キャッシュ機能付き・フォールバック対応）
  ///
  /// 同じタイルが同時に何度も頼まれる（等高線の生成が同じ DEM を 4 回、テクスチャの層が同じ地図を…）。
  /// キャッシュに書く前に次が来るとみんなネットへ行くので、進行中の要求は 1 本にまとめる（2026-09-13 に同じ DEM が 4〜5 回）
  Future<Uint8List?> getTile(BaseMapProvider provider, int z, int x, int y) =>
      _coalesce('tile:${provider.id}/$z/$x/$y', () => _getTileUncoalesced(provider, z, x, y));

  Future<Uint8List?> _getTileUncoalesced(BaseMapProvider provider, int z, int x, int y) async {
    if (provider.type == BaseMapType.generated) {
      return z < provider.minZoom || z > provider.maxZoom ? null : _getGeneratedTile(provider, z, x, y);
    }
    // プロバイダーの最大ズームレベルを超えている場合は取りに行かず直接フォールバック
    final tile = z > provider.maxZoom ? null : await _fetchTileShared(provider, z, x, y);
    // 標高タイル（Terrarium）は親を拡大して返さない。RGB を拡大すると高さがブロック状の階段になり、
    // 3D の崖にギザギザの溝が出る（Pixel 9 で実測）。3D 側は自前のピラミッドで親タイルを正しい形で描く
    if (tile != null || provider.type == BaseMapType.terrain) return tile;
    return _getTileWithFallback(provider, z, x, y);
  }

  /// [_fetchTile] の、同じタイルの要求を 1 本にまとめる版。隣り合う子タイルのフォールバックは同じ先祖を同時に取りに行くので
  Future<Uint8List?> _fetchTileShared(BaseMapProvider provider, int z, int x, int y) =>
      _coalesce('fetch:${provider.cacheId}/$z/$x/$y', () => _fetchTile(provider, z, x, y));

  /// キャッシュ → ネット（フォールバックなし）。
  ///
  /// [attempt] は何回目の試行から始めるか。HTTP のエラー（404 以外）は 2 回目まで、通信の例外は 1 回目まで間を置いて取り直す
  /// （一括ダウンロードは 2 から始めて取り直さない）。取り直さずに諦めるときはキャッシュをもう一度見る（その間に入ったかもしれない）。
  /// [checkCache] が false なら最初の試行ではキャッシュを見ない（呼び出し側で見たばかりのとき）
  Future<Uint8List?> _fetchTile(
    BaseMapProvider provider,
    int z,
    int x,
    int y, {
    int attempt = 0,
    bool checkCache = true,
  }) async {
    for (var first = true;; first = false, attempt++) {
      final sw = Stopwatch()..start();
      if (checkCache || !first) {
        final cached = await _getCachedTile(provider.cacheId, z, x, y);
        if (cached != null) {
          if (sw.elapsedMilliseconds > 100) AppLogger.debug('[TILE] cache hit ${provider.id} $z/$x/$y ${sw.elapsedMilliseconds}ms');
          return cached;
        }
      }
      final cacheMs = sw.elapsedMilliseconds;

      // 明示的オフラインモードなら取りに行かない
      if (_isOfflineMode) return null;

      // 到達不能と判定中は、次の試行時刻まで待たずに諦める（1タイルごとに
      // タイムアウトを待つと、圏外で画面が分単位で固まる）
      if (_inUnreachableCooldown) return null;

      // ネットワークからダウンロード（connectivity_plusはヒントのみ、短いタイムアウトで実際に試行）
      final timeout = _reachable && _isNetworkAvailable ? 10 : 3;
      final http.Response response;
      try {
        response = await _http
            .get(Uri.parse(provider.tileUrl(z, x, y)), headers: _tileHeaders)
            .timeout(Duration(seconds: timeout));
      } catch (e) {
        AppLogger.debug('[TILE] ❌ Network error');
        _noteFetchFailure();
        // 取り直す（到達不能と判定したら粘らない）
        if (attempt < 1 && _reachable) {
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          continue;
        }
        // ネットワークエラーでもキャッシュがあれば利用
        return _getCachedTile(provider.cacheId, z, x, y);
      }

      final httpMs = sw.elapsedMilliseconds - cacheMs;
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        _noteFetchSuccess();
        final data = response.bodyBytes;
        // 小さすぎるものは壊れている（形式は見ない。WebP などを返すサーバーもある。読めなければ描く側で弾く）
        if (!TileCacheMBTiles.isPlausibleTile(data)) return null;

        await _cacheTile(provider.cacheId, z, x, y, data);
        if (sw.elapsedMilliseconds > 300) {
          AppLogger.debug('[TILE] ${provider.id} $z/$x/$y cache ${cacheMs}ms http ${httpMs}ms write ${sw.elapsedMilliseconds - cacheMs - httpMs}ms');
        }
        return data;
      }
      if (response.statusCode == 404) {
        if (sw.elapsedMilliseconds > 300) AppLogger.debug('[TILE] ${provider.id} $z/$x/$y 404 cache ${cacheMs}ms http ${httpMs}ms');
        // 無いものは無い（標高タイルの整備範囲外など）。粘ると 1 枚 1.5 秒になる
        _noteFetchSuccess();
        return null;
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        continue;
      }
      return _getCachedTile(provider.cacheId, z, x, y);
    }
  }

  /// フォールバック機能付きタイル取得
  ///
  /// 目的のタイルが取れないとき、先祖のタイル（1〜[maxFallbackLevels] 段上）から
  /// 該当部分を切り出して拡大したものを返す。
  /// プロバイダの最大ズームより上の段は取りに行かない（サーバーに無い。地理院は 404、OSM は 400 を返し、
  /// 400 は取り直しで 1.5 秒待っていた。2026-10-07 に curl で確認）。
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
      if (ancestorZ > provider.maxZoom) continue;
      final ancestorX = x >> level;
      final ancestorY = y >> level;

      final ancestorTile = await _fetchTileShared(provider, ancestorZ, ancestorX, ancestorY);
      if (ancestorTile == null) continue;

      final scaled = await _extractAndScaleTile(ancestorTile, z, x, y, ancestorZ, ancestorX, ancestorY);
      if (scaled != null) return scaled;
    }
    return null;
  }

  /// 親タイルから指定領域を切り出してスケールアップ
  ///
  /// 画像処理は常駐の作業用 isolate（TerrainWorker）で回す。以前は compute でタイルごとに isolate を起こしていた。
  /// 書き戻す PNG は保存しない一時データなので圧縮は軽く（level 1）
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
      return await TerrainWorker.instance.run<Map<String, dynamic>, Uint8List?>(_processTileExtraction, {
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

  // =============================================
  // キャッシュの管理（設定画面）
  // =============================================

  /// キャッシュサイズを取得（MB単位）
  Future<double> getCacheSizeMB() async {
    final db = _tileCacheDb;
    if (db == null) return 0.0;
    try {
      return await db.getCacheSize() / (1024 * 1024);
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Size error: $e');
      return 0.0;
    }
  }

  /// キャッシュクリア
  Future<void> clearCache({String? providerId}) async {
    try {
      await _tileCacheDb?.clearCache(providerId: providerId);
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Clear error: $e');
    }
  }

  /// プロバイダー別のキャッシュ統計を取得
  Future<Map<String, int>> getCacheStatistics() async {
    final db = _tileCacheDb;
    if (db == null) return {};
    try {
      return await db.getStatistics();
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Stats error: $e');
      return {};
    }
  }

  /// キャッシュ検証（破損タイルの確認・修復）
  Future<Map<String, dynamic>> validateAndRepairCache() async {
    const empty = {'totalTiles': 0, 'validTiles': 0, 'invalidTiles': 0, 'removedTiles': 0};
    final db = _tileCacheDb;
    if (db == null) return empty;
    try {
      return await db.validateAndRepair();
    } catch (e) {
      AppLogger.debug('[BaseMapService] ❌ Validation error: $e');
      return empty;
    }
  }

  // =============================================
  // エリア一括ダウンロード
  // =============================================

  /// 緯度経度からタイル座標を取得
  static math.Point<int> _getTileCoordinates(double lat, double lon, int zoom) {
    final n = math.pow(2, zoom);
    final x = ((lon + 180.0) / 360.0 * n).floor();
    final latRad = lat * math.pi / 180.0;
    final y = ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) / 2.0 * n).floor();
    return math.Point(x, y);
  }

  /// 中心と半径の範囲に掛かるタイルの範囲（ズームごと）
  static List<({int z, int minX, int maxX, int minY, int maxY})> _tileRanges(
    LatLng center,
    double radiusMeters,
    int minZoom,
    int maxZoom,
  ) {
    // 半径を緯度経度の差分に変換（概算）
    // 緯度1度 ≒ 111km, 経度1度 ≒ 111km * cos(lat)
    final latDiff = radiusMeters / 111000.0;
    final lonDiff = radiusMeters / (111000.0 * math.cos(center.latitude * math.pi / 180.0));

    final north = center.latitude + latDiff;
    final south = center.latitude - latDiff;
    final east = center.longitude + lonDiff;
    final west = center.longitude - lonDiff;

    return [
      for (var z = minZoom; z <= maxZoom; z++)
        if ((_getTileCoordinates(north, west, z), _getTileCoordinates(south, east, z)) case (final a, final b))
          (
            z: z,
            minX: math.min(a.x, b.x),
            maxX: math.max(a.x, b.x),
            minY: math.min(a.y, b.y),
            maxY: math.max(a.y, b.y),
          ),
    ];
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
    var totalTiles = 0;
    for (final r in _tileRanges(center, radiusMeters, minZoom, maxZoom)) {
      totalTiles += (r.maxX - r.minX + 1) * (r.maxY - r.minY + 1);
    }
    return {'totalTiles': totalTiles};
  }

  /// 一括ダウンロードの対象: 見えているレイヤのプロバイダ（OSM は方針で除外。等高線などの生成プロバイダは作ってキャッシュに入れる）
  List<BaseMapProvider> get downloadableProviders =>
      [for (final (p, _) in activeLayers) if (p.type != BaseMapType.openStreetMap) p];

  /// エリア一括ダウンロード実行 (並列処理対応)
  ///
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

    // ダウンロード対象のタイルリストを作成
    final tiles = [
      for (final r in _tileRanges(center, radiusMeters, minZoom, maxZoom))
        for (var x = r.minX; x <= r.maxX; x++)
          for (var y = r.minY; y <= r.maxY; y++) (z: r.z, x: x, y: y),
    ];

    final targets = providers ?? downloadableProviders;
    final queue = [for (final p in targets) for (final t in tiles) (p, t)];
    final totalTiles = queue.length;
    var next = 0;
    var processedTiles = 0;
    var downloadedTiles = 0;
    var skippedTiles = 0;
    var errorTiles = 0;

    yield {
      'status': 'start',
      'total': totalTiles,
      'processed': 0,
    };

    // 並列処理の設定
    // OpenStreetMapの推奨は最大2スレッドだが、ユーザーの要望により4スレッドまで許可
    // 待機時間を短くしてスループットを上げる
    const int maxConcurrentDownloads = 4;
    final activeFutures = <Future<void>>{};

    try {
      while (next < queue.length || activeFutures.isNotEmpty) {
        if (_cancelDownload) break;

        // キューから取り出して並列実行数までタスクを追加
        while (activeFutures.length < maxConcurrentDownloads && next < queue.length) {
          final (provider, tile) = queue[next++];
          late final Future<void> future;
          future = _downloadTile(provider, tile.z, tile.x, tile.y).then((result) {
            processedTiles++;
            switch (result) {
              case _DownloadResult.downloaded:
                downloadedTiles++;
              case _DownloadResult.skipped:
                skippedTiles++;
              case _DownloadResult.error:
                errorTiles++;
            }
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

  /// 一括ダウンロードの 1 枚（並列実行用）
  Future<_DownloadResult> _downloadTile(BaseMapProvider provider, int z, int x, int y) async {
    try {
      // その段を持たないプロバイダは飛ばす（等高線は z9〜、地理院は z18 まで）
      if (z < provider.minZoom || z > provider.maxZoom) return _DownloadResult.skipped;
      // キャッシュ確認
      if (await _getCachedTile(provider.cacheId, z, x, y) != null) return _DownloadResult.skipped;
      // 生成プロバイダ（等高線）は作ってキャッシュに入れる（DEM は取りに行く）
      if (provider.type == BaseMapType.generated) {
        return await getTile(provider, z, x, y) != null ? _DownloadResult.downloaded : _DownloadResult.error;
      }
      // ダウンロード実行（キャッシュは今見たので見ない。取り直しもしない）
      final data = await _fetchTile(provider, z, x, y, attempt: 2, checkCache: false);
      if (data == null) return _DownloadResult.error;
      // BAN対策: 短い待機時間を入れる
      // 4並列 × 50ms待機 = 理論最大80req/sec (通信時間除く)
      // 実際は通信時間があるため、サーバー負荷はそこまで高くならないはず
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return _DownloadResult.downloaded;
    } catch (e) {
      AppLogger.debug('[Downloader] ❌ Download failed (Offline/Network Error)');
      return _DownloadResult.error;
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
