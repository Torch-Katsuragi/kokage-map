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
/// ホーム画面の権限確認とグローバルフォルダ初期化ヘルパー
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/global_folder_node.dart';
import '../../models/nodes/sys_node.dart';
import '../../providers/notification_providers.dart';
import '../../providers/project_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/global_folder_locator.dart';
import '../../services/projects_home.dart';
import '../../utils/folder_utils.dart';
import '../settings_screen.dart' show kGlobalFolderCustomPathKey;

/// ストレージ・位置情報権限の確認とリクエストを担う
class HomePermissionChecker {
  bool isChecking = false;

  /// 権限を確認・リクエストする。許可されたら [onGranted]、恒久拒否時は [onDenied] を呼ぶ。
  Future<void> checkPermissions({
    required VoidCallback onGranted,
    required VoidCallback onDenied,
  }) async {
    if (!PlatformCapabilities.needsRuntimePermissions) {
      onGranted();
      return;
    }

    // 既に権限チェック中の場合はスキップ
    if (isChecking) {
      AppLogger.debug('[HomeScreen] 権限チェックが既に実行中のため、スキップします');
      return;
    }

    isChecking = true;
    AppLogger.debug('[HomeScreen] 権限チェック開始');

    try {
      // Android 11 (API level 30) 以降での権限管理
      final manageStorageGranted = await Permission.manageExternalStorage.isGranted;
      AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限状態: $manageStorageGranted');

      if (manageStorageGranted) {
        AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が既に許可済み');
        // ストレージ権限OK後、位置情報→Bluetooth権限をチェック
        await _checkLocationPermission(onGranted: onGranted);
        return;
      }

      AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限をリクエスト中...');
      final status = await Permission.manageExternalStorage.request();
      AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限リクエスト結果: $status');

      if (status.isGranted) {
        AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が許可されました');
        await _checkLocationPermission(onGranted: onGranted);
      } else if (status.isPermanentlyDenied) {
        AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が恒久的に拒否されました');
        onDenied();
      } else {
        AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が拒否されました。従来の権限を試行');
        await _requestLegacyStoragePermissions(onGranted: onGranted, onDenied: onDenied);
      }
    } catch (e) {
      AppLogger.debug('[HomeScreen] 権限チェック中にエラーが発生: $e');
    } finally {
      isChecking = false;
      AppLogger.debug('[HomeScreen] 権限チェック終了');
    }
  }

  /// 従来のストレージ権限をリクエスト
  Future<void> _requestLegacyStoragePermissions({
    required VoidCallback onGranted,
    required VoidCallback onDenied,
  }) async {
    AppLogger.debug('[HomeScreen] 従来のストレージ権限チェック開始');

    final permissions = [Permission.storage];

    AppLogger.debug('[HomeScreen] ストレージ権限をリクエスト中...');
    final statuses = await permissions.request();
    AppLogger.debug('[HomeScreen] ストレージ権限リクエスト結果: $statuses');

    if (statuses[Permission.storage]?.isGranted == true) {
      AppLogger.debug('[HomeScreen] ストレージ権限が許可されました');
      await _checkLocationPermission(onGranted: onGranted);
    } else {
      AppLogger.debug('[HomeScreen] ストレージ権限が拒否されました');
      onDenied();
    }
  }

  /// 位置情報権限の確認（ストレージ権限の後に実行）
  Future<void> _checkLocationPermission({required VoidCallback onGranted}) async {
    AppLogger.debug('[HomeScreen] 位置情報権限チェック開始');

    final locationGranted = await Permission.location.isGranted;
    AppLogger.debug('[HomeScreen] 位置情報権限状態: $locationGranted');

    if (!locationGranted) {
      AppLogger.debug('[HomeScreen] 位置情報権限をリクエスト中...');
      final status = await Permission.location.request();
      AppLogger.debug('[HomeScreen] 位置情報権限リクエスト結果: $status');

      if (!status.isGranted) {
        AppLogger.debug('[HomeScreen] 位置情報権限が拒否されました（GPS機能制限付きで続行）');
      }
    }

    // 位置情報権限の結果に関わらず先へ進む。
    // Bluetooth は起動時に求めない（外部機器を使うときだけ要る。オンボーディングで飛ばしたのに
    // ここで 2 回出ていた。2026-09-01）。求めるのは外部機器設定・GPS 設定の接続操作の直前
    onGranted();
  }
}

/// 権限拒否ダイアログを表示
void showPermissionDeniedDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.permissions.storageRequired),
      content: Text(t.permissions.storageRequiredDesc),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.cancel),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            openAppSettings();
          },
          child: Text(t.common.openSettings),
        ),
      ],
    ),
  );
}

