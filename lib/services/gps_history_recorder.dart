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
/// GPS軌跡の常時記録サービス（ハイブリッド方式）
///
/// InternalGpsLocationStore.positionStream を購読し:
/// - Raw Buffer: AppSupport内のGeoPackageにPoint逐次追加（高速・安全）
/// - Consolidated: Global内のgps_history.gpkgにLine+正規化テーブルで定期反映
///
/// Consolidation済みデータはGPKGレイヤツリー経由で地図上に表示。
/// 未Consolidation分（max ~20秒）のみメモリ保持し、kGpsTrackソースで表示。
/// Raw Bufferの反映済みポイントはConsolidation後に即時削除。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../models/geometry_type.dart';
import '../models/geopackage/geopackage_file.dart';
import '../models/gps_position_record.dart';
import '../models/gps_track.dart';
import '../utils/app_logger.dart';

/// GPS履歴レコーダー（シングルトン、ChangeNotifier）
///
/// ハイブリッド方式:
/// - Raw記録: GPS受信ごとにPointをバッファGeoPackageにINSERT（O(1)）
/// - 未Consolidation分: _pendingDetailsに保持（表示+書き込み兼用）
/// - Consolidation: 定期的にLineジオメトリ+詳細テーブルを更新+Raw Buffer削除
class GpsHistoryRecorder extends ChangeNotifier {
  static final GpsHistoryRecorder _instance = GpsHistoryRecorder._internal();
  factory GpsHistoryRecorder() => _instance;
  GpsHistoryRecorder._internal();

  static const String _logTag = 'GpsHistoryRecorder';

  // ファイル名
  static const String _historyGpkgFileName = 'gps_history.gpkg';
  static const String _rawBufferDirName = 'gps_buffer';
  static const String _rawBufferGpkgFileName = 'gps_raw_buffer.gpkg';

  // テーブル・レイヤ名
  static const String _tracksLayerName = 'gps_tracks';
  static const String _detailsTableName = 'gps_track_details';
  static const String _rawLayerPrefix = 'gps_raw_';

  // Consolidation間隔（秒）
  static const int _consolidationIntervalSeconds = 20;

  /// これ以上記録が空いたら新しい区間（フィーチャ）にする。
  /// 暦日だけで区切ると、アプリを閉じて別の場所で開いたときに前の末尾から直線で繋がる
  static const Duration segmentGap = Duration(minutes: 10);

  // GeoPackageファイル
  GeoPackageFile? _historyFile;
  GeoPackageFile? _rawBufferFile;

  // 日付・状態管理
  String? _currentDateKey;
  int? _todayTrackFeatureId;

  /// 今日の何本目の区間か（1 本目の名前は日付だけ、2 本目からは `2026_09_12 #2`）
  int _segmentIndex = 1;

  String get _segmentName =>
      _segmentIndex <= 1 ? _currentDateKey! : '$_currentDateKey #$_segmentIndex';

  /// フィーチャ名から区間番号を取り出す（`2026_09_12` → 1、`2026_09_12 #3` → 3、別の日は null）
  static int? segmentIndexOf(String? name, String dateKey) {
    if (name == null) return null;
    if (name == dateKey) return 1;
    if (!name.startsWith('$dateKey #')) return null;
    return int.tryParse(name.substring(dateKey.length + 2));
  }
  int _lastConsolidatedIndex = 0;

  // ストリーム・タイマー
  StreamSubscription<GpsPositionRecord>? _subscription;
  Timer? _consolidationTimer;

  // メモリキャッシュ（未Consolidation分のみ）
  final List<GpsTrackPoint> _pendingDetails = [];
  final List<int> _pendingRawIds = [];
  DateTime? _lastRecordedTime;
  LatLng? _lastRecordedPosition;
  LatLng? _lastConsolidatedPosition;

  /// Consolidation完了コールバック（レイヤリフレッシュ用）
  VoidCallback? onConsolidated;

  // フラグ
  bool _isInitialized = false;
  Completer<void>? _initCompleter;
  bool _isConsolidating = false;

  // ==============================
  // Getters
  // ==============================

  bool get isInitialized => _isInitialized;

