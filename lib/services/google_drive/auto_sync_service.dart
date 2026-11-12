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
import '../../models/nodes/drive_folder_set_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../utils/app_logger.dart';
import '../projects_home.dart';
import 'appdata_sync_service.dart';
import 'drive_folder_set_service.dart';
import 'drive_transfer_registry.dart';
import 'drive_tree_nodes.dart';
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
  StreamSubscription<DriveTransferCompletionEvent>? _transferCompletionSub;
  bool _isWifi = false;
  bool _isSyncing = false;
  bool _enabled = false;
  bool _pendingSyncAfterTransfer = false;

  /// ツリールートを外部から設定（MapPageで呼ぶ）
  LayerTreeNode? rootNode;

  /// UIリビルド用コールバック
  VoidCallback? onSyncStatusChanged;

  /// 同期完了後にツリーリフレッシュが必要な場合のコールバック
  Future<void> Function(DriveFolderNode node)? onTreeRefreshNeeded;

  /// フォルダセット構成更新後にフィーチャ読込・地図再描画が必要な場合のコールバック
  Future<void> Function(DriveFolderSetNode setNode)? onFolderSetRefreshNeeded;

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
    Future<void> Function(DriveFolderSetNode)? onFolderSetRefreshNeeded,
    void Function(DriveFolderNode node, SyncResult result)? onMerged,
  }) async {
    rootNode = root;
    onSyncStatusChanged = onStatusChanged;
    onTreeRefreshNeeded = onRefreshNeeded;
    this.onFolderSetRefreshNeeded = onFolderSetRefreshNeeded;
    this.onMerged = onMerged;

    unawaited(_transferCompletionSub?.cancel());
    _transferCompletionSub = DriveTransferRegistry.instance.onTransferCompleted
        .listen(_handleTransferCompleted);

    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(kAutoSyncEnabledKey) ?? true;

    if (!_enabled) {
      AppLogger.debug('[AutoSync] Disabled by settings');
      return;
    }

    _listenConnectivity();
    AppLogger.debug('[AutoSync] Started');
  }

  Future<void> _handleTransferCompleted(
    DriveTransferCompletionEvent event,
  ) async {
    try {
      if (!event.success) {
        onSyncStatusChanged?.call();
        return;
      }
      final currentRoot = rootNode;
      if (currentRoot == null) return;

      final existingFolders = DriveTreeNodes.findDriveFoldersByPath(
        currentRoot,
        event.localPath,
      );
      if (existingFolders.isNotEmpty) {
        for (final node in existingFolders) {
          node.syncStatus = SyncStatus.synced;
        }
        await onTreeRefreshNeeded?.call(existingFolders.first);
        onSyncStatusChanged?.call();
        return;
      }

      var existingSet = DriveTreeNodes.findFolderSetByPath(
        currentRoot,
        event.localPath,
      );
      if (existingSet != null) {
        existingSet.syncStatus = SyncStatus.synced;
        await DriveFolderSetService.reloadFolderSetNode(existingSet);
        await onFolderSetRefreshNeeded?.call(existingSet);
        onSyncStatusChanged?.call();
        return;
      }

      await refreshSharedFolderTree();
      existingSet = DriveTreeNodes.findFolderSetByPath(
        currentRoot,
        event.localPath,
      );
      if (existingSet != null) {
        existingSet.syncStatus = SyncStatus.synced;
        await DriveFolderSetService.reloadFolderSetNode(existingSet);
        await onFolderSetRefreshNeeded?.call(existingSet);
        onSyncStatusChanged?.call();
        return;
      }
      final added = DriveTreeNodes.findDriveFoldersByPath(
        currentRoot,
        event.localPath,
      );
      if (added.isNotEmpty) {
        for (final node in added) {
          node.syncStatus = SyncStatus.synced;
        }
        await onTreeRefreshNeeded?.call(added.first);
        onSyncStatusChanged?.call();
      }
    } finally {
      if (_pendingSyncAfterTransfer &&
          DriveTransferRegistry.instance.activeCount.value == 0) {
        _pendingSyncAfterTransfer = false;
        unawaited(_runAutoSync());
      }
    }
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
    _isWifi = false;
    _pendingSyncAfterTransfer = false;
    AppLogger.debug('[AutoSync] Stopped');
  }

  /// 止めて、[start] で受け取った木と呼び戻しも手放す（地図の画面を閉じたとき）。
  /// 呼び戻しは閉じた画面の State を抱えているので、残すと次に地図を開くまで画面ごと残る。
  /// 設定で止めるだけ（[setEnabled]）のときは使わない（入れ直したらそのまま同期を再開する）
  void detach() {
    stop();
    _transferCompletionSub?.cancel();
    _transferCompletionSub = null;
    rootNode = null;
    onSyncStatusChanged = null;
    onTreeRefreshNeeded = null;
    onFolderSetRefreshNeeded = null;
    onMerged = null;
  }

  /// 接続状態の監視
  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);

    // 初回チェック
    Connectivity().checkConnectivity().then(_onConnectivityChanged);
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final wasWifi = _isWifi;
    _isWifi = results.contains(ConnectivityResult.wifi);

    if (_isWifi && (!wasWifi || _timer == null)) {
      AppLogger.debug('[AutoSync] WiFi connected, starting periodic sync');
      _startTimer();
      // WiFi接続直後（および起動時）に1回実行
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
    final minutes =
        prefs.getInt(kAutoSyncIntervalKey) ?? kAutoSyncDefaultInterval;
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => _runAutoSync());
  }

  /// `共有/` フォルダのツリーを再読み込みする
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

  bool _deferIfForegroundTransferActive([String? reasonLog]) {
    if (DriveTransferRegistry.instance.activeCount.value <= 0) return false;
    if (reasonLog != null) AppLogger.debug(reasonLog);
    _pendingSyncAfterTransfer = true;
    return true;
  }

  /// Drive認証確認（起動直後は main.dart の無音復元がまだ完了していないことがあるため、
  /// initialize だけでなく restoreSessionSilently を待ってから判定する）
  Future<bool> _ensureSilentDriveAuth() async {
    final driveService = GoogleDriveService();
    if (!driveService.isDriveApiAvailable) {
      await driveService.restoreSessionSilently(userGesture: false);
      if (!driveService.isDriveApiAvailable) {
        AppLogger.debug('[AutoSync] Not authenticated, skipping');
        return false;
      }
    } else {
      await driveService.refreshToken();
    }
    return true;
  }

  Future<void> _runAutoSync() async {
    if (!_enabled || !_isWifi || _isSyncing) return;
    if (_deferIfForegroundTransferActive(
      '[AutoSync] Foreground transfer active, deferring cycle',
    )) {
      return;
    }
    final root = rootNode;
    if (root == null) return;

    _isSyncing = true;
    AppLogger.debug('[AutoSync] Sync cycle starting...');

    try {
      if (!await _ensureSilentDriveAuth()) return;
      if (_deferIfForegroundTransferActive()) return;

      // 端末間データ統合（AppData/kmap: 設定・共有リスト・前日以前のGPS履歴）
      try {
        await AppDataSyncService.instance.syncIfEnabled(
          onSharedFoldersChanged: refreshSharedFolderTree,
        );
      } catch (e) {
        AppLogger.debug('[AutoSync] AppData sync error: $e');
      }

      await _syncRootFolderSets(root);
      await _syncUniqueDriveFolders(root);
    } catch (e) {
      AppLogger.debug('[AutoSync] Cycle error: $e');
    } finally {
      _isSyncing = false;
      AppLogger.debug('[AutoSync] Sync cycle finished');
    }
  }

  Future<void> _syncRootFolderSets(LayerTreeNode root) async {
    // 子セット（親が DriveFolderSetNode のもの）は親セットの reconcileSet 内で再帰的に同期されるため、ルートセットのみ走査する
    final folderSets = DriveTreeNodes.collectFolderSets(root)
        .where((n) => n.parent is! DriveFolderSetNode);
    for (final setNode in folderSets) {
      if (!_isWifi) break;
      if (_deferIfForegroundTransferActive()) break;
      await _syncFolderSet(setNode);
    }
  }

  Future<void> _syncUniqueDriveFolders(LayerTreeNode root) async {
    final folders = DriveTreeNodes.collectDriveFolders(root);
    if (folders.isEmpty) return;

    // 同一実体パス（DirectPathResolver で複数セットから参照マウントされているフォルダ）を重複排除
    final nodesByNormPath = <String, List<DriveFolderNode>>{};
    for (final node in folders) {
      final localPath = node.getAbsoluteFilePath();
      if (localPath == null) continue;
      final key = DriveTransferRegistry.normalizeKey(localPath);
      nodesByNormPath.putIfAbsent(key, () => <DriveFolderNode>[]).add(node);
    }

    AppLogger.debug(
      '[AutoSync] Found ${nodesByNormPath.length} unique Drive folder(s) (${folders.length} node(s))',
    );
    final syncEngine = SyncEngine();

    for (final group in nodesByNormPath.values) {
      if (!_isWifi) {
        AppLogger.debug('[AutoSync] WiFi lost mid-sync, aborting');
        break;
      }
      if (_deferIfForegroundTransferActive(
        '[AutoSync] Foreground transfer started, deferring remaining',
      )) {
        break;
      }
      final primary = group.first;
      for (var i = 1; i < group.length; i++) {
        group[i].syncStatus = SyncStatus.syncing;
      }
      await _syncFolder(syncEngine, primary);
      for (var i = 1; i < group.length; i++) {
        group[i].syncStatus = primary.syncStatus;
      }
      onSyncStatusChanged?.call();
    }
  }

  /// テスト用: 1 フォルダ分の自動同期
  @visibleForTesting
  Future<void> syncFolderForTest(SyncEngine engine, DriveFolderNode node) =>
      _syncFolder(engine, node);

  /// 個別フォルダの同期
  Future<void> _syncFolder(SyncEngine engine, DriveFolderNode node) async {
    final localPath = node.getAbsoluteFilePath();
    if (localPath == null) return;

    // すでに手動・バックグラウンドクローン等で転送中のフォルダは二重実行しない
    if (DriveTransferRegistry.instance.isBusy(localPath)) {
      node.syncStatus = SyncStatus.syncing;
      onSyncStatusChanged?.call();
      return;
    }

    node.syncStatus = SyncStatus.syncing;
    onSyncStatusChanged?.call();

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
          final result = await engine.pushFolder(
            localPath,
            snapshot: detail.snapshot,
          );
          node.syncStatus =
              result.success ? SyncStatus.synced : SyncStatus.error;
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
          final result = await engine.pullFolder(
            localPath,
            snapshot: detail.snapshot,
          );
          node.syncStatus =
              result.success ? SyncStatus.synced : SyncStatus.error;
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

  /// [relativePath] が `.qgs` で、同じ dir にまだ別の `.qgs`（付け替え後の名前）があるか
  static Future<bool> _isRenamedProjectFile(
    String localPath,
    String relativePath,
  ) async {
    if (!relativePath.toLowerCase().endsWith('.qgs')) return false;
    final dir = p.join(localPath, p.dirname(relativePath));
    try {
      return (await fs.list(dir)).any(
        (e) => !e.isDirectory && e.path.toLowerCase().endsWith('.qgs'),
      );
    } on Object {
      return false;
    }
  }

  /// ファイル単位の差分一覧から自動マージ可能な [MergeDecision] と残存衝突有無を計画する
  @visibleForTesting
  static Future<({
    List<MergeDecision> decisions,
    bool hasRealConflict,
    bool needsTreeRefresh,
  })> planAutoMergeDecisions({
    required List<MergeFileEntry> entries,
    required String localPath,
    required Map<String, DateTime?> failedMergeAt,
    Future<bool> Function(String localPath, String relativePath)?
        isRenamedProjectFile,
  }) async {
    final checkRenamed = isRenamedProjectFile ?? _isRenamedProjectFile;
    final autoDecisions = <MergeDecision>[];
    var hasRealConflict = false;
    var needsTreeRefresh = false;

    for (final entry in entries) {
      if (entry.isConflict) {
        final failedKey = '$localPath/${entry.relativePath}';
        if (entry.mergeable &&
            failedMergeAt.containsKey(failedKey) &&
            failedMergeAt[failedKey] == entry.remoteModifiedTime) {
          // この版は前に合わせられなかった → ユーザーに委ねる
          hasRealConflict = true;
          continue;
        }
        if (entry.mergeable) {
          // 同じ gpkg を両方で変更 → 行単位で合わせる（base があるときだけ）
          autoDecisions
              .add(MergeDecision(entry: entry, choice: MergeChoice.merge));
          needsTreeRefresh = true;
          continue;
        }
        // 同一ファイルが両方で変更 → ユーザーに委ねる
        hasRealConflict = true;
        continue;
      }

      // ローカル削除は自動pushしない。ただし `.qgs` の名前の付け替え（同じ dir にまだ `.qgs` がある）は、
      // 古い名前を Drive に残すと相手の端末に散らかるので消す
      if (entry.localChange == MergeChangeType.deleted &&
          !await checkRenamed(localPath, entry.relativePath)) {
        continue;
      }

      if (entry.localChange != MergeChangeType.none) {
        autoDecisions
            .add(MergeDecision(entry: entry, choice: MergeChoice.local));
      } else if (entry.remoteChange != MergeChangeType.none) {
        autoDecisions
            .add(MergeDecision(entry: entry, choice: MergeChoice.remote));
        needsTreeRefresh = true;
      }
    }

    return (
      decisions: autoDecisions,
      hasRealConflict: hasRealConflict,
      needsTreeRefresh: needsTreeRefresh,
    );
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

    final plan = await planAutoMergeDecisions(
      entries: entries,
      localPath: localPath,
      failedMergeAt: _failedMergeAt,
    );
    var hasRealConflict = plan.hasRealConflict;

    // 自動マージ可能なエントリを実行
    if (plan.decisions.isNotEmpty) {
      node.syncStatus = SyncStatus.syncing;
      onSyncStatusChanged?.call();
      final result = await engine.executeMerge(
        localPath,
        plan.decisions,
        snapshot: snapshot,
      );
      if (result.success) {
        AppLogger.debug(
          '[AutoSync] ${node.name}: auto-merged ${plan.decisions.length} file(s) '
          '(↑${result.uploadedCount} ↓${result.downloadedCount} ⇄${result.mergedCount})',
        );
        if (result.conflicts.isNotEmpty) {
          AppLogger.debug(
            '[AutoSync] ${node.name}: 行の衝突 ${result.conflicts.length} 件（この端末の値を残した）: ${result.conflicts}',
          );
        }
        if (result.mergedCount > 0 ||
            result.failedMerges.isNotEmpty ||
            result.failedUploads.isNotEmpty) {
          onMerged?.call(node, result);
        }
        // 置き場所が見つからず上げられなかったものは、次の周期でもう一度（状態は衝突として人の目に入れる）
        if (result.failedUploads.isNotEmpty) hasRealConflict = true;
        if (result.failedMerges.isNotEmpty) {
          hasRealConflict = true;
          for (final path in result.failedMerges) {
            final e = plan.decisions
                .map((d) => d.entry)
                .firstWhere((x) => x.relativePath == path);
            _failedMergeAt['$localPath/$path'] = e.remoteModifiedTime;
          }
          AppLogger.debug(
            '[AutoSync] ${node.name}: 行単位で合わせられなかった ${result.failedMerges}',
          );
        }
        if (plan.needsTreeRefresh && result.changedLocal) {
          await onTreeRefreshNeeded?.call(node);
        }
      } else {
        // 以前は失敗しても下で「同期済み」にしていた
        AppLogger.debug(
          '[AutoSync] ${node.name}: auto-merge failed - ${result.errorMessage}',
        );
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

  /// 共有フォルダセット（JSON）の定期チェック＆差分同期
  Future<void> _syncFolderSet(DriveFolderSetNode setNode) async {
    final localPath = setNode.getAbsoluteFilePath();
    if (localPath == null) return;
    if (DriveTransferRegistry.instance.isBusy(localPath)) {
      setNode.syncStatus = SyncStatus.syncing;
      onSyncStatusChanged?.call();
      return;
    }
    setNode.syncStatus = SyncStatus.syncing;
    onSyncStatusChanged?.call();
    try {
      final result = await DriveFolderSetService().reconcileSet(
        localSetPath: localPath,
        manifestFileId: setNode.manifestFileId,
        setNode: setNode,
      );
      if (result.success) {
        setNode.syncStatus =
            result.failedItems.isEmpty ? SyncStatus.synced : SyncStatus.error;
        if (result.addedCount > 0 ||
            result.removedCount > 0 ||
            setNode.children.isEmpty) {
          await DriveFolderSetService.reloadFolderSetNode(setNode);
          await onFolderSetRefreshNeeded?.call(setNode);
        }
        onSyncStatusChanged?.call();
      } else {
        setNode.syncStatus = SyncStatus.error;
        onSyncStatusChanged?.call();
      }
    } catch (e) {
      AppLogger.debug('[AutoSync] FolderSet sync error (${setNode.name}): $e');
      setNode.syncStatus = SyncStatus.error;
      onSyncStatusChanged?.call();
    }
  }

  /// ローカルパスに対応するツリー内の [DriveFolderSetNode] を探す
  DriveFolderSetNode? findFolderSetByPath(String localPath) {
    final currentRoot = rootNode;
    if (currentRoot == null) return null;
    return DriveTreeNodes.findFolderSetByPath(currentRoot, localPath);
  }
}