/// グローバルフォルダの置き場所を決める（旧場所からの移行もここで走る）。web・失敗時は null
Future<GlobalFolderResolution?> resolveGlobalFolder() async {
  if (!PlatformCapabilities.hasLocalFileSystem) return null;
  try {
    final prefs = await SharedPreferences.getInstance();
    return await GlobalFolderLocator.resolve(customPath: prefs.getString(kGlobalFolderCustomPathKey));
  } catch (e) {
    AppLogger.debug('[HomeScreen] グローバルフォルダの置き場所を決められない: $e');
    return null;
  }
}

/// グローバルフォルダの初期化
/// SharedPreferencesにカスタムパスがあればそちらを使用、なければデフォルト
/// （Android の既定は共有ストレージ。場所決めと旧場所からの移行は
/// `GlobalFolderLocator` に集約）
///
/// [resolved] は [resolveGlobalFolder] で先に決めた結果（決められなかったら null で、ここでもう一度試す）
Future<void> initializeGlobalFolder(
  WidgetRef ref, {
  GlobalFolderResolution? resolved,
}) async {
  // ⚠ グローバルフォルダは「アプリのドキュメント領域」に置く仕組みで、
  // web にはその概念が無い（path_provider が未対応）。
  // web でプロジェクトを開いたときは黙って飛ばす。
  if (!PlatformCapabilities.hasLocalFileSystem) {
    AppLogger.debug('[HomeScreen] GlobalFolder: skipped (web)');
    return;
  }
  void notify(String title, NotificationLevel level, {String? detail}) {
    ref.read(notificationCenterProvider.notifier).add(title: title, detail: detail, level: level);
  }

  try {
    final resolution = resolved ?? await resolveGlobalFolder();
    if (resolution == null) return;
    final globalPath = resolution.path;

    // グローバルフォルダパスを保存
    ref.read(globalFolderPathProvider.notifier).set(globalPath);
    AppLogger.debug('[HomeScreen] グローバルフォルダパス: $globalPath');

    if (resolution.migrated) {
      notify(t.globalFolder.migrated(count: resolution.migratedFiles), NotificationLevel.info, detail: globalPath);
    }
    if (resolution.fellBack) {
      notify(t.globalFolder.fallback, NotificationLevel.warning, detail: resolution.fallbackReason);
    }

    // 含有関係チェック（プロジェクトフォルダとの重複警告）
    final projectDir = ref.read(projectRootDirProvider);
    final warning = projectDir == null ? null : checkContainmentRelation(globalPath, projectDir);
    if (warning != null) notify(warning, NotificationLevel.warning);

    // グローバルフォルダは「System」（sys）の下に置く。sys はルート直下の先頭
    // （[[docs/features/layer-management#System（sys）]]）
    final rootNode = ref.read(folderTreeProvider);
    if (rootNode != null) {
      final globalFolderNode = GlobalFolderNode(
        'Global',
        globalPath: globalPath,
        visible: true,
      );
      SysNode.attachGlobalFolder(rootNode, globalFolderNode);
      AppLogger.debug('[HomeScreen] グローバルフォルダを「System」の下に追加');
    }
  } catch (e) {
    AppLogger.debug('[HomeScreen] グローバルフォルダ初期化エラー: $e');
  }
}

/// 選択されたプロジェクトフォルダのルートツリーと GlobalFolder を初期化する
Future<void> bootstrapProjectIntoProviders(
  WidgetRef ref, {
  required String dir,
  required bool usesProjectsHome,
  required void Function(String status) onStatus,
}) async {
  onStatus(t.home.initializingProject);
  AppLogger.debug('[HomeScreen] フォルダ選択完了、初期化を開始');
  ref.read(projectRootDirProvider.notifier).set(dir);
  AppLogger.debug('[HomeScreen] projectRootDirProvider 設定完了');
  // Global の置き場所を先に決める（旧 Global を .kokage へ移し、移せなかった旧フォルダを地図に出さない印を付ける）。
  // 決めた結果は下の initializeGlobalFolder でそのまま使う（以前は二度決めていて、移した件数のお知らせが出なかった）
  final globalResolution = await resolveGlobalFolder();
  if (usesProjectsHome) unawaited(ProjectsHome.remember(dir));
  final rootNode = await FolderNode.createRootNode(dir);
  ref.read(folderTreeProvider.notifier).set(rootNode);
  AppLogger.debug('[HomeScreen] rootNode 設定完了 (${rootNode.runtimeType})');

  onStatus(t.home.preparingSharedFolder);
  await initializeGlobalFolder(ref, resolved: globalResolution);
  AppLogger.debug('[HomeScreen] GlobalFolder 初期化完了');
}
