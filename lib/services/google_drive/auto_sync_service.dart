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
// Root Maps: 自動同期サービス
// WiFi接続時にDrive連携フォルダを自動同期
// conflict時のみユーザーに通知（サブタイトル表示）

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../utils/app_logger.dart';
import '../projects_home.dart';
import 'appdata_sync_service.dart';
import 'google_drive_service.dart';
import 'sync_engine.dart';
import 'sync_snapshot.dart';

/// 自動同期の設定キー
const String kAutoSyncEnabledKey = 'auto_sync_enabled';

/// 自動同期の間隔（分）
const String kAutoSyncIntervalKey = 'auto_sync_interval_minutes';

/// デフォルト間隔（分）
const int kAutoSyncDefaultInterval = 5;

/// 自動同期サービス
///
/// WiFi接続時にDrive連携フォルダを定期チェック＆自動同期。
/// conflict時はノードのsyncStatusを更新するのみ（UIがサブタイトルで表示）。
class AutoSyncService {
  static final AutoSyncService instance = AutoSyncService._();
  AutoSyncService._();

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isWifi = false;
  bool _isSyncing = false;
  bool _enabled = false;

  /// ツリールートを外部から設定（MapPageで呼ぶ）
  LayerTreeNode? rootNode;

  /// UIリビルド用コールバック
  VoidCallback? onSyncStatusChanged;

  /// 同期完了後にツリーリフレッシュが必要な場合のコールバック
  Future<void> Function(DriveFolderNode node)? onTreeRefreshNeeded;

  /// 行単位で合わせられなかった版（`<dir>/<相対パス>` → そのときの Drive 側の modifiedTime）。
  /// 同じリモートの版で何度やっても合わせられない（列の増減など）ので、版が変わるまで試さない
  final Map<String, DateTime?> _failedMergeAt = {};

  /// 自動同期で行単位マージが走ったとき（合わせた数と、同じ行・同じ列の衝突）。
  /// 自動同期は画面を出さないので、ここで通知しないと衝突が誰にも見えない
  void Function(DriveFolderNode node, SyncResult result)? onMerged;

  bool get isEnabled => _enabled;

  /// 初期化＆開始
  Future<void> start({
    required LayerTreeNode root,
    VoidCallback? onStatusChanged,
    Future<void> Function(DriveFolderNode)? onRefreshNeeded,
    void Function(DriveFolderNode node, SyncResult result)? onMerged,
  }) async {
    rootNode = root;
    onSyncStatusChanged = onStatusChanged;
    onTreeRefreshNeeded = onRefreshNeeded;
    this.onMerged = onMerged;

    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(kAutoSyncEnabledKey) ?? true;

    if (!_enabled) {
      AppLogger.debug('[AutoSync] Disabled by settings');
      return;
    }

    _listenConnectivity();
    AppLogger.debug('[AutoSync] Started');
  }