  /// 未Consolidation分のポイント座標リスト（kGpsTrackソース表示用）
  /// Consolidation済み分はGPKGレイヤツリー経由で表示される
  /// Consolidated末尾を先頭に1点含めて表示ギャップを防止
  List<LatLng> get todayPoints => List.unmodifiable([
    ?_lastConsolidatedPosition,
    ..._pendingDetails.map((p) => LatLng(p.latitude, p.longitude)),
  ]);

  /// 本日の日付キー
  String get todayDateKey => _buildDateKey(DateTime.now());

  // ==============================
  // 初期化
  // ==============================

  /// 初期化
  ///
  /// [globalFolderPath] gps_history.gpkg の配置先（グローバルフォルダ）
  /// [supportDirPath] gps_raw_buffer.gpkg の配置先（AppSupport、UI非表示）
  Future<void> initialize(
    String globalFolderPath,
    String supportDirPath,
  ) async {
    if (_isInitialized) return;

    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    try {
      AppLogger.debug('$_logTag: 初期化開始');

      // ディレクトリ確保
      await _ensureDirectory(globalFolderPath);
      final rawBufferDir = p.join(supportDirPath, _rawBufferDirName);
      await _ensureDirectory(rawBufferDir);

      // History GeoPackage（Line + details）
      final historyPath = p.join(globalFolderPath, _historyGpkgFileName);
      _historyFile = GeoPackageFile(
        [_historyGpkgFileName],
        absolutePath: historyPath,
      );
      if (!await File(historyPath).exists()) {
        await _historyFile!.createEmptyDatabase();
      }

      // Raw Buffer GeoPackage（Point逐次記録）
      final rawPath = p.join(rawBufferDir, _rawBufferGpkgFileName);
      _rawBufferFile = GeoPackageFile(
        [_rawBufferGpkgFileName],
        absolutePath: rawPath,
      );
      if (!await File(rawPath).exists()) {
        await _rawBufferFile!.createEmptyDatabase();
      }

      // テーブル・レイヤ確保
      await _ensureTracksLayer();
      await _ensureDetailsTable();

      _currentDateKey = _buildDateKey(DateTime.now());
      await _ensureRawLayer(_currentDateKey!);

      // 本日の既存Line → キャッシュ復元
      await _loadTodayFromHistory();

      // Raw未反映分 → 即座にconsolidate
      await _recoverUnconsolidated();

      // 古いrawデータを削除
      await _cleanupOldRawData();

      _isInitialized = true;
      AppLogger.debug(
        '$_logTag: 初期化完了 (日付: $_currentDateKey, '
        'featureId: $_todayTrackFeatureId, '
        'consolidated: $_lastConsolidatedIndex点)',
      );
      _initCompleter!.complete();
    } catch (e) {
      AppLogger.debug('$_logTag: 初期化エラー: $e');
      _initCompleter!.completeError(e);
    } finally {
      _initCompleter = null;
    }
  }

  Future<void> _ensureDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  // ==============================
  // 記録の開始/停止
  // ==============================

  /// positionStream の購読開始 + consolidationタイマー起動
  void startRecording(Stream<GpsPositionRecord> positionStream) {
    _subscription?.cancel();
    _subscription = positionStream.listen(
      _onPositionReceived,
      onError: (error) {
        AppLogger.debug('$_logTag: ストリームエラー: $error');
      },
    );

    _consolidationTimer?.cancel();
    _consolidationTimer = Timer.periodic(
      const Duration(seconds: _consolidationIntervalSeconds),
      (_) => _consolidate(),
    );

    AppLogger.debug('$_logTag: 記録開始 (consolidation: $_consolidationIntervalSeconds秒間隔)');
  }

  /// 停止（最終consolidation実行）
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;

    _consolidationTimer?.cancel();
    _consolidationTimer = null;

    // 残りを確実に反映
    await _consolidate();

