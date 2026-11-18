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
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../models/geometry_type.dart';
import '../models/geopackage/geopackage_file.dart';
import '../models/gps_info.dart';
import '../models/gps_position_record.dart';
import '../models/gps_track.dart';
import '../models/track_recording_settings.dart';
import '../utils/app_logger.dart';
import 'device_connection_log_service.dart';

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

  /// シングルトンでない新しいもの（テストで「落ちて起動し直した」を作る）
  @visibleForTesting
  GpsHistoryRecorder.forTesting();

  static const String _logTag = 'GpsHistoryRecorder';

  // ファイル名
  static const String _historyGpkgFileName = 'gps_history.gpkg';
  static const String _rawBufferDirName = 'gps_buffer';
  static const String _rawBufferGpkgFileName = 'gps_raw_buffer.gpkg';
  static const String _deviceIdFileName = 'device_id.txt';

  // テーブル・レイヤ名
  static const String _tracksLayerName = 'gps_tracks';
  static const String _detailsTableName = 'gps_track_details';
  static const String _rawLayerPrefix = 'gps_raw_';

  // 外部GNSS常時記録用のテーブル・レイヤ名（同じ gps_history.gpkg 内に同居）
  static const String gnssTracksLayerName = 'gnss_tracks';
  static const String gnssDetailsTableName = 'gnss_track_details';
  static const String connectionEventsTableName = 'device_connection_events';
  static const String _gnssRawLayerPrefix = 'gnss_raw_';
  static const String gnssTag = 'GNSS';

  // Consolidation間隔（秒）
  static const int _consolidationIntervalSeconds = 20;

  /// これ以上記録が空いたら新しい区間（フィーチャ）にする。
  /// 暦日だけで区切ると、アプリを閉じて別の場所で開いたときに前の末尾から直線で繋がる
  static const Duration segmentGap = Duration(minutes: 10);

  /// 届いた測位を軌跡に入れるかの判定（設定は地図ページが [TrackRecordingSettings] を流し込む）
  final TrackPointFilter filter = TrackPointFilter();

  /// 外部GNSS測位の軌跡フィルタ（既定 1秒間隔で高密度に保管）
  final TrackPointFilter gnssFilter = TrackPointFilter();

  /// 外部GNSS記録時に現在配信中の NTRIP マウントポイント名を付与するプロバイダ（任意）
  String? Function()? ntripMountpointProvider;

  // GeoPackageファイル
  GeoPackageFile? _historyFile;
  GeoPackageFile? _rawBufferFile;

  // 端末識別子（Auto Backup 対象外の supportDir に保持）
  String _deviceId = '';
  String get deviceId => _deviceId;

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
  StreamSubscription<GpsInfo>? _gnssSubscription;
  Timer? _consolidationTimer;

  // メモリキャッシュ（未Consolidation分のみ）
  final List<GpsTrackPoint> _pendingDetails = [];
  final List<int> _pendingRawIds = [];
  DateTime? _lastRecordedTime;
  LatLng? _lastRecordedPosition;
  LatLng? _lastConsolidatedPosition;

  // 外部GNSS用の状態・メモリキャッシュ
  int? _todayGnssTrackFeatureId;
  int _gnssSegmentIndex = 1;
  int _lastGnssConsolidatedIndex = 0;
  final List<GpsTrackPoint> _pendingGnssDetails = [];
  final List<int> _pendingGnssRawIds = [];
  DateTime? _lastGnssRecordedTime;
  LatLng? _lastGnssRecordedPosition;
  LatLng? _lastGnssConsolidatedPosition;

  String get _gnssSegmentName =>
      _gnssSegmentIndex <= 1 ? _currentDateKey! : '$_currentDateKey #$_gnssSegmentIndex';

  /// 直近の反映で書いた今日の区間（フィーチャ ID と座標）。地図側はレイヤを読み直さず、この 1 本だけ差し替える
  int? get todayTrackFeatureId => _todayTrackFeatureId;
  List<LatLng>? lastConsolidatedLine;

  int? get todayGnssTrackFeatureId => _todayGnssTrackFeatureId;
  List<LatLng>? lastConsolidatedGnssLine;

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
    ..._pendingDetails.map((p) => p.toLatLng()),
  ]);

  /// 外部GNSSの未Consolidation分のポイント座標リスト（地図常時描画用）
  List<LatLng> get todayGnssPoints => List.unmodifiable([
    ?_lastGnssConsolidatedPosition,
    ..._pendingGnssDetails.map((p) => p.toLatLng()),
  ]);

  // ==============================
  // 初期化
  // ==============================

  /// 初期化
  ///
  /// [globalFolderPath] gps_history.gpkg の配置先（グローバルフォルダ）
  /// [supportDirPath] gps_raw_buffer.gpkg の配置先（AppSupport、UI非表示）
  /// [deviceIdOverride] テスト等で端末IDを明示指定する場合に使用
  Future<void> initialize(
    String globalFolderPath,
    String supportDirPath, {
    String? deviceIdOverride,
  }) async {
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

      // 端末IDの読み込みまたは生成（supportDir配下に保存しAuto Backupによる複製を防止）
      _deviceId = deviceIdOverride ?? await _loadOrCreateDeviceId(supportDirPath);

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

      // テーブル・レイヤ確保（内蔵GPS + 外部GNSS + 機器接続イベント）
      await _ensureTracksLayer();
      await _ensureDetailsTable();
      await _ensureGnssTracksLayer();
      await _ensureGnssDetailsTable();
      await _ensureConnectionEventsTable();

      _currentDateKey = dateKey(DateTime.now());
      await _ensureRawLayer(_currentDateKey!);
      await _ensureGnssRawLayer(_currentDateKey!);

      // 本日の既存Line → キャッシュ復元
      await _loadTodayFromHistory();
      await _loadTodayGnssFromHistory();

      // Raw未反映分 → 即座にconsolidate
      await _recoverUnconsolidated();
      await _recoverUnconsolidatedGnss();

      // 古いrawデータを削除
      await _cleanupOldRawData();

      DeviceConnectionLogService.instance.addEventSink(_onDeviceConnectionEvent);
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

  static Future<String> _loadOrCreateDeviceId(String supportDirPath) async {
    try {
      final file = File(p.join(supportDirPath, _deviceIdFileName));
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (existing.isNotEmpty) return existing;
      }
      final rng = math.Random.secure();
      final id = List.generate(12, (_) => rng.nextInt(16).toRadixString(16)).join();
      await file.writeAsString(id, flush: true);
      return id;
    } catch (_) {
      return 'local';
    }
  }

  bool _isOwnDevice(Object? rowDeviceId) {
    final s = rowDeviceId?.toString();
    return s == null || s.isEmpty || s == _deviceId;
  }

  // ==============================
  // 記録の開始/停止
  // ==============================

  /// 書きかけの raw バッファへの書き込み
  final Set<Future<void>> _writing = {};

  /// 届いた位置の書き込みが終わるまで待つ（テスト用。落ちる直前の状態を作る）
  @visibleForTesting
  Future<void> flushPendingWrites() => Future.wait(_writing.toList());

  /// positionStream の購読開始 + consolidationタイマー起動
  void startRecording(Stream<GpsPositionRecord> positionStream) {
    _subscription?.cancel();
    _subscription = positionStream.listen(
      (record) {
        final write = _onPositionReceived(record);
        _writing.add(write);
        write.whenComplete(() => _writing.remove(write));
      },
      onError: (error) {
        AppLogger.debug('$_logTag: ストリームエラー: $error');
      },
    );

    _consolidationTimer?.cancel();
    _consolidationTimer = Timer.periodic(
      const Duration(seconds: _consolidationIntervalSeconds),
      (_) => _consolidateAll(),
    );

    AppLogger.debug('$_logTag: 記録開始 (consolidation: $_consolidationIntervalSeconds秒間隔)');
  }

  /// 外部GNSS測位ストリームの常時記録を開始（`gnss_tracks` / `gnss_track_details` に詳細保管）
  void startExternalGnssRecording(Stream<GpsInfo> gnssStream) {
    _gnssSubscription?.cancel();
    _gnssSubscription = gnssStream.listen(
      (info) {
        final write = _onGnssInfoReceived(info);
        _writing.add(write);
        write.whenComplete(() => _writing.remove(write));
      },
      onError: (error) {
        AppLogger.debug('$_logTag: 外部GNSSストリームエラー: $error');
      },
    );

    _consolidationTimer ??= Timer.periodic(
      const Duration(seconds: _consolidationIntervalSeconds),
      (_) => _consolidateAll(),
    );
  }

  /// 停止（最終consolidation実行）
  Future<void> stop() async {
    DeviceConnectionLogService.instance.removeEventSink(_onDeviceConnectionEvent);
    await _subscription?.cancel();
    _subscription = null;
    await _gnssSubscription?.cancel();
    _gnssSubscription = null;

    _consolidationTimer?.cancel();
    _consolidationTimer = null;

    // 進行中の raw 書き込みを待ってから残りを確実に反映
    await Future.wait(_writing.toList());
    await _consolidateAll();

    AppLogger.debug('$_logTag: 記録停止');
  }

  @override
  void dispose() {
    DeviceConnectionLogService.instance.removeEventSink(_onDeviceConnectionEvent);
    _subscription?.cancel();
    _subscription = null;
    _gnssSubscription?.cancel();
    _gnssSubscription = null;
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

    // 間隔・距離・精度・飛びで間引く（設定 → GPS・測位 →「軌跡の記録」）。
    // 区間の切れ目では前の点と比べない（閉じていた間に動いた分を飛びとみなさない）
    final position = LatLng(record.latitude, record.longitude);
    final gap = _lastRecordedTime == null ? null : record.timestamp.difference(_lastRecordedTime!);
    final verdict = filter.judge(
      position: position,
      time: record.timestamp,
      accuracy: record.accuracy,
      lastTime: _lastRecordedTime,
      lastPosition: _lastRecordedPosition,
      newSegment: gap != null && gap >= segmentGap,
    );
    if (verdict != TrackFixVerdict.accept) return;

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
        position,
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
      _lastRecordedPosition = position;

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

  /// 日付キー（`yyyy_MM_dd`）。生の記録・軌跡のレイヤ名に入る（gpkg に残るので書式は変えない）
  static String dateKey(DateTime date) {
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
    await _ensureTracksLayerOn(_historyFile!, backfillDeviceId: _deviceId);
  }

  static Future<void> _ensureTracksLayerOn(
    GeoPackageFile file, {
    String? backfillDeviceId,
  }) async {
    final existingLayers = await file.getLayerNames();
    if (!existingLayers.contains(_tracksLayerName)) {
      AppLogger.debug('$_logTag: gps_tracks LineLayer 作成');
      await file.addLayer(_tracksLayerName, GeometryType.linestring);
    }

    // addLine/updateLine が name, description カラムを必要とするため確保 + 端末識別用の device_id
    final columns = await file.getTableColumns(_tracksLayerName);
    final needed = {'name': 'TEXT', 'description': 'TEXT', 'device_id': 'TEXT'};
    for (final entry in needed.entries) {
      if (!columns.contains(entry.key)) {
        await file.addAttributeColumn(
          _tracksLayerName,
          entry.key,
          entry.value,
        );
      }
    }
    if (backfillDeviceId != null && backfillDeviceId.isNotEmpty) {
      final db = await file.getDatabase();
      await db.rawUpdate(
        'UPDATE $_tracksLayerName SET device_id = ? WHERE device_id IS NULL OR device_id = \'\'',
        [backfillDeviceId],
      );
    }
  }

  Future<void> _ensureDetailsTable() async {
    if (_historyFile == null) return;
    await _ensureDetailsTableOn(_historyFile!, backfillDeviceId: _deviceId);
  }

  static Future<void> _ensureDetailsTableOn(
    GeoPackageFile file, {
    String? backfillDeviceId,
  }) async {
    try {
      final db = await file.getDatabase();
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [_detailsTableName],
      );
      if (tables.isEmpty) {
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
            source_type TEXT DEFAULT 'GPS',
            device_id TEXT
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
      } else {
        final info = await db.rawQuery('PRAGMA table_info($_detailsTableName)');
        final hasDeviceId = info.any((r) => r['name'] == 'device_id');
        if (!hasDeviceId) {
          await db.execute(
            'ALTER TABLE $_detailsTableName ADD COLUMN device_id TEXT',
          );
        }
      }
      if (backfillDeviceId != null && backfillDeviceId.isNotEmpty) {
        await db.rawUpdate(
          'UPDATE $_detailsTableName SET device_id = ? WHERE device_id IS NULL OR device_id = \'\'',
          [backfillDeviceId],
        );
      }
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
    final newDateKey = dateKey(DateTime.now());
    if (newDateKey == _currentDateKey) return;

    AppLogger.debug('$_logTag: 日付変更検出: $_currentDateKey → $newDateKey');

    // 残りを確実に反映してから切り替え
    await _consolidateAll();

    _currentDateKey = newDateKey;
    _todayTrackFeatureId = null;
    _segmentIndex = 1;
    _lastRecordedTime = null;
    _lastConsolidatedIndex = 0;
    _pendingDetails.clear();
    _pendingRawIds.clear();
    _lastRecordedPosition = null;
    _lastConsolidatedPosition = null;

    _todayGnssTrackFeatureId = null;
    _gnssSegmentIndex = 1;
    _lastGnssRecordedTime = null;
    _lastGnssConsolidatedIndex = 0;
    _pendingGnssDetails.clear();
    _pendingGnssRawIds.clear();
    _lastGnssRecordedPosition = null;
    _lastGnssConsolidatedPosition = null;

    await _ensureRawLayer(newDateKey);
    await _ensureGnssRawLayer(newDateKey);

    notifyListeners();
  }

  Future<void> _consolidateAll() async {
    await _consolidate();
    await _consolidateGnss();
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
          .map((p) => p.toLatLng())
          .toList();
      currentLine.addAll(newCoords);

      final db = await _historyFile!.getDatabase();

      // Line ジオメトリ更新
      if (currentLine.length >= 2) {
        if (_todayTrackFeatureId == null) {
          // 新規作成
          _todayTrackFeatureId = await _historyFile!.addLine(
            _tracksLayerName,
            currentLine,
            name: _segmentName,
          );
          if (_todayTrackFeatureId != null && _deviceId.isNotEmpty) {
            await db.update(
              _tracksLayerName,
              {'device_id': _deviceId},
              where: 'fid = ?',
              whereArgs: [_todayTrackFeatureId],
            );
          }
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
            if (_todayTrackFeatureId != null && _deviceId.isNotEmpty) {
              await db.update(
                _tracksLayerName,
                {'device_id': _deviceId},
                where: 'fid = ?',
                whereArgs: [_todayTrackFeatureId],
              );
            }
            AppLogger.debug(
              '$_logTag: gps_tracks フィーチャ再作成 '
              '(id=$_todayTrackFeatureId)',
            );
          }
        }
      }

      // Details テーブルにバッチINSERT
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
            'device_id': _deviceId,
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
      lastConsolidatedLine = currentLine;

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
      if (detail == null || detail[featureGeometryKey] == null) {
        // フィーチャが削除されている → addLine パスに切り替え
        AppLogger.debug(
          '$_logTag: フィーチャ未発見 (id=$_todayTrackFeatureId), リセット',
        );
        _todayTrackFeatureId = null;
        return [];
      }

      return _lineCoords(detail[featureGeometryKey]);
    } catch (e) {
      AppLogger.debug('$_logTag: Line読み出しエラー: $e');
      _todayTrackFeatureId = null;
      return [];
    }
  }

  /// Line（MultiLineString のこともある）のジオメトリを 1 本の座標列に
  static List<LatLng> _lineCoords(Object? geom) => switch (geom) {
    List<LatLng>() => [...geom],
    List() => [
      for (final item in geom)
        if (item is LatLng)
          item
        else if (item is List)
          ...item.whereType<LatLng>(),
    ],
    _ => const [],
  };

  /// raw バッファ・details テーブルの 1 行を点に（時刻が読めなければ今）
  static GpsTrackPoint _trackPointFromRow(Map<String, dynamic> row, LatLng position) => GpsTrackPoint(
    latitude: position.latitude,
    longitude: position.longitude,
    altitude: (row['altitude'] as num?)?.toDouble(),
    accuracy: (row['accuracy'] as num?)?.toDouble(),
    speed: (row['speed'] as num?)?.toDouble(),
    bearing: (row['bearing'] as num?)?.toDouble(),
    timestamp: DateTime.tryParse(row['timestamp']?.toString() ?? '') ?? DateTime.now(),
    sourceType: row['source_type']?.toString() ?? 'GPS',
  );

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

      // 当日の自端末フィーチャのうち一番新しい区間を拾う（`日付` `日付 #2` …）
      final features = await _historyFile!.getFeatures(_tracksLayerName);
      int? latestId;
      var latestIndex = 0;
      for (final feature in features) {
        if (!_isOwnDevice(feature['device_id'])) continue;
        final index = segmentIndexOf(feature['name']?.toString(), _currentDateKey!);
        if (index == null || index <= latestIndex) continue;
        final id = feature[featureIdKey];
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
        if (detail != null) {
          _lastRecordedPosition = _lineCoords(detail[featureGeometryKey]).lastOrNull ?? _lastRecordedPosition;
        }
      }

      // details テーブルから自端末の反映済みインデックスと最後の記録時刻を算出
      final db = await _historyFile!.getDatabase();
      final countResult = await db.rawQuery(
        'SELECT COUNT(*) as cnt, MAX(timestamp) as last_ts FROM $_detailsTableName '
        'WHERE track_date = ? AND (device_id IS NULL OR device_id = \'\' OR device_id = ?)',
        [_currentDateKey, _deviceId],
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

      // 反映した点は反映のたびに raw から消すので、raw に残っているのは反映する前に落ちた分。
      // ⚠ 以前は「raw の件数 > 今日の反映済み件数」のときだけ戻していたため、その日に反映済みの点が
      // raw の残りより多いと（ほぼいつも）戻さず、落ちる直前の最大 20 秒が軌跡から抜けていた。
      // 消し損ねて残った反映済みの点を二重に入れないよう、反映済みの最後の時刻より後の点だけ戻す
      final consolidatedUntil = _lastRecordedTime;
      final rawFeatures = await _rawBufferFile!.getFeatures(rawLayerName);
      if (rawFeatures.isEmpty) return;

      int recovered = 0;
      for (final feature in rawFeatures) {
        final id = feature[featureIdKey];
        if (id == null) continue;

        final featureId =
            id is int ? id : int.tryParse(id.toString()) ?? 0;
        final detail = await _rawBufferFile!.getFeature(
          rawLayerName,
          featureId,
        );
        if (detail == null || detail[featureGeometryKey] == null) continue;

        final geom = detail[featureGeometryKey];
        LatLng? latLng;
        if (geom is List && geom.isNotEmpty && geom.first is LatLng) {
          latLng = geom.first as LatLng;
        }
        if (latLng == null) continue;

        final point = _trackPointFromRow(detail, latLng);
        if (consolidatedUntil != null && !point.timestamp.isAfter(consolidatedUntil)) continue;
        _pendingDetails.add(point);
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
      final thresholdKey = dateKey(threshold);

      final layers = await _rawBufferFile!.getLayerNames();
      for (final layer in layers) {
        String? dKey;
        if (layer.startsWith(_rawLayerPrefix)) {
          dKey = layer.replaceFirst(_rawLayerPrefix, '');
        } else if (layer.startsWith(_gnssRawLayerPrefix)) {
          dKey = layer.replaceFirst(_gnssRawLayerPrefix, '');
        }
        if (dKey == null) continue;
        if (dKey.compareTo(thresholdKey) < 0) {
          AppLogger.debug('$_logTag: 古いrawレイヤ削除: $layer');
          await _rawBufferFile!.removeLayer(layer);
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: rawクリーンアップエラー: $e');
    }
  }

  // ==============================
  // 端末間の過去日統合（当日分は対象外）
  // ==============================

  static final RegExp _dateKeyPattern = RegExp(r'^\d{4}_\d{2}_\d{2}$');

  static String _baseDateOfFeatureName(String name) => name.split(' #').first;

  static bool _isPastDateKey(String dKey, String todayKey) =>
      _dateKeyPattern.hasMatch(dKey) && dKey.compareTo(todayKey) < 0;

  static bool _isNewerBlock(
    ({int featureCount, int detailCount}) a,
    ({int featureCount, int detailCount}) b,
  ) {
    if (a.detailCount != b.detailCount) return a.detailCount > b.detailCount;
    return a.featureCount > b.featureCount;
  }

  /// リモート（Drive 等）の `gps_history.gpkg` と前日以前の確定データを双方向統合する。
  ///
  /// ルール:
  /// - 当日分（`dateKey >= todayKey`）は一切読み書きしない（記録中の競合を完全に防ぐ）。
  /// - 単位は `(device_id, dateKey)` ブロック。自分が書いた過去日ブロックをリモートへ追加し、
  ///   他端末（または再インストール前の過去分）の過去日ブロックをローカルへ取り込む。
  Future<({bool changedLocal, bool changedRemote, int importedDays, int exportedDays})>
      mergePastDaysWith(String remoteGpkgPath) async {
    if (_historyFile == null) {
      return (changedLocal: false, changedRemote: false, importedDays: 0, exportedDays: 0);
    }

    if (_isInitialized && _rawBufferFile != null) {
      await _checkAndRotateDay();
    }
    final todayKey = _currentDateKey ?? dateKey(DateTime.now());
    final remoteFile = GeoPackageFile(
      [p.basename(remoteGpkgPath)],
      absolutePath: remoteGpkgPath,
    );

    var changedLocal = false;
    var changedRemote = false;
    var importedDays = 0;
    var exportedDays = 0;

    try {
      if (!await File(remoteGpkgPath).exists()) {
        await remoteFile.createEmptyDatabase();
      }
      await _ensureTracksLayerOn(remoteFile);
      await _ensureDetailsTableOn(remoteFile);
      await _ensureGnssTracksLayerOn(remoteFile);
      await _ensureGnssDetailsTableOn(remoteFile);
      await _ensureConnectionEventsTableOn(remoteFile);
      await _ensureGnssTracksLayerOn(_historyFile!, backfillDeviceId: _deviceId);
      await _ensureGnssDetailsTableOn(_historyFile!, backfillDeviceId: _deviceId);
      await _ensureConnectionEventsTableOn(_historyFile!);

      final localIndex = await _collectPastDayBlocks(
        _historyFile!,
        todayKey,
        fallbackDeviceId: _deviceId,
      );
      final remoteIndex = await _collectPastDayBlocks(
        remoteFile,
        todayKey,
        fallbackDeviceId: '',
      );

      final importedKeys = <({String deviceId, String dateKey})>{};

      // 1. リモート → ローカル（ローカルに未取得の過去日ブロックを取り込む）
      for (final entry in remoteIndex.stats.entries) {
        final key = entry.key;
        final remoteStat = entry.value;
        final localStat = localIndex.stats[key];
        final shouldImport = localStat == null ||
            (key.deviceId != _deviceId && _isNewerBlock(remoteStat, localStat));
        if (!shouldImport) continue;

        await _copyDayBlock(
          from: remoteFile,
          to: _historyFile!,
          deviceId: key.deviceId,
          dateKey: key.dateKey,
          fromFallbackDeviceId: '',
          fromFids: remoteIndex.fidsByBlock[key] ?? const [],
          toFids: localIndex.fidsByBlock[key] ?? const [],
        );
        importedKeys.add(key);
        importedDays++;
        changedLocal = true;
      }

      // 2. ローカル → リモート（リモートに未反映の過去日ブロックを書き出す）
      for (final entry in localIndex.stats.entries) {
        final key = entry.key;
        if (importedKeys.contains(key)) continue;
        final localStat = entry.value;
        final remoteStat = remoteIndex.stats[key];
        final shouldExport =
            remoteStat == null || _isNewerBlock(localStat, remoteStat);
        if (!shouldExport) continue;

        await _copyDayBlock(
          from: _historyFile!,
          to: remoteFile,
          deviceId: key.deviceId,
          dateKey: key.dateKey,
          fromFallbackDeviceId: _deviceId,
          fromFids: localIndex.fidsByBlock[key] ?? const [],
          toFids: remoteIndex.fidsByBlock[key] ?? const [],
        );
        exportedDays++;
        changedRemote = true;
      }

      // 3. 外部GNSS軌跡 (gnss_tracks + gnss_track_details) と接続イベントの過去日双方向統合
      final gnssMerge = await _mergePastGnssAndEvents(
        localFile: _historyFile!,
        remoteFile: remoteFile,
        todayKey: todayKey,
        localFallbackDeviceId: _deviceId,
      );
      if (gnssMerge.changedLocal) changedLocal = true;
      if (gnssMerge.changedRemote) changedRemote = true;
      importedDays += gnssMerge.importedDays;
      exportedDays += gnssMerge.exportedDays;

      if (changedRemote) {
        await GeoPackageFile.prepareForHandOff(remoteGpkgPath);
      }
    } finally {
      await remoteFile.dispose();
    }

    if (changedLocal) {
      onConsolidated?.call();
      notifyListeners();
    }

    return (
      changedLocal: changedLocal,
      changedRemote: changedRemote,
      importedDays: importedDays,
      exportedDays: exportedDays,
    );
  }

  static Future<({
    Map<({String deviceId, String dateKey}), ({int featureCount, int detailCount})> stats,
    Map<({String deviceId, String dateKey}), List<int>> fidsByBlock,
  })> _collectPastDayBlocks(
    GeoPackageFile file,
    String todayKey, {
    required String fallbackDeviceId,
  }) async {
    final stats = <({String deviceId, String dateKey}), ({int featureCount, int detailCount})>{};
    final fidsByBlock = <({String deviceId, String dateKey}), List<int>>{};
    final layers = await file.getLayerNames();
    if (layers.contains(_tracksLayerName)) {
      final features = await file.getFeatures(_tracksLayerName);
      for (final f in features) {
        final name = f['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final dKey = _baseDateOfFeatureName(name);
        if (!_isPastDateKey(dKey, todayKey)) continue;
        final rawDev = f['device_id']?.toString() ?? '';
        final dev = rawDev.isEmpty ? fallbackDeviceId : rawDev;
        if (dev.isEmpty) continue;
        final k = (deviceId: dev, dateKey: dKey);
        final prev = stats[k] ?? (featureCount: 0, detailCount: 0);
        stats[k] = (featureCount: prev.featureCount + 1, detailCount: prev.detailCount);
        final id = f[featureIdKey];
        final fid = id is int ? id : int.tryParse(id?.toString() ?? '');
        if (fid != null) {
          (fidsByBlock[k] ??= <int>[]).add(fid);
        }
      }
    }

    final db = await file.getDatabase();
    final rows = await db.rawQuery(
      'SELECT device_id, track_date, COUNT(*) as cnt FROM $_detailsTableName '
      'WHERE track_date < ? GROUP BY device_id, track_date',
      [todayKey],
    );
    for (final r in rows) {
      final dKey = r['track_date']?.toString() ?? '';
      if (!_isPastDateKey(dKey, todayKey)) continue;
      final rawDev = r['device_id']?.toString() ?? '';
      final dev = rawDev.isEmpty ? fallbackDeviceId : rawDev;
      if (dev.isEmpty) continue;
      final cnt = (r['cnt'] as int?) ?? 0;
      final k = (deviceId: dev, dateKey: dKey);
      final prev = stats[k] ?? (featureCount: 0, detailCount: 0);
      stats[k] = (featureCount: prev.featureCount, detailCount: prev.detailCount + cnt);
    }
    return (stats: stats, fidsByBlock: fidsByBlock);
  }

  static Future<void> _copyDayBlock({
    required GeoPackageFile from,
    required GeoPackageFile to,
    required String deviceId,
    required String dateKey,
    required String fromFallbackDeviceId,
    required List<int> fromFids,
    required List<int> toFids,
  }) async {
    // 1. 既存の (deviceId, dateKey) フィーチャを to から削除
    for (final fid in toFids) {
      await to.removeFeature(_tracksLayerName, fid);
    }

    // 2. from の (deviceId, dateKey) フィーチャを to に追加
    final toDb = await to.getDatabase();
    for (final fid in fromFids) {
      final detail = await from.getFeature(_tracksLayerName, fid);
      if (detail == null) continue;
      final coords = _lineCoords(detail[featureGeometryKey]);
      if (coords.length < 2) continue;
      final name = detail['name']?.toString() ?? dateKey;
      final newFid = await to.addLine(
        _tracksLayerName,
        coords,
        name: name,
        description: detail['description']?.toString() ?? '',
      );
      if (newFid != null) {
        await toDb.update(
          _tracksLayerName,
          {'device_id': deviceId},
          where: 'fid = ?',
          whereArgs: [newFid],
        );
      }
    }

    // 3. gps_track_details の (deviceId, dateKey) 行を入れ替え
    final fromDb = await from.getDatabase();
    final detailRows = await fromDb.query(
      _detailsTableName,
      where: 'track_date = ? AND (device_id = ? OR (? = ? AND (device_id IS NULL OR device_id = \'\')))',
      whereArgs: [dateKey, deviceId, deviceId, fromFallbackDeviceId],
      orderBy: 'point_index ASC',
    );
    await toDb.transaction((txn) async {
      await txn.delete(
        _detailsTableName,
        where: 'track_date = ? AND device_id = ?',
        whereArgs: [dateKey, deviceId],
      );
      final batch = txn.batch();
      for (final row in detailRows) {
        batch.insert(_detailsTableName, {
          'track_date': dateKey,
          'point_index': row['point_index'],
          'timestamp': row['timestamp'],
          'latitude': row['latitude'],
          'longitude': row['longitude'],
          'altitude': row['altitude'],
          'accuracy': row['accuracy'],
          'speed': row['speed'],
          'bearing': row['bearing'],
          'source_type': row['source_type'] ?? 'GPS',
          'device_id': deviceId,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  // ==============================
  // クエリ（ダイアログ用）
  // ==============================

  /// 利用可能な日付キーのリストを取得（新しい順）。
  /// 同日に複数端末の記録がある場合は、他端末分に ` [<端末ID先頭4文字>]` を添えて区別できるようにする。
  Future<List<String>> getAvailableDates() async {
    if (_historyFile == null) return [];

    try {
      final layers = await _historyFile!.getLayerNames();
      if (!layers.contains(_tracksLayerName)) return [];

      final features = await _historyFile!.getFeatures(_tracksLayerName);
      // 日付ごとにどの device_id があるかを集計
      final devicesByDate = <String, Set<String>>{};
      for (final f in features) {
        final name = f['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final dKey = _baseDateOfFeatureName(name);
        final rawDev = f['device_id']?.toString() ?? '';
        final dev = rawDev.isEmpty ? _deviceId : rawDev;
        (devicesByDate[dKey] ??= <String>{}).add(dev);
      }

      final dateKeys = <String>{};
      for (final f in features) {
        final name = f['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final dKey = _baseDateOfFeatureName(name);
        final rawDev = f['device_id']?.toString() ?? '';
        final dev = rawDev.isEmpty ? _deviceId : rawDev;
        final hasMultipleDevices = (devicesByDate[dKey]?.length ?? 0) > 1;
        if (hasMultipleDevices && dev != _deviceId && dev.isNotEmpty) {
          final tag = dev.length > 4 ? dev.substring(0, 4) : dev;
          dateKeys.add('$name [$tag]');
        } else {
          dateKeys.add(name);
        }
      }

      if (layers.contains(gnssTracksLayerName)) {
        final gnssFeatures = await _historyFile!.getFeatures(gnssTracksLayerName);
        for (final f in gnssFeatures) {
          final name = f['name']?.toString();
          if (name == null || name.isEmpty) continue;
          final rawDev = f['device_id']?.toString() ?? '';
          final dev = rawDev.isEmpty ? _deviceId : rawDev;
          if (dev != _deviceId && dev.isNotEmpty) {
            final tag = dev.length > 4 ? dev.substring(0, 4) : dev;
            dateKeys.add('$name [$gnssTag:$tag]');
          } else {
            dateKeys.add('$name [$gnssTag]');
          }
        }
      }

      final sorted = dateKeys.toList()..sort((a, b) => b.compareTo(a));
      return sorted;
    } catch (e) {
      AppLogger.debug('$_logTag: 日付リスト取得エラー: $e');
      return [];
    }
  }

  /// 日付キーを表示用にフォーマット
  /// 例: '2026_02_06' → '2026/02/06'
  static String formatLayerNameAsDate(String layerName) {
    return layerName.replaceAll('_', '/');
  }

  /// 特定日付の全ポイントを取得
  /// 軌跡のフィーチャ名（`2026_09_12` / `2026_09_12 #2` / `2026_09_12 [a1b2]`）の区間の点。
  ///
  /// 点の表は日付＋端末ごとに引き、その日の点を記録と同じ規則（[segmentGap] 以上空いたら次の区間）で分けて返す。
  Future<List<GpsTrackPoint>> getPointsForDate(String name) async {
    var cleanName = name;
    String? deviceTag;
    var isGnss = false;
    final bracketIdx = name.lastIndexOf(' [');
    if (bracketIdx > 0 && name.endsWith(']')) {
      final rawTag = name.substring(bracketIdx + 2, name.length - 1);
      cleanName = name.substring(0, bracketIdx);
      if (rawTag == gnssTag) {
        isGnss = true;
      } else if (rawTag.startsWith('$gnssTag:')) {
        isGnss = true;
        deviceTag = rawTag.substring(gnssTag.length + 1);
      } else {
        deviceTag = rawTag;
      }
    }
    final dateKey = cleanName.split(' #').first;
    final index = segmentIndexOf(cleanName, dateKey) ?? 1;
    final dayPoints = isGnss
        ? await _gnssPointsOfDay(dateKey, deviceTag: deviceTag)
        : await _pointsOfDay(dateKey, deviceTag: deviceTag);
    return segmentOf(dayPoints, index);
  }

  /// 指定日付の外部GNSS詳細ポイント列を取得する
  Future<List<GpsTrackPoint>> getGnssPointsForDate(
    String dateOrSegmentName,
  ) =>
      getPointsForDate(
        dateOrSegmentName.endsWith(']')
            ? dateOrSegmentName
            : '$dateOrSegmentName [$gnssTag]',
      );

  /// [points]（時刻順）を [segmentGap] で区切った [index] 本目（1 始まり）
  @visibleForTesting
  static List<GpsTrackPoint> segmentOf(List<GpsTrackPoint> points, int index) {
    var segment = 1;
    var start = 0;
    for (var i = 1; i < points.length; i++) {
      if (points[i].timestamp.difference(points[i - 1].timestamp) < segmentGap) continue;
      if (segment == index) return points.sublist(start, i);
      segment++;
      start = i;
    }
    return segment == index ? points.sublist(start) : const [];
  }

  Future<List<GpsTrackPoint>> _pointsOfDay(
    String dateKey, {
    String? deviceTag,
  }) async {
    if (_historyFile == null) return [];

    try {
      final db = await _historyFile!.getDatabase();
      // その日にどの device_id の点があるか確認し、1つの端末に絞って取得する（2台同時記録のジグザグ混線を防ぐ）
      String? targetDeviceId;
      if (deviceTag != null && deviceTag.isNotEmpty) {
        final devRows = await db.rawQuery(
          'SELECT DISTINCT device_id FROM $_detailsTableName WHERE track_date = ? AND device_id LIKE ?',
          [dateKey, '$deviceTag%'],
        );
        targetDeviceId = devRows.firstOrNull?['device_id']?.toString();
      } else {
        final devRows = await db.rawQuery(
          'SELECT DISTINCT device_id FROM $_detailsTableName WHERE track_date = ?',
          [dateKey],
        );
        final devs = [
          for (final r in devRows) (r['device_id']?.toString() ?? ''),
        ];
        if (devs.contains(_deviceId) || devs.contains('')) {
          targetDeviceId = _deviceId;
        } else if (devs.isNotEmpty) {
          targetDeviceId = devs.first;
        }
      }

      final List<Map<String, Object?>> rows;
      if (targetDeviceId == null || targetDeviceId == _deviceId) {
        rows = await db.query(
          _detailsTableName,
          where: 'track_date = ? AND (device_id IS NULL OR device_id = \'\' OR device_id = ?)',
          whereArgs: [dateKey, _deviceId],
          orderBy: 'point_index ASC',
        );
      } else {
        rows = await db.query(
          _detailsTableName,
          where: 'track_date = ? AND device_id = ?',
          whereArgs: [dateKey, targetDeviceId],
          orderBy: 'point_index ASC',
        );
      }

      return [
        for (final row in rows)
          _trackPointFromRow(
            row,
            LatLng((row['latitude'] as num).toDouble(), (row['longitude'] as num).toDouble()),
          ),
      ];
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
    final allPoints = await _pointsOfDay(dateKey);
    return allPoints
        .where((p) =>
            !p.timestamp.isBefore(start) && !p.timestamp.isAfter(end))
        .toList();
  }

  // ==============================
  // 外部GNSS常時記録（gnss_tracks / gnss_track_details / gnss_raw_）
  // ==============================

  String _buildGnssRawLayerName(String dKey) => '$_gnssRawLayerPrefix$dKey';

  Future<void> _onGnssInfoReceived(GpsInfo info) async {
    if (!_isInitialized || _rawBufferFile == null) return;
    final lat = info.latitude;
    final lon = info.longitude;
    if (lat == null || lon == null || (info.gpsQuality ?? 0) <= 0) return;

    final ts = info.timestamp ?? DateTime.now();
    final position = LatLng(lat, lon);
    final gap =
        _lastGnssRecordedTime == null ? null : ts.difference(_lastGnssRecordedTime!);
    // Bluetooth SPP バッファ経由では 1.000s 周期の NMEA が ±50〜120ms 前後して届くため、
    // 150ms のジッター許容を持たせて毎秒エポックの取りこぼしを防ぐ
    final targetMs = gnssFilter.settings.intervalSeconds * 1000;
    final effectiveJudgeTime = (_lastGnssRecordedTime != null &&
            gap != null &&
            gap.inMilliseconds >= math.max(200, targetMs - 150) &&
            gap.inMilliseconds < targetMs)
        ? _lastGnssRecordedTime!.add(Duration(milliseconds: targetMs))
        : ts;
    final verdict = gnssFilter.judge(
      position: position,
      time: effectiveJudgeTime,
      accuracy: info.accuracy,
      lastTime: _lastGnssRecordedTime,
      lastPosition: _lastGnssRecordedPosition,
      newSegment: gap != null && gap >= segmentGap,
    );
    // 器械点・基準点で三脚やポールに据えて静止観測している間（TruPulse 併用時など）、
    // RTK FIX で座標がミリ単位まで完全一致（duplicate）しても 1 秒ごとのエポックを欠かさず gnss_track_details に蓄える
    if (verdict != TrackFixVerdict.accept &&
        verdict != TrackFixVerdict.duplicate) {
      return;
    }

    try {
      await _checkAndRotateDay();
      if (_currentDateKey == null) return;

      if (_lastGnssRecordedTime != null) {
        final g = ts.difference(_lastGnssRecordedTime!);
        if (g >= segmentGap) await _startNewGnssSegment(g);
      }

      final rawLayerName = _buildGnssRawLayerName(_currentDateKey!);
      final ntripMount = ntripMountpointProvider?.call();

      final rawId = await _rawBufferFile!.addPointWithAttributes(
        rawLayerName,
        position,
        {
          'timestamp': ts.toIso8601String(),
          'altitude': info.altitude,
          'accuracy': info.accuracy,
          'accuracy_source': info.accuracySource,
          'speed': info.speed,
          'bearing': info.bearing,
          'gps_quality': info.gpsQuality,
          'fix_type': info.fixType,
          'correction_source': info.correctionSource,
          'satellite_count': info.satelliteCount,
          'hdop': info.hdop,
          'pdop': info.pdop,
          'vdop': info.vdop,
          'gnss_device': info.selectedDevice,
          'ntrip_mountpoint': ntripMount,
          'raw_gga': info.nmea,
        },
      );

      _lastGnssRecordedTime = ts;
      _lastGnssRecordedPosition = position;

      if (rawId != null) _pendingGnssRawIds.add(rawId);

      _pendingGnssDetails.add(GpsTrackPoint(
        latitude: lat,
        longitude: lon,
        altitude: info.altitude,
        accuracy: info.accuracy,
        accuracySource: info.accuracySource,
        speed: info.speed,
        bearing: info.bearing,
        timestamp: ts,
        sourceType: 'GNSS',
        gpsQuality: info.gpsQuality,
        fixType: info.fixType,
        correctionSource: info.correctionSource,
        satelliteCount: info.satelliteCount,
        hdop: info.hdop,
        pdop: info.pdop,
        vdop: info.vdop,
        gnssDevice: info.selectedDevice,
        ntripMountpoint: ntripMount,
        rawGga: info.nmea,
      ));

      if (_pendingGnssDetails.length <= 5 ||
          _pendingGnssDetails.length % 5 == 0) {
        notifyListeners();
      }
    } catch (e) {
      AppLogger.debug('$_logTag: 外部GNSS軌跡記録エラー: $e');
    }
  }

  Future<void> _ensureGnssRawLayer(String dKey) async {
    if (_rawBufferFile == null) return;
    final layerName = _buildGnssRawLayerName(dKey);
    final existingLayers = await _rawBufferFile!.getLayerNames();
    if (existingLayers.contains(layerName)) return;

    await _rawBufferFile!.addLayer(layerName, GeometryType.point);
    await _rawBufferFile!.addAttributeColumns(layerName, {
      'timestamp': 'TEXT',
      'altitude': 'REAL',
      'accuracy': 'REAL',
      'accuracy_source': 'TEXT',
      'speed': 'REAL',
      'bearing': 'REAL',
      'gps_quality': 'INTEGER',
      'fix_type': 'TEXT',
      'correction_source': 'TEXT',
      'satellite_count': 'INTEGER',
      'hdop': 'REAL',
      'pdop': 'REAL',
      'vdop': 'REAL',
      'gnss_device': 'TEXT',
      'ntrip_mountpoint': 'TEXT',
      'raw_gga': 'TEXT',
    });
  }

  Future<void> _ensureGnssTracksLayer() async {
    if (_historyFile == null) return;
    await _ensureGnssTracksLayerOn(_historyFile!, backfillDeviceId: _deviceId);
  }

  static Future<void> _ensureGnssTracksLayerOn(
    GeoPackageFile file, {
    String? backfillDeviceId,
  }) async {
    final existingLayers = await file.getLayerNames();
    if (!existingLayers.contains(gnssTracksLayerName)) {
      AppLogger.debug('$_logTag: gnss_tracks LineLayer 作成');
      await file.addLayer(gnssTracksLayerName, GeometryType.linestring);
    }

    final columns = await file.getTableColumns(gnssTracksLayerName);
    const needed = {
      'name': 'TEXT',
      'description': 'TEXT',
      'device_id': 'TEXT',
      'gnss_device': 'TEXT',
    };
    for (final entry in needed.entries) {
      if (!columns.contains(entry.key)) {
        await file.addAttributeColumn(
          gnssTracksLayerName,
          entry.key,
          entry.value,
        );
      }
    }
    if (backfillDeviceId != null && backfillDeviceId.isNotEmpty) {
      final db = await file.getDatabase();
      await db.rawUpdate(
        'UPDATE $gnssTracksLayerName SET device_id = ? WHERE device_id IS NULL OR device_id = \'\'',
        [backfillDeviceId],
      );
    }
  }

  Future<void> _ensureGnssDetailsTable() async {
    if (_historyFile == null) return;
    await _ensureGnssDetailsTableOn(_historyFile!, backfillDeviceId: _deviceId);
  }

  static Future<void> _ensureGnssDetailsTableOn(
    GeoPackageFile file, {
    String? backfillDeviceId,
  }) async {
    try {
      final db = await file.getDatabase();
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [gnssDetailsTableName],
      );
      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE $gnssDetailsTableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_date TEXT NOT NULL,
            point_index INTEGER NOT NULL,
            timestamp TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude REAL,
            accuracy REAL,
            accuracy_source TEXT,
            speed REAL,
            bearing REAL,
            gps_quality INTEGER,
            fix_type TEXT,
            correction_source TEXT,
            satellite_count INTEGER,
            hdop REAL,
            pdop REAL,
            vdop REAL,
            gnss_device TEXT,
            ntrip_mountpoint TEXT,
            raw_gga TEXT,
            source_type TEXT DEFAULT 'GNSS',
            device_id TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_gnss_track_details_date '
          'ON $gnssDetailsTableName(track_date)',
        );
        await db.execute(
          'CREATE INDEX idx_gnss_track_details_date_idx '
          'ON $gnssDetailsTableName(track_date, point_index)',
        );
      }
      if (backfillDeviceId != null && backfillDeviceId.isNotEmpty) {
        await db.rawUpdate(
          'UPDATE $gnssDetailsTableName SET device_id = ? WHERE device_id IS NULL OR device_id = \'\'',
          [backfillDeviceId],
        );
      }
    } catch (e) {
      AppLogger.debug('$_logTag: gnss_track_details テーブル作成エラー: $e');
    }
  }

  Future<void> _startNewGnssSegment(Duration gap) async {
    await _consolidateGnss();
    _gnssSegmentIndex++;
    _todayGnssTrackFeatureId = null;
    _lastGnssConsolidatedPosition = null;
    AppLogger.debug('$_logTag: 外部GNSS ${gap.inMinutes} 分空いたので新しい区間 #$_gnssSegmentIndex');
    notifyListeners();
  }

  bool _isConsolidatingGnss = false;

  Future<void> _consolidateGnss() async {
    if (_isConsolidatingGnss ||
        _historyFile == null ||
        _pendingGnssDetails.isEmpty ||
        _currentDateKey == null) {
      return;
    }

    _isConsolidatingGnss = true;
    try {
      final detailsToWrite = List<GpsTrackPoint>.from(_pendingGnssDetails);
      final rawIdsToDelete = List<int>.from(_pendingGnssRawIds);
      _pendingGnssDetails.clear();
      _pendingGnssRawIds.clear();

      final currentLine = await _readCurrentGnssLine();
      // SQLite の gnss_track_details には静止中の毎秒エポックを全件残しつつ、
      // 地図描画・QGIS 用の LineString ジオメトリには連続重複頂点（duplicate nodes）を入れない
      for (final p in detailsToWrite) {
        final coord = p.toLatLng();
        if (currentLine.isEmpty || currentLine.last != coord) {
          currentLine.add(coord);
        }
      }

      final db = await _historyFile!.getDatabase();
      final devLabel =
          detailsToWrite.map((p) => p.gnssDevice).whereType<String>().lastOrNull ?? '';

      if (currentLine.length >= 2) {
        if (_todayGnssTrackFeatureId == null) {
          _todayGnssTrackFeatureId = await _historyFile!.addLine(
            gnssTracksLayerName,
            currentLine,
            name: _gnssSegmentName,
            description: devLabel,
          );
          if (_todayGnssTrackFeatureId != null) {
            await db.update(
              gnssTracksLayerName,
              {
                if (_deviceId.isNotEmpty) 'device_id': _deviceId,
                if (devLabel.isNotEmpty) 'gnss_device': devLabel,
              },
              where: 'fid = ?',
              whereArgs: [_todayGnssTrackFeatureId],
            );
          }
        } else {
          try {
            await _historyFile!.updateLine(
              gnssTracksLayerName,
              _todayGnssTrackFeatureId!,
              currentLine,
              name: _gnssSegmentName,
              description: devLabel,
            );
          } catch (_) {
            _todayGnssTrackFeatureId = await _historyFile!.addLine(
              gnssTracksLayerName,
              currentLine,
              name: _gnssSegmentName,
              description: devLabel,
            );
            if (_todayGnssTrackFeatureId != null && _deviceId.isNotEmpty) {
              await db.update(
                gnssTracksLayerName,
                {'device_id': _deviceId, 'gnss_device': devLabel},
                where: 'fid = ?',
                whereArgs: [_todayGnssTrackFeatureId],
              );
            }
          }
        }
      }

      await db.transaction((txn) async {
        for (final pt in detailsToWrite) {
          await txn.insert(gnssDetailsTableName, {
            'track_date': _currentDateKey,
            'point_index': _lastGnssConsolidatedIndex,
            'timestamp': pt.timestamp.toIso8601String(),
            'latitude': pt.latitude,
            'longitude': pt.longitude,
            'altitude': pt.altitude,
            'accuracy': pt.accuracy,
            'accuracy_source': pt.accuracySource,
            'speed': pt.speed,
            'bearing': pt.bearing,
            'gps_quality': pt.gpsQuality,
            'fix_type': pt.fixType,
            'correction_source': pt.correctionSource,
            'satellite_count': pt.satelliteCount,
            'hdop': pt.hdop,
            'pdop': pt.pdop,
            'vdop': pt.vdop,
            'gnss_device': pt.gnssDevice,
            'ntrip_mountpoint': pt.ntripMountpoint,
            'raw_gga': pt.rawGga,
            'source_type': 'GNSS',
            'device_id': _deviceId,
          });
          _lastGnssConsolidatedIndex++;
        }
      });

      if (rawIdsToDelete.isNotEmpty && _rawBufferFile != null) {
        try {
          final rawDb = await _rawBufferFile!.getDatabase();
          final rawLayerName = _buildGnssRawLayerName(_currentDateKey!);
          final placeholders = List.filled(rawIdsToDelete.length, '?').join(',');
          await rawDb.rawDelete(
            'DELETE FROM "$rawLayerName" WHERE rowid IN ($placeholders)',
            rawIdsToDelete,
          );
        } catch (e) {
          AppLogger.debug('$_logTag: GNSS Raw Buffer削除エラー: $e');
        }
      }

      if (currentLine.isNotEmpty) {
        _lastGnssConsolidatedPosition = currentLine.last;
      }
      lastConsolidatedGnssLine = currentLine;

      onConsolidated?.call();
    } catch (e) {
      AppLogger.debug('$_logTag: GNSS Consolidationエラー: $e');
    } finally {
      _isConsolidatingGnss = false;
    }
  }

  Future<List<LatLng>> _readCurrentGnssLine() async {
    if (_historyFile == null || _todayGnssTrackFeatureId == null) return [];
    try {
      final detail = await _historyFile!.getFeature(
        gnssTracksLayerName,
        _todayGnssTrackFeatureId!,
      );
      if (detail == null || detail[featureGeometryKey] == null) {
        _todayGnssTrackFeatureId = null;
        return [];
      }
      return _lineCoords(detail[featureGeometryKey]);
    } catch (_) {
      _todayGnssTrackFeatureId = null;
      return [];
    }
  }

  Future<void> _loadTodayGnssFromHistory() async {
    if (_historyFile == null || _currentDateKey == null) return;
    try {
      final existingLayers = await _historyFile!.getLayerNames();
      if (!existingLayers.contains(gnssTracksLayerName)) return;

      final features = await _historyFile!.getFeatures(gnssTracksLayerName);
      int? latestId;
      var latestIndex = 0;
      for (final feature in features) {
        if (!_isOwnDevice(feature['device_id'])) continue;
        final index = segmentIndexOf(
          feature['name']?.toString(),
          _currentDateKey!,
        );
        if (index == null || index <= latestIndex) continue;
        final id = feature[featureIdKey];
        if (id == null) continue;
        latestIndex = index;
        latestId = id is int ? id : int.tryParse(id.toString()) ?? 0;
      }
      if (latestId != null) {
        _todayGnssTrackFeatureId = latestId;
        _gnssSegmentIndex = latestIndex;
        final detail = await _historyFile!.getFeature(
          gnssTracksLayerName,
          latestId,
        );
        if (detail != null) {
          final coords = _lineCoords(detail[featureGeometryKey]);
          _lastGnssRecordedPosition = coords.lastOrNull ?? _lastGnssRecordedPosition;
          _lastGnssConsolidatedPosition = coords.lastOrNull;
          lastConsolidatedGnssLine = coords;
        }
      }

      final db = await _historyFile!.getDatabase();
      final countResult = await db.rawQuery(
        'SELECT COUNT(*) as cnt, MAX(timestamp) as last_ts FROM $gnssDetailsTableName '
        'WHERE track_date = ? AND (device_id IS NULL OR device_id = \'\' OR device_id = ?)',
        [_currentDateKey, _deviceId],
      );
      _lastGnssConsolidatedIndex = (countResult.first['cnt'] as int?) ?? 0;
      final lastTs = countResult.first['last_ts']?.toString();
      if (lastTs != null) _lastGnssRecordedTime = DateTime.tryParse(lastTs);
    } catch (e) {
      AppLogger.debug('$_logTag: GNSS History復元エラー: $e');
    }
  }

  Future<void> _recoverUnconsolidatedGnss() async {
    if (_rawBufferFile == null || _currentDateKey == null) return;
    try {
      final rawLayerName = _buildGnssRawLayerName(_currentDateKey!);
      final existingLayers = await _rawBufferFile!.getLayerNames();
      if (!existingLayers.contains(rawLayerName)) return;

      final consolidatedUntil = _lastGnssRecordedTime;
      final rawFeatures = await _rawBufferFile!.getFeatures(rawLayerName);
      if (rawFeatures.isEmpty) return;

      var recovered = 0;
      for (final feature in rawFeatures) {
        final id = feature[featureIdKey];
        if (id == null) continue;
        final featureId = id is int ? id : int.tryParse(id.toString()) ?? 0;
        final detail = await _rawBufferFile!.getFeature(rawLayerName, featureId);
        if (detail == null || detail[featureGeometryKey] == null) continue;

        final geom = detail[featureGeometryKey];
        LatLng? latLng;
        if (geom is List && geom.isNotEmpty && geom.first is LatLng) {
          latLng = geom.first as LatLng;
        }
        if (latLng == null) continue;

        final point = _gnssTrackPointFromRow(detail, latLng);
        if (consolidatedUntil != null && !point.timestamp.isAfter(consolidatedUntil)) {
          continue;
        }
        _pendingGnssDetails.add(point);
        _pendingGnssRawIds.add(featureId);
        recovered++;
      }

      if (recovered > 0) {
        final lastTs = _pendingGnssDetails.last.timestamp;
        if (_lastGnssRecordedTime == null || lastTs.isAfter(_lastGnssRecordedTime!)) {
          _lastGnssRecordedTime = lastTs;
        }
        await _consolidateGnss();
      }
    } catch (e) {
      AppLogger.debug('$_logTag: GNSS未反映復元エラー: $e');
    }
  }

  static GpsTrackPoint _gnssTrackPointFromRow(
    Map<String, dynamic> row,
    LatLng position,
  ) =>
      GpsTrackPoint(
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: (row['altitude'] as num?)?.toDouble(),
        accuracy: (row['accuracy'] as num?)?.toDouble(),
        accuracySource: row['accuracy_source']?.toString(),
        speed: (row['speed'] as num?)?.toDouble(),
        bearing: (row['bearing'] as num?)?.toDouble(),
        timestamp:
            DateTime.tryParse(row['timestamp']?.toString() ?? '') ?? DateTime.now(),
        sourceType: 'GNSS',
        gpsQuality: (row['gps_quality'] as num?)?.toInt(),
        fixType: row['fix_type']?.toString(),
        correctionSource: row['correction_source']?.toString(),
        satelliteCount: (row['satellite_count'] as num?)?.toInt(),
        hdop: (row['hdop'] as num?)?.toDouble(),
        pdop: (row['pdop'] as num?)?.toDouble(),
        vdop: (row['vdop'] as num?)?.toDouble(),
        gnssDevice: row['gnss_device']?.toString(),
        ntripMountpoint: row['ntrip_mountpoint']?.toString(),
        rawGga: row['raw_gga']?.toString(),
      );

  Future<List<GpsTrackPoint>> _gnssPointsOfDay(
    String dKey, {
    String? deviceTag,
  }) async {
    if (_historyFile == null) return [];
    try {
      final db = await _historyFile!.getDatabase();
      String? targetDeviceId;
      if (deviceTag != null && deviceTag.isNotEmpty) {
        final devRows = await db.rawQuery(
          'SELECT DISTINCT device_id FROM $gnssDetailsTableName WHERE track_date = ? AND device_id LIKE ?',
          [dKey, '$deviceTag%'],
        );
        targetDeviceId = devRows.firstOrNull?['device_id']?.toString();
      } else {
        targetDeviceId = _deviceId;
      }

      final List<Map<String, Object?>> rows;
      if (targetDeviceId == null || targetDeviceId == _deviceId) {
        rows = await db.query(
          gnssDetailsTableName,
          where:
              'track_date = ? AND (device_id IS NULL OR device_id = \'\' OR device_id = ?)',
          whereArgs: [dKey, _deviceId],
          orderBy: 'point_index ASC',
        );
      } else {
        rows = await db.query(
          gnssDetailsTableName,
          where: 'track_date = ? AND device_id = ?',
          whereArgs: [dKey, targetDeviceId],
          orderBy: 'point_index ASC',
        );
      }

      return [
        for (final row in rows)
          _gnssTrackPointFromRow(
            row,
            LatLng(
              (row['latitude'] as num).toDouble(),
              (row['longitude'] as num).toDouble(),
            ),
          ),
      ];
    } catch (e) {
      AppLogger.debug('$_logTag: gnss_track_details クエリエラー: $e');
      return [];
    }
  }

  // ==============================
  // 機器接続・切断イベントの構造化記録（AIエージェント協働解析用）
  // ==============================

  Future<void> _ensureConnectionEventsTable() async {
    if (_historyFile == null) return;
    await _ensureConnectionEventsTableOn(_historyFile!);
  }

  static Future<void> _ensureConnectionEventsTableOn(GeoPackageFile file) async {
    try {
      final db = await file.getDatabase();
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [connectionEventsTableName],
      );
      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE $connectionEventsTableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            category TEXT NOT NULL,
            event_type TEXT NOT NULL,
            device_name TEXT NOT NULL,
            device_address TEXT,
            detail TEXT,
            device_id TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_device_conn_events_ts '
          'ON $connectionEventsTableName(timestamp)',
        );
      }
    } catch (e) {
      AppLogger.debug('$_logTag: $connectionEventsTableName テーブル作成エラー: $e');
    }
  }

  static Future<({bool changedLocal, bool changedRemote, int importedDays, int exportedDays})>
      _mergePastGnssAndEvents({
    required GeoPackageFile localFile,
    required GeoPackageFile remoteFile,
    required String todayKey,
    required String localFallbackDeviceId,
  }) async {
    var changedLocal = false;
    var changedRemote = false;
    var importedDays = 0;
    var exportedDays = 0;

    final localGnss = await _collectPastGnssBlocks(
      localFile,
      todayKey,
      fallbackDeviceId: localFallbackDeviceId,
    );
    final remoteGnss = await _collectPastGnssBlocks(
      remoteFile,
      todayKey,
      fallbackDeviceId: '',
    );
    final importedKeys = <({String deviceId, String dateKey})>{};

    for (final entry in remoteGnss.stats.entries) {
      final key = entry.key;
      final remoteStat = entry.value;
      final localStat = localGnss.stats[key];
      final shouldImport = localStat == null ||
          (key.deviceId != localFallbackDeviceId &&
              _isNewerBlock(remoteStat, localStat));
      if (!shouldImport) continue;

      await _copyGnssDayBlock(
        from: remoteFile,
        to: localFile,
        deviceId: key.deviceId,
        dateKey: key.dateKey,
        fromFallbackDeviceId: '',
        fromFids: remoteGnss.fidsByBlock[key] ?? const [],
        toFids: localGnss.fidsByBlock[key] ?? const [],
      );
      importedKeys.add(key);
      importedDays++;
      changedLocal = true;
    }

    for (final entry in localGnss.stats.entries) {
      final key = entry.key;
      if (importedKeys.contains(key)) continue;
      final localStat = entry.value;
      final remoteStat = remoteGnss.stats[key];
      final shouldExport =
          remoteStat == null || _isNewerBlock(localStat, remoteStat);
      if (!shouldExport) continue;

      await _copyGnssDayBlock(
        from: localFile,
        to: remoteFile,
        deviceId: key.deviceId,
        dateKey: key.dateKey,
        fromFallbackDeviceId: localFallbackDeviceId,
        fromFids: localGnss.fidsByBlock[key] ?? const [],
        toFids: remoteGnss.fidsByBlock[key] ?? const [],
      );
      exportedDays++;
      changedRemote = true;
    }

    // 過去日の device_connection_events を双方向にマージ（重複キーで冪等追加）
    final todayIsoPrefix = todayKey.replaceAll('_', '-');
    if (await _copyMissingPastConnectionEvents(
      from: remoteFile,
      to: localFile,
      todayIsoPrefix: todayIsoPrefix,
      fallbackDeviceId: '',
    )) {
      changedLocal = true;
    }
    if (await _copyMissingPastConnectionEvents(
      from: localFile,
      to: remoteFile,
      todayIsoPrefix: todayIsoPrefix,
      fallbackDeviceId: localFallbackDeviceId,
    )) {
      changedRemote = true;
    }

    return (
      changedLocal: changedLocal,
      changedRemote: changedRemote,
      importedDays: importedDays,
      exportedDays: exportedDays,
    );
  }

  static Future<({
    Map<({String deviceId, String dateKey}), ({int featureCount, int detailCount})> stats,
    Map<({String deviceId, String dateKey}), List<int>> fidsByBlock,
  })> _collectPastGnssBlocks(
    GeoPackageFile file,
    String todayKey, {
    required String fallbackDeviceId,
  }) async {
    final stats = <({String deviceId, String dateKey}), ({int featureCount, int detailCount})>{};
    final fidsByBlock = <({String deviceId, String dateKey}), List<int>>{};
    final layers = await file.getLayerNames();
    if (layers.contains(gnssTracksLayerName)) {
      final features = await file.getFeatures(gnssTracksLayerName);
      for (final f in features) {
        final name = f['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final dKey = _baseDateOfFeatureName(name);
        if (!_isPastDateKey(dKey, todayKey)) continue;
        final rawDev = f['device_id']?.toString() ?? '';
        final dev = rawDev.isEmpty ? fallbackDeviceId : rawDev;
        if (dev.isEmpty) continue;
        final k = (deviceId: dev, dateKey: dKey);
        final prev = stats[k] ?? (featureCount: 0, detailCount: 0);
        stats[k] = (featureCount: prev.featureCount + 1, detailCount: prev.detailCount);
        final id = f[featureIdKey];
        final fid = id is int ? id : int.tryParse(id?.toString() ?? '');
        if (fid != null) {
          (fidsByBlock[k] ??= <int>[]).add(fid);
        }
      }
    }

    final db = await file.getDatabase();
    final rows = await db.rawQuery(
      'SELECT device_id, track_date, COUNT(*) as cnt FROM $gnssDetailsTableName '
      'WHERE track_date < ? GROUP BY device_id, track_date',
      [todayKey],
    );
    for (final r in rows) {
      final dKey = r['track_date']?.toString() ?? '';
      if (!_isPastDateKey(dKey, todayKey)) continue;
      final rawDev = r['device_id']?.toString() ?? '';
      final dev = rawDev.isEmpty ? fallbackDeviceId : rawDev;
      if (dev.isEmpty) continue;
      final cnt = (r['cnt'] as int?) ?? 0;
      final k = (deviceId: dev, dateKey: dKey);
      final prev = stats[k] ?? (featureCount: 0, detailCount: 0);
      stats[k] = (featureCount: prev.featureCount, detailCount: prev.detailCount + cnt);
    }
    return (stats: stats, fidsByBlock: fidsByBlock);
  }

  static Future<void> _copyGnssDayBlock({
    required GeoPackageFile from,
    required GeoPackageFile to,
    required String deviceId,
    required String dateKey,
    required String fromFallbackDeviceId,
    required List<int> fromFids,
    required List<int> toFids,
  }) async {
    for (final fid in toFids) {
      await to.removeFeature(gnssTracksLayerName, fid);
    }
    final toDb = await to.getDatabase();
    for (final fid in fromFids) {
      final detail = await from.getFeature(gnssTracksLayerName, fid);
      if (detail == null) continue;
      final coords = _lineCoords(detail[featureGeometryKey]);
      if (coords.length < 2) continue;
      final name = detail['name']?.toString() ?? dateKey;
      final desc = detail['description']?.toString() ?? '';
      final gnssDev = detail['gnss_device']?.toString() ?? desc;
      final newFid = await to.addLine(
        gnssTracksLayerName,
        coords,
        name: name,
        description: desc,
      );
      if (newFid != null) {
        await toDb.update(
          gnssTracksLayerName,
          {'device_id': deviceId, 'gnss_device': gnssDev},
          where: 'fid = ?',
          whereArgs: [newFid],
        );
      }
    }

    final fromDb = await from.getDatabase();
    final detailRows = await fromDb.query(
      gnssDetailsTableName,
      where:
          'track_date = ? AND (device_id = ? OR (? = ? AND (device_id IS NULL OR device_id = \'\')))',
      whereArgs: [dateKey, deviceId, deviceId, fromFallbackDeviceId],
      orderBy: 'point_index ASC',
    );
    await toDb.transaction((txn) async {
      await txn.delete(
        gnssDetailsTableName,
        where: 'track_date = ? AND device_id = ?',
        whereArgs: [dateKey, deviceId],
      );
      final batch = txn.batch();
      for (final row in detailRows) {
        batch.insert(gnssDetailsTableName, {
          'track_date': dateKey,
          'point_index': row['point_index'],
          'timestamp': row['timestamp'],
          'latitude': row['latitude'],
          'longitude': row['longitude'],
          'altitude': row['altitude'],
          'accuracy': row['accuracy'],
          'accuracy_source': row['accuracy_source'],
          'speed': row['speed'],
          'bearing': row['bearing'],
          'gps_quality': row['gps_quality'],
          'fix_type': row['fix_type'],
          'correction_source': row['correction_source'],
          'satellite_count': row['satellite_count'],
          'hdop': row['hdop'],
          'pdop': row['pdop'],
          'vdop': row['vdop'],
          'gnss_device': row['gnss_device'],
          'ntrip_mountpoint': row['ntrip_mountpoint'],
          'raw_gga': row['raw_gga'],
          'source_type': row['source_type'] ?? 'GNSS',
          'device_id': deviceId,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<bool> _copyMissingPastConnectionEvents({
    required GeoPackageFile from,
    required GeoPackageFile to,
    required String todayIsoPrefix,
    required String fallbackDeviceId,
  }) async {
    final fromDb = await from.getDatabase();
    final toDb = await to.getDatabase();
    final srcRows = await fromDb.query(
      connectionEventsTableName,
      where: 'substr(timestamp, 1, 10) < ?',
      whereArgs: [todayIsoPrefix],
      orderBy: 'timestamp ASC',
    );
    if (srcRows.isEmpty) return false;

    final dstRows = await toDb.query(
      connectionEventsTableName,
      where: 'substr(timestamp, 1, 10) < ?',
      whereArgs: [todayIsoPrefix],
    );
    String sig(Map<String, Object?> r, String fb) {
      final rawDev = r['device_id']?.toString() ?? '';
      final dev = rawDev.isEmpty ? fb : rawDev;
      return '$dev|${r['timestamp']}|${r['category']}|${r['event_type']}|${r['device_name']}';
    }

    final existing = {for (final r in dstRows) sig(r, '')};
    final toInsert = <Map<String, Object?>>[];
    for (final r in srcRows) {
      final rawDev = r['device_id']?.toString() ?? '';
      final dev = rawDev.isEmpty ? fallbackDeviceId : rawDev;
      final key = '$dev|${r['timestamp']}|${r['category']}|${r['event_type']}|${r['device_name']}';
      if (existing.add(key)) {
        toInsert.add({
          'timestamp': r['timestamp'],
          'category': r['category'],
          'event_type': r['event_type'],
          'device_name': r['device_name'],
          'device_address': r['device_address'],
          'detail': r['detail'],
          'device_id': dev,
        });
      }
    }
    if (toInsert.isEmpty) return false;

    await toDb.transaction((txn) async {
      final batch = txn.batch();
      for (final row in toInsert) {
        batch.insert(connectionEventsTableName, row);
      }
      await batch.commit(noResult: true);
    });
    return true;
  }

  void _onDeviceConnectionEvent(DeviceConnectionEvent ev) {
    if (!_isInitialized || _historyFile == null) return;
    final write = _insertConnectionEvent(ev);
    _writing.add(write);
    write.whenComplete(() => _writing.remove(write));
  }

  Future<void> _insertConnectionEvent(DeviceConnectionEvent ev) async {
    final file = _historyFile;
    if (file == null) return;
    try {
      final db = await file.getDatabase();
      await db.insert(connectionEventsTableName, {
        'timestamp': ev.timestamp.toIso8601String(),
        'category': ev.category.name,
        'event_type': ev.type.name,
        'device_name': ev.deviceName,
        'device_address': ev.deviceAddress,
        'detail': ev.detail,
        'device_id': _deviceId,
      });
    } catch (e) {
      AppLogger.debug('$_logTag: 接続イベントのGPKG書き込みエラー: $e');
    }
  }
}