  /// 設定変更時に呼ぶ
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAutoSyncEnabledKey, enabled);

    if (enabled) {
      _listenConnectivity();
    } else {
      stop();
    }
  }

  /// 停止
  void stop() {
    _timer?.cancel();
    _timer = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    AppLogger.debug('[AutoSync] Stopped');
  }

  /// 止めて、[start] で受け取った木と呼び戻しも手放す（地図の画面を閉じたとき）。
  /// 呼び戻しは閉じた画面の State を抱えているので、残すと次に地図を開くまで画面ごと残る。
  /// 設定で止めるだけ（[setEnabled]）のときは使わない（入れ直したらそのまま同期を再開する）
  void detach() {
    stop();
    rootNode = null;
    onSyncStatusChanged = null;
    onTreeRefreshNeeded = null;
    onMerged = null;
  }

  /// 接続状態の監視
  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged);

    // 初回チェック
    Connectivity().checkConnectivity().then(_onConnectivityChanged);
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final wasWifi = _isWifi;
    _isWifi = results.contains(ConnectivityResult.wifi);

    if (_isWifi && !wasWifi) {
      AppLogger.debug('[AutoSync] WiFi connected, starting periodic sync');
      _startTimer();
      // WiFi接続直後に1回実行
      _runAutoSync();
    } else if (!_isWifi && wasWifi) {
      AppLogger.debug('[AutoSync] WiFi lost, pausing auto-sync');
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer() async {
    _timer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    final minutes = prefs.getInt(kAutoSyncIntervalKey) ?? kAutoSyncDefaultInterval;
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => _runAutoSync());
  }

  /// メイン同期ロジック
  /// ???????????????????????????????
  Future<void> refreshSharedFolderTree() async {
    final root = rootNode;
    if (root == null) return;
    await root.updateChildren();
    for (final child in root.children) {
      if (child.name == ProjectsHome.sharedDirName) {
        await child.updateChildren();
      }
    }
    onSyncStatusChanged?.call();
  }

  Future<void> _runAutoSync() async {
    if (!_enabled || !_isWifi || _isSyncing) return;
    final root = rootNode;
    if (root == null) return;

    _isSyncing = true;
    AppLogger.debug('[AutoSync] Sync cycle starting...');

    try {
      // Drive認証確認
      final driveService = GoogleDriveService();
      if (!driveService.isDriveApiAvailable) {
        await driveService.initialize();
        if (!driveService.isDriveApiAvailable) {
          AppLogger.debug('[AutoSync] Not authenticated, skipping');
          return;
        }
      }
      await driveService.refreshToken();

      // 端末間データ統合（AppData/kmap: 設定・共有リスト・前日以前のGPS履歴）
      try {
        await AppDataSyncService.instance.syncIfEnabled(
          onSharedFoldersChanged: refreshSharedFolderTree,
        );
      } catch (e) {
        AppLogger.debug('[AutoSync] AppData sync error: $e');
      }

      final folders = _collectDriveFolders(root);
      if (folders.isEmpty) return;

      AppLogger.debug('[AutoSync] Found ${folders.length} Drive folder(s)');
      final syncEngine = SyncEngine();

      for (final node in folders) {
        if (!_isWifi) {
          AppLogger.debug('[AutoSync] WiFi lost mid-sync, aborting');
          break;
        }
        await _syncFolder(syncEngine, node);
      }
    } catch (e) {
      AppLogger.debug('[AutoSync] Cycle error: $e');
    } finally {
      _isSyncing = false;
      AppLogger.debug('[AutoSync] Sync cycle finished');
    }
  }

  /// テスト用: 1 フォルダ分の自動同期
  @visibleForTesting
  Future<void> syncFolderForTest(SyncEngine engine, DriveFolderNode node) => _syncFolder(engine, node);

  /// 個別フォルダの同期
  Future<void> _syncFolder(SyncEngine engine, DriveFolderNode node) async {
    final localPath = node.getAbsoluteFilePath();
    if (localPath == null) return;

    try {
      final detail = await engine.checkSyncStatusDetail(localPath);

      switch (detail.status) {
        case FolderSyncStatus.synced:
          node.syncStatus = SyncStatus.synced;

        case FolderSyncStatus.localChanges:
          // ローカル削除を含む場合は自動pushしない（手動同期を要求）
          if (detail.localDeleted > 0) {
            node.syncStatus = SyncStatus.localChanges;
            AppLogger.debug(
              '[AutoSync] ${node.name}: local deletions detected, skipping auto-push (manual sync required)',
            );
            break;
          }
          node.syncStatus = SyncStatus.syncing;
          onSyncStatusChanged?.call();
          final result = await engine.pushFolder(localPath, snapshot: detail.snapshot);
          node.syncStatus = result.success
              ? SyncStatus.synced
              : SyncStatus.error;
          if (result.success) {
            AppLogger.debug(
              '[AutoSync] ${node.name}: pushed ${result.uploadedCount} file(s)',
            );
          } else {
            AppLogger.debug(
              '[AutoSync] ${node.name}: push failed - ${result.errorMessage}',
            );
          }

        case FolderSyncStatus.remoteChanges:
          node.syncStatus = SyncStatus.syncing;
          onSyncStatusChanged?.call();
          final result = await engine.pullFolder(localPath, snapshot: detail.snapshot);
          node.syncStatus = result.success
              ? SyncStatus.synced
              : SyncStatus.error;
          if (result.success) {
            AppLogger.debug(
              '[AutoSync] ${node.name}: pulled ${result.downloadedCount} file(s) '
              '(unchanged ${result.skippedCount})',
            );
            // 手元が何も変わらなければツリーを読み直さない（読み込み済みレイヤのフィーチャを全部読み直すので重い）
            if (result.changedLocal) await onTreeRefreshNeeded?.call(node);
          } else {
            AppLogger.debug(
              '[AutoSync] ${node.name}: pull failed - ${result.errorMessage}',
            );
          }

        case FolderSyncStatus.conflict:
          // ファイル単位でconflictを判定し、非conflictは自動マージ
          await _handleConflict(engine, node, localPath, detail.snapshot);

        case FolderSyncStatus.notLinked:
        case FolderSyncStatus.error:
          node.syncStatus = SyncStatus.error;
      }
    } catch (e) {
      AppLogger.debug('[AutoSync] ${node.name}: error - $e');
      node.syncStatus = SyncStatus.error;
    }

    onSyncStatusChanged?.call();
  }

  /// フォルダレベルconflict時のファイル単位マージ
  ///
  /// [relativePath] が `.qgs` で、同じ dir にまだ別の `.qgs`（付け替え後の名前）があるか
  static Future<bool> _isRenamedProjectFile(String localPath, String relativePath) async {
    if (!relativePath.toLowerCase().endsWith('.qgs')) return false;
    final dir = p.join(localPath, p.dirname(relativePath));
    try {
      return (await fs.list(dir)).any((e) => !e.isDirectory && e.path.toLowerCase().endsWith('.qgs'));
    } on Object {
      return false;
    }
  }

  /// 同一ファイルが両方で変更された場合のみユーザーに委ね、
  /// それ以外（ローカルAを変更＋リモートBを変更）は自動マージ。
  /// ローカル削除は自動pushしない（手動同期を要求）。
  Future<void> _handleConflict(
    SyncEngine engine,
    DriveFolderNode node,
    String localPath,
    SyncSnapshot? snapshot,
  ) async {
    // 判定に使った材料をそのまま使う（Drive をたどり直さない）。判定できなければ投げる（呼び元でエラーにする）
    final entries = await engine.getMergeEntries(localPath, snapshot: snapshot);
    if (entries.isEmpty) {
      node.syncStatus = SyncStatus.synced;
      return;
    }

    final autoDecisions = <MergeDecision>[];
    bool hasRealConflict = false;
    bool needsTreeRefresh = false;

    for (final entry in entries) {
      if (entry.isConflict) {
        final failedKey = '$localPath/${entry.relativePath}';
        if (entry.mergeable &&
            _failedMergeAt.containsKey(failedKey) &&
            _failedMergeAt[failedKey] == entry.remoteModifiedTime) {
          // この版は前に合わせられなかった → ユーザーに委ねる
          hasRealConflict = true;
          continue;
        }
        if (entry.mergeable) {
          // 同じ gpkg を両方で変更 → 行単位で合わせる（base があるときだけ）
          autoDecisions.add(MergeDecision(entry: entry, choice: MergeChoice.merge));
          needsTreeRefresh = true;
          continue;
        }
        // 同一ファイルが両方で変更 → ユーザーに委ねる
        hasRealConflict = true;
        continue;
      }
      // ローカル削除は自動pushしない。ただし `.qgs` の名前の付け替え（同じ dir にまだ `.qgs` がある）は、
      // 古い名前を Drive に残すと相手の端末に散らかるので消す
      if (entry.localChange == MergeChangeType.deleted && !await _isRenamedProjectFile(localPath, entry.relativePath)) continue;

      if (entry.localChange != MergeChangeType.none) {
        autoDecisions.add(MergeDecision(entry: entry, choice: MergeChoice.local));
      } else if (entry.remoteChange != MergeChangeType.none) {
        autoDecisions.add(MergeDecision(entry: entry, choice: MergeChoice.remote));
        needsTreeRefresh = true;
      }
    }

    // 自動マージ可能なエントリを実行
    if (autoDecisions.isNotEmpty) {
      node.syncStatus = SyncStatus.syncing;
      onSyncStatusChanged?.call();
      final result = await engine.executeMerge(localPath, autoDecisions, snapshot: snapshot);
      if (result.success) {
        AppLogger.debug(
          '[AutoSync] ${node.name}: auto-merged ${autoDecisions.length} file(s) '
          '(↑${result.uploadedCount} ↓${result.downloadedCount} ⇄${result.mergedCount})',
        );
        if (result.conflicts.isNotEmpty) {
          AppLogger.debug('[AutoSync] ${node.name}: 行の衝突 ${result.conflicts.length} 件（この端末の値を残した）: ${result.conflicts}');
        }
        if (result.mergedCount > 0 || result.failedMerges.isNotEmpty || result.failedUploads.isNotEmpty) {
          onMerged?.call(node, result);
        }
        // 置き場所が見つからず上げられなかったものは、次の周期でもう一度（状態は衝突として人の目に入れる）
        if (result.failedUploads.isNotEmpty) hasRealConflict = true;
        if (result.failedMerges.isNotEmpty) {
          hasRealConflict = true;
          for (final path in result.failedMerges) {
            final e = autoDecisions.map((d) => d.entry).firstWhere((x) => x.relativePath == path);
            _failedMergeAt['$localPath/$path'] = e.remoteModifiedTime;
          }
          AppLogger.debug('[AutoSync] ${node.name}: 行単位で合わせられなかった ${result.failedMerges}');
        }
        if (needsTreeRefresh && result.changedLocal) await onTreeRefreshNeeded?.call(node);
      } else {
        // 以前は失敗しても下で「同期済み」にしていた
        AppLogger.debug('[AutoSync] ${node.name}: auto-merge failed - ${result.errorMessage}');
        node.syncStatus = SyncStatus.error;
        return;
      }
    }

    // 真のconflictが残っているかで最終ステータスを決定
    node.syncStatus = hasRealConflict ? SyncStatus.conflict : SyncStatus.synced;
    if (hasRealConflict) {
      AppLogger.debug('[AutoSync] ${node.name}: file-level conflicts remain');
    }
  }

  /// ツリーからDriveFolderNodeを再帰収集
  List<DriveFolderNode> _collectDriveFolders(LayerTreeNode node) {
    final result = <DriveFolderNode>[];
    if (node is DriveFolderNode) result.add(node);
    for (final child in node.children) {
      result.addAll(_collectDriveFolders(child));
    }
    return result;
  }
}