    AppLogger.debug('$_logTag: 記録停止');
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _consolidationTimer?.cancel();
    _consolidationTimer = null;
    _historyFile?.dispose();
    _historyFile = null;
    _rawBufferFile?.dispose();
    _rawBufferFile = null;
    _isInitialized = false;
    super.dispose();
  }

  // ==============================
  // 位置記録（Raw Buffer）
  // ==============================

  Future<void> _onPositionReceived(GpsPositionRecord record) async {
    if (!_isInitialized || _rawBufferFile == null) return;

    // 最低1秒間隔フィルタ
    if (_lastRecordedTime != null &&
        record.timestamp.difference(_lastRecordedTime!).inMilliseconds <
            1000) {
      return;
    }

    // 空間的重複フィルタ（直前と完全一致なら記録しない）
    if (_lastRecordedPosition != null) {
      if (_lastRecordedPosition!.latitude == record.latitude &&
          _lastRecordedPosition!.longitude == record.longitude) {
        return;
      }
    }

    try {
      await _checkAndRotateDay();
      if (_currentDateKey == null) return;

      // 前の記録から空きすぎていたら新しい区間へ（閉じていた間は繋がない）
      if (_lastRecordedTime != null) {
        final gap = record.timestamp.difference(_lastRecordedTime!);
        if (gap >= segmentGap) await _startNewSegment(gap);
      }

      final rawLayerName = _buildRawLayerName(_currentDateKey!);

      // Raw BufferにPoint INSERT（O(1)、高速）
      final rawId = await _rawBufferFile!.addPointWithAttributes(
        rawLayerName,
        LatLng(record.latitude, record.longitude),
        {
          'timestamp': record.timestamp.toIso8601String(),
          'altitude': record.altitude,
          'accuracy': record.accuracy,
          'speed': record.speed,
          'bearing': record.bearing,
          'source_type': 'GPS',
        },
      );

      _lastRecordedTime = record.timestamp;
      _lastRecordedPosition = LatLng(record.latitude, record.longitude);

      // Raw Buffer rowId を追跡（Consolidation後の削除用）
      if (rawId != null) _pendingRawIds.add(rawId);

      // 未Consolidation分として保持（表示+書き込み兼用）
      _pendingDetails.add(GpsTrackPoint(
        latitude: record.latitude,
        longitude: record.longitude,
        altitude: record.altitude,
        accuracy: record.accuracy,
        speed: record.speed,
        bearing: record.bearing,
        timestamp: record.timestamp,
        sourceType: 'GPS',
      ));

      // UI更新通知（頻度を抑える）
      if (_pendingDetails.length <= 5 || _pendingDetails.length % 10 == 0) {
        notifyListeners();
      }
    } catch (e) {
      AppLogger.debug('$_logTag: 記録エラー: $e');
    }
  }

  // ==============================
  // 日付管理
  // ==============================

  String _buildDateKey(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '${y}_${m}_$d';
  }

  String _buildRawLayerName(String dateKey) => '$_rawLayerPrefix$dateKey';

  Future<void> _ensureRawLayer(String dateKey) async {
    if (_rawBufferFile == null) return;

    final layerName = _buildRawLayerName(dateKey);
    final existingLayers = await _rawBufferFile!.getLayerNames();
    if (existingLayers.contains(layerName)) return;

    AppLogger.debug('$_logTag: Rawレイヤ作成: $layerName');
    await _rawBufferFile!.addLayer(layerName, GeometryType.point);
    await _rawBufferFile!.addAttributeColumns(layerName, {
      'timestamp': 'TEXT',
      'altitude': 'REAL',
      'accuracy': 'REAL',
      'speed': 'REAL',
      'bearing': 'REAL',
      'source_type': 'TEXT',
    });
  }

  Future<void> _ensureTracksLayer() async {
    if (_historyFile == null) return;

    final existingLayers = await _historyFile!.getLayerNames();
    if (!existingLayers.contains(_tracksLayerName)) {
      AppLogger.debug('$_logTag: gps_tracks LineLayer 作成');
      await _historyFile!.addLayer(_tracksLayerName, GeometryType.linestring);
    }

    // addLine/updateLine が name, description カラムを必要とするため確保
    final columns = await _historyFile!.getTableColumns(_tracksLayerName);
    final needed = {'name': 'TEXT', 'description': 'TEXT'};
    for (final entry in needed.entries) {
      if (!columns.contains(entry.key)) {
        await _historyFile!.addAttributeColumn(
          _tracksLayerName,
          entry.key,
          entry.value,
        );
      }
    }
  }

  Future<void> _ensureDetailsTable() async {
    if (_historyFile == null) return;

    try {
      final db = await _historyFile!.getDatabase();
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [_detailsTableName],
      );
      if (tables.isNotEmpty) return;

      AppLogger.debug('$_logTag: gps_track_details テーブル作成');
      await db.execute('''
        CREATE TABLE $_detailsTableName (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          track_date TEXT NOT NULL,
          point_index INTEGER NOT NULL,
          timestamp TEXT NOT NULL,
          latitude REAL NOT NULL,
          longitude REAL NOT NULL,
          altitude REAL,
          accuracy REAL,
          speed REAL,
          bearing REAL,
          source_type TEXT DEFAULT 'GPS'
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_track_details_date '
        'ON $_detailsTableName(track_date)',
      );
      await db.execute(
        'CREATE INDEX idx_track_details_date_idx '
        'ON $_detailsTableName(track_date, point_index)',
      );
    } catch (e) {
      AppLogger.debug('$_logTag: detailsテーブル作成エラー: $e');
    }
  }

  /// 区間を切る: 溜まっている分を今の区間に反映してから、次の点は新しいフィーチャに
  Future<void> _startNewSegment(Duration gap) async {
    await _consolidate();
    _segmentIndex++;
    _todayTrackFeatureId = null;
    _lastConsolidatedPosition = null; // 表示側でも前の区間と繋がないように
    AppLogger.debug('$_logTag: ${gap.inMinutes} 分空いたので新しい区間 #$_segmentIndex');
    notifyListeners();
  }

  Future<void> _checkAndRotateDay() async {
    final newDateKey = _buildDateKey(DateTime.now());
    if (newDateKey == _currentDateKey) return;

    AppLogger.debug('$_logTag: 日付変更検出: $_currentDateKey → $newDateKey');

    // 残りを確実に反映してから切り替え
    await _consolidate();

    _currentDateKey = newDateKey;
    _todayTrackFeatureId = null;
    _segmentIndex = 1;
    _lastRecordedTime = null;
    _lastConsolidatedIndex = 0;
    _pendingDetails.clear();
    _pendingRawIds.clear();
    _lastRecordedPosition = null;
    _lastConsolidatedPosition = null;

    await _ensureRawLayer(newDateKey);

    notifyListeners();
  }

  // ==============================
  // Consolidation（定期反映）
  // ==============================

  Future<void> _consolidate() async {
    if (_isConsolidating ||
        _historyFile == null ||
        _pendingDetails.isEmpty ||
        _currentDateKey == null) {
      return;
    }

    _isConsolidating = true;
    try {
      final detailsToWrite = List<GpsTrackPoint>.from(_pendingDetails);
      final rawIdsToDelete = List<int>.from(_pendingRawIds);
      _pendingDetails.clear();
      _pendingRawIds.clear();

      // GPKGから現在のLine座標を読み出し + 新ポイント追加（read-modify-write）
      final currentLine = await _readCurrentLine();
      final newCoords = detailsToWrite
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();
      currentLine.addAll(newCoords);

      // Line ジオメトリ更新
      if (currentLine.length >= 2) {
        if (_todayTrackFeatureId == null) {
          // 新規作成
          _todayTrackFeatureId = await _historyFile!.addLine(
            _tracksLayerName,
            currentLine,
            name: _segmentName,
          );
          AppLogger.debug(
            '$_logTag: gps_tracks フィーチャ作成 (id=$_todayTrackFeatureId)',
          );
        } else {
          // 既存更新（外部削除されたフィーチャの場合はフォールバック）
          try {
            await _historyFile!.updateLine(
              _tracksLayerName,
              _todayTrackFeatureId!,
              currentLine,
              name: _segmentName,
            );
          } catch (e) {
            AppLogger.debug(
              '$_logTag: updateLine失敗 (id=$_todayTrackFeatureId), '
              '新規作成にフォールバック: $e',
            );
            _todayTrackFeatureId = await _historyFile!.addLine(
              _tracksLayerName,
              currentLine,
              name: _segmentName,
            );
            AppLogger.debug(
              '$_logTag: gps_tracks フィーチャ再作成 '
              '(id=$_todayTrackFeatureId)',
            );
          }
        }
      }

      // Details テーブルにバッチINSERT
      final db = await _historyFile!.getDatabase();
      await db.transaction((txn) async {
        for (final pt in detailsToWrite) {
          await txn.insert(_detailsTableName, {
            'track_date': _currentDateKey,
            'point_index': _lastConsolidatedIndex,
            'timestamp': pt.timestamp.toIso8601String(),
            'latitude': pt.latitude,
            'longitude': pt.longitude,
            'altitude': pt.altitude,
            'accuracy': pt.accuracy,
            'speed': pt.speed,
            'bearing': pt.bearing,
            'source_type': pt.sourceType,
          });
          _lastConsolidatedIndex++;
        }
      });

      // Raw Buffer クリーンアップ（Consolidation済みポイントを削除）
      if (rawIdsToDelete.isNotEmpty && _rawBufferFile != null) {
        try {
          final rawDb = await _rawBufferFile!.getDatabase();
          final rawLayerName = _buildRawLayerName(_currentDateKey!);
          final placeholders =
              List.filled(rawIdsToDelete.length, '?').join(',');
          await rawDb.rawDelete(
            'DELETE FROM "$rawLayerName" WHERE rowid IN ($placeholders)',
            rawIdsToDelete,
          );
          AppLogger.debug(
            '$_logTag: Raw Buffer ${rawIdsToDelete.length}件削除',
          );
        } catch (e) {
          AppLogger.debug('$_logTag: Raw Buffer削除エラー: $e');
        }
      }

      // Consolidated末尾座標を記録（pending表示との接続点）
      if (currentLine.isNotEmpty) {
        _lastConsolidatedPosition = currentLine.last;
      }

      AppLogger.debug(
        '$_logTag: Consolidation完了 (${detailsToWrite.length}点反映, '
        '合計: $_lastConsolidatedIndex点)',
      );

      // レイヤリフレッシュ通知
      onConsolidated?.call();
    } catch (e) {
      AppLogger.debug('$_logTag: Consolidationエラー: $e');
    } finally {
      _isConsolidating = false;
    }
  }

  /// gps_tracks から当日のLineジオメトリ座標を読み出す
  /// フィーチャが外部削除されていた場合は _todayTrackFeatureId をリセット
  Future<List<LatLng>> _readCurrentLine() async {
    if (_historyFile == null || _todayTrackFeatureId == null) return [];

    try {
      final detail = await _historyFile!.getFeature(
        _tracksLayerName,
        _todayTrackFeatureId!,
      );
      if (detail == null || detail['geometry'] == null) {
        // フィーチャが削除されている → addLine パスに切り替え
        AppLogger.debug(
          '$_logTag: フィーチャ未発見 (id=$_todayTrackFeatureId), リセット',
        );
        _todayTrackFeatureId = null;
        return [];
      }

      final geom = detail['geometry'];
      final result = <LatLng>[];
      if (geom is List<LatLng>) {
        result.addAll(geom);
      } else if (geom is List) {
        for (final item in geom) {
          if (item is LatLng) {
            result.add(item);
          } else if (item is List<LatLng>) {
            // MultiLineString: List<List<LatLng>> → フラット化
            result.addAll(item);
          } else if (item is List) {
            // ネストされたListの場合も再帰的にLatLngを拾う
            for (final pt in item) {
              if (pt is LatLng) result.add(pt);
            }
          }
        }
      }
      return result;
    } catch (e) {
      AppLogger.debug('$_logTag: Line読み出しエラー: $e');
      _todayTrackFeatureId = null;
      return [];
    }
  }

  // ==============================
  // 起動時復元
  // ==============================

  /// gps_tracks から当日のフィーチャIDと反映済みインデックスを復元
  /// （座標キャッシュは不要 — GPKGレイヤツリーが表示を担当）
  Future<void> _loadTodayFromHistory() async {
    if (_historyFile == null || _currentDateKey == null) return;

    try {
      final existingLayers = await _historyFile!.getLayerNames();
      if (!existingLayers.contains(_tracksLayerName)) return;

      // 当日のフィーチャのうち一番新しい区間を拾う（`日付` `日付 #2` …）
      final features = await _historyFile!.getFeatures(_tracksLayerName);
      int? latestId;
      var latestIndex = 0;
      for (final feature in features) {
        final index = segmentIndexOf(feature['name']?.toString(), _currentDateKey!);
        if (index == null || index <= latestIndex) continue;
        final id = feature['id'];
        if (id == null) continue;
        latestIndex = index;
        latestId = id is int ? id : int.tryParse(id.toString()) ?? 0;
      }
      if (latestId != null) {
        final featureId = latestId;
        _todayTrackFeatureId = featureId;
        _segmentIndex = latestIndex;

        // 空間フィルタ用に末尾座標を復元
        final detail = await _historyFile!.getFeature(
          _tracksLayerName,
          featureId,
        );
        if (detail != null && detail['geometry'] != null) {
          final geom = detail['geometry'];
          if (geom is List<LatLng> && geom.isNotEmpty) {
            _lastRecordedPosition = geom.last;
          } else if (geom is List && geom.isNotEmpty) {
            // MultiLineString: List<List<LatLng>> → 最後のラインの末尾
            final lastItem = geom.last;
            if (lastItem is LatLng) {
              _lastRecordedPosition = lastItem;
            } else if (lastItem is List<LatLng> && lastItem.isNotEmpty) {
              _lastRecordedPosition = lastItem.last;
            } else if (lastItem is List && lastItem.isNotEmpty && lastItem.last is LatLng) {
              _lastRecordedPosition = lastItem.last as LatLng;
            }
          }
        }
      }

      // details テーブルから反映済みインデックスと最後の記録時刻を算出
      final db = await _historyFile!.getDatabase();
      final countResult = await db.rawQuery(
        'SELECT COUNT(*) as cnt, MAX(timestamp) as last_ts FROM $_detailsTableName WHERE track_date = ?',
        [_currentDateKey],
      );
      _lastConsolidatedIndex =
          (countResult.first['cnt'] as int?) ?? 0;
      final lastTs = countResult.first['last_ts']?.toString();
      if (lastTs != null) _lastRecordedTime = DateTime.tryParse(lastTs);

      AppLogger.debug(
        '$_logTag: History復元完了 '
        '(featureId=$_todayTrackFeatureId, '
        'consolidated=$_lastConsolidatedIndex)',
      );
    } catch (e) {
      AppLogger.debug('$_logTag: History復元エラー: $e');
    }
  }

  /// Raw Buffer に残っている未反映ポイントを復元してconsolidate
  Future<void> _recoverUnconsolidated() async {
    if (_rawBufferFile == null || _currentDateKey == null) return;

    try {
      final rawLayerName = _buildRawLayerName(_currentDateKey!);
      final existingLayers = await _rawBufferFile!.getLayerNames();
      if (!existingLayers.contains(rawLayerName)) return;

      final rawFeatures = await _rawBufferFile!.getFeatures(rawLayerName);
      final rawCount = rawFeatures.length;

      // Raw Buffer のポイント数がConsolidation済み件数以下なら復元不要
      if (rawCount <= _lastConsolidatedIndex) return;

      AppLogger.debug(
        '$_logTag: 未反映ポイント検出 '
        '(raw=$rawCount, consolidated=$_lastConsolidatedIndex, '
        'diff=${rawCount - _lastConsolidatedIndex})',
      );

      // 未反映分だけ復元
      int recovered = 0;
      for (int i = _lastConsolidatedIndex; i < rawFeatures.length; i++) {
        final feature = rawFeatures[i];
        final id = feature['id'];
        if (id == null) continue;

        final featureId =
            id is int ? id : int.tryParse(id.toString()) ?? 0;
        final detail = await _rawBufferFile!.getFeature(
          rawLayerName,
          featureId,
        );
        if (detail == null || detail['geometry'] == null) continue;

        final geom = detail['geometry'];
        LatLng? latLng;
        if (geom is List && geom.isNotEmpty && geom.first is LatLng) {
          latLng = geom.first as LatLng;
        }
        if (latLng == null) continue;

        _pendingDetails.add(GpsTrackPoint(
          latitude: latLng.latitude,
          longitude: latLng.longitude,
          altitude: (detail['altitude'] as num?)?.toDouble(),
          accuracy: (detail['accuracy'] as num?)?.toDouble(),
          speed: (detail['speed'] as num?)?.toDouble(),
          bearing: (detail['bearing'] as num?)?.toDouble(),
          timestamp: detail['timestamp'] != null
              ? DateTime.tryParse(detail['timestamp'].toString()) ??
                  DateTime.now()
              : DateTime.now(),
          sourceType: detail['source_type']?.toString() ?? 'GPS',
        ));
        // Raw Buffer rowId も追跡
        _pendingRawIds.add(featureId);
        recovered++;
      }

      if (recovered > 0) {
        // 復元した点は閉じる前の記録なので今の区間に繋ぐ。次の生の点との空きはここからの差で判定する
        final lastTs = _pendingDetails.last.timestamp;
        if (_lastRecordedTime == null || lastTs.isAfter(_lastRecordedTime!)) {
          _lastRecordedTime = lastTs;
        }
        AppLogger.debug('$_logTag: $recovered 点を復元、consolidation実行');
        await _consolidate();
      }
    } catch (e) {
      AppLogger.debug('$_logTag: 未反映復元エラー: $e');
    }
  }

  // ==============================
  // 日次クリーンアップ
  // ==============================

  /// 2日前以前のrawレイヤを削除
  Future<void> _cleanupOldRawData() async {
    if (_rawBufferFile == null) return;

    try {
      final now = DateTime.now();
      final threshold = now.subtract(const Duration(days: 2));
      final thresholdKey = _buildDateKey(threshold);

      final layers = await _rawBufferFile!.getLayerNames();
      for (final layer in layers) {
        if (!layer.startsWith(_rawLayerPrefix)) continue;
        final dateKey = layer.replaceFirst(_rawLayerPrefix, '');
        if (dateKey.compareTo(thresholdKey) < 0) {
          AppLogger.debug('$_logTag: 古いrawレイヤ削除: $layer');
          await _rawBufferFile!.removeLayer(layer);
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: rawクリーンアップエラー: $e');
    }
  }

  // ==============================
  // クエリ（ダイアログ用）
  // ==============================

  /// 利用可能な日付キーのリストを取得（新しい順）
  Future<List<String>> getAvailableDates() async {
    if (_historyFile == null) return [];

    try {
      final dateKeys = <String>{};

      final layers = await _historyFile!.getLayerNames();
      if (layers.contains(_tracksLayerName)) {
        final features =
            await _historyFile!.getFeatures(_tracksLayerName);
        for (final f in features) {
          final name = f['name']?.toString();
          if (name != null && name.isNotEmpty) {
            dateKeys.add(name);
          }
        }
      }

      final sorted = dateKeys.toList()
        ..sort((a, b) => b.compareTo(a));
      return sorted;
    } catch (e) {
      AppLogger.debug('$_logTag: 日付リスト取得エラー: $e');
      return [];
    }
  }

  /// 日付キーを表示用にフォーマット
  /// 例: '2026_02_06' → '2026/02/06'
  static String formatDateKeyAsDate(String dateKey) {
    return dateKey.replaceAll('_', '/');
  }

  /// 日付キーを表示用にフォーマット（formatDateKeyAsDateのエイリアス）
  static String formatLayerNameAsDate(String layerName) {
    return layerName.replaceAll('_', '/');
  }

  /// 特定日付の全ポイントを取得
  Future<List<GpsTrackPoint>> getPointsForDate(String dateKey) async {
    if (_historyFile == null) return [];

    try {
      final db = await _historyFile!.getDatabase();
      final rows = await db.query(
        _detailsTableName,
        where: 'track_date = ?',
        whereArgs: [dateKey],
        orderBy: 'point_index ASC',
      );
      return rows.map((row) => GpsTrackPoint(
        latitude: (row['latitude'] as num).toDouble(),
        longitude: (row['longitude'] as num).toDouble(),
        altitude: (row['altitude'] as num?)?.toDouble(),
        accuracy: (row['accuracy'] as num?)?.toDouble(),
        speed: (row['speed'] as num?)?.toDouble(),
        bearing: (row['bearing'] as num?)?.toDouble(),
        timestamp: row['timestamp'] != null
            ? DateTime.tryParse(row['timestamp'].toString()) ??
                DateTime.now()
            : DateTime.now(),
        sourceType: row['source_type']?.toString() ?? 'GPS',
      )).toList();
    } catch (e) {
      AppLogger.debug('$_logTag: detailsテーブルクエリエラー: $e');
      return [];
    }
  }

  /// 特定時間範囲のポイントを取得
  Future<List<GpsTrackPoint>> getPointsInRange(
    String dateKey,
    DateTime start,
    DateTime end,
  ) async {
    final allPoints = await getPointsForDate(dateKey);
    return allPoints
        .where((p) =>
            !p.timestamp.isBefore(start) && !p.timestamp.isAfter(end))
        .toList();
  }
}
