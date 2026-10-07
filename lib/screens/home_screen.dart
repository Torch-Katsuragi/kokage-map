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
// Root Maps: ホーム画面（プロジェクト作成・選択）
// プロジェクト新規作成・ローカル/DriveからインポートUI
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fs/k_file_system.dart';
import '../core/fs/project_folder_picker.dart';
import '../core/launch_options.dart';
import '../core/launch_request.dart';
import '../core/platform_capabilities.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/folder_node.dart';
import '../models/nodes/global_folder_node.dart';
import '../models/nodes/sys_node.dart';
import '../providers/notification_providers.dart';
import '../providers/project_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/changelog_service.dart';
import '../services/global_folder_locator.dart';
import '../services/google_drive/google_drive_service.dart';
import '../services/party/party_invite.dart';
import '../services/projects_home.dart';
import '../services/shared_map_link.dart';
import '../tutorial/practice_project.dart';
import '../tutorial/tutorial.dart';
import '../utils/folder_utils.dart';
import '../widgets/dialogs/drive_url_input_dialog.dart';
import 'changelog_screen.dart';
import 'home/folder_browser_screen.dart';
import 'home/project_launcher.dart';
import 'map_page/map_page.dart';
import 'onboarding_screen.dart';
import 'settings_screen.dart' show kGlobalFolderCustomPathKey;
import 'user_guide_screen.dart';

/// ホーム画面（最小構成）
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  String? _projectDir;
  bool _permissionsGranted = false;
  bool _isCheckingPermissions = false; // 権限チェック中フラグ
  bool _navigatedToMapPage = false; // マップ画面に遷移済みフラグ
  bool _isOpeningProject = false; // プロジェクト開始中フラグ

  /// 前回開いたフォルダの名前（web のみ。無ければ null）
  String? _lastFolderName;
  String _openingProjectStatus = '';
  bool _initCompleted = false; // 初期化（オンボーディング含む）完了フラグ
  bool _hasUnreadChangelog = false; // チェンジログ未読フラグ
  bool _autoOpenAttempted = false; // --dart-define=PROJECT_DIR の自動オープンを試したか

  /// 最後に開いたのが「ほかの場所」ならそのパス（native だけ。web は従来のフォルダ選択）
  String? _lastProject;
  bool get _usesProjectsHome => !kIsWeb && PlatformCapabilities.canOpenLocalProject;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LaunchRequest.incoming.addListener(_onLaunchRequest);
    LaunchRequest.sharedLinks.addListener(_onSharedLink);
    tutorialRequests.addListener(_onTutorialRequest);
    _initPermissions();
    _checkChangelogUnread();
    _loadLastFolderName();
  }

  /// 「続きから」を読み直す（権限が取れてから・地図から戻ったとき）。いつもの地図なら出さない
  Future<void> _loadProjects() async {
    if (!_usesProjectsHome || !_permissionsGranted) return;
    try {
      final last = await ProjectsHome.last();
      final other = last != null && !await ProjectsHome.isMyMap(last) ? last : null;
      if (!mounted) return;
      setState(() => _lastProject = other);
      _onSharedLink(); // 権限待ちで止めていた共有リンク
    } catch (e) {
      AppLogger.debug('[HomeScreen] 最後に開いたフォルダを読めない: $e');
    }
  }

  String? _lastSharedLink;
  DateTime _lastSharedLinkAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// QR の共有リンクが届いた（App Links）。地図を開いていればホームに戻ってから取り込む
  void _onSharedLink() {
    final link = LaunchRequest.sharedLinks.value;
    if (link == null || !_usesProjectsHome) return;
    if (!_permissionsGranted || _isOpeningProject) {
      // 権限が取れたら（_loadProjects の後で）もう一度見る
      return;
    }
    LaunchRequest.sharedLinks.value = null;
    // 起動中に届いたリンクと起動時のリンクが同じものを二度運んでくることがある
    final now = DateTime.now();
    if (link == _lastSharedLink && now.difference(_lastSharedLinkAt).inSeconds < 15) return;
    _lastSharedLink = link;
    _lastSharedLinkAt = now;
    final id = GoogleDriveService.extractFolderIdFromUrl(link);
    if (id == null) return;
    if (_navigatedToMapPage) Navigator.of(context).popUntil((r) => r.isFirst);
    unawaited(_receiveFromDrive(id));
  }

  /// Drive フォルダを、いつもの地図の 共有/ に取り込んで開く（QR のリンク）
  Future<void> _receiveFromDrive(String driveId) async {
    final notifier = ref.read(notificationCenterProvider.notifier);
    setState(() {
      _isOpeningProject = true;
      _openingProjectStatus = t.home.receivingShared;
    });
    try {
      final drive = GoogleDriveService();
      // 起動直後は無音の復元が終わっていないことがある。先に無音で試し、だめなときだけサインインを出す
      if (!drive.authState.isAuthenticated) await drive.restoreSessionSilently();
      if (!drive.authState.isAuthenticated && !await drive.signIn()) {
        notifier.add(title: drive.authState.errorMessage ?? t.home.receiveNeedsSignIn, level: NotificationLevel.warning);
        return;
      }
      final info = await drive.getFolderInfo(driveId);
      if (info == null) {
        notifier.add(title: t.home.receiveFailed, level: NotificationLevel.error);
        return;
      }
      final root = await receiveSharedMap(
        driveId: driveId,
        folderName: info.name ?? driveId,
        driveUrl: 'https://drive.google.com/drive/folders/$driveId',
        isReadOnly: !(info.capabilities?.canEdit ?? false),
      );
      if (!mounted) return;
      setState(() => _isOpeningProject = false);
      await _openProjectDir(root);
      return;
    } catch (e) {
      AppLogger.debug('[HomeScreen] 共有の地図を取り込めない: $e');
      notifier.add(title: t.home.receiveFailed, level: NotificationLevel.error);
    } finally {
      if (mounted && !_navigatedToMapPage) {
        setState(() {
          _isOpeningProject = false;
          _openingProjectStatus = '';
        });
      }
    }
  }

  /// ホームの「QR で受け取る」: アプリのカメラで読む（Drive の URL を貼っても読める）
  Future<void> _receiveFromDialog() async {
    final result = await DriveUrlInputDialog.show(context);
    if (result == null || !mounted) return;
    setState(() {
      _isOpeningProject = true;
      _openingProjectStatus = t.home.receivingShared;
    });
    try {
      final root = await receiveSharedMap(
        driveId: result.folderId,
        folderName: result.folderName,
        driveUrl: result.url,
        isReadOnly: result.isReadOnly,
      );
      if (!mounted) return;
      setState(() => _isOpeningProject = false);
      await _openProjectDir(root);
    } catch (e) {
      AppLogger.debug('[HomeScreen] 共有の地図を取り込めない: $e');
      ref.read(notificationCenterProvider.notifier).add(title: t.home.receiveFailed, level: NotificationLevel.error);
      if (mounted) setState(() => _isOpeningProject = false);
    }
  }

  /// いつもの地図（Documents/KokageMap）を開く
  Future<void> _openMyMap() async {
    if (_isOpeningProject) return;
    final dir = await ProjectsHome.myMap();
    await _openProjectDir(dir);
  }

  /// 前回のフォルダ名を読む（ボタンを出すかの判断だけ。権限は要求しない）
  Future<void> _loadLastFolderName() async {
    final name = await lastProjectFolderName();
    if (!mounted || name == null) return;
    setState(() => _lastFolderName = name);
  }

  /// 前回のフォルダを開き直す
  ///
  /// ⚠ **ボタンのハンドラから直接呼ぶこと。** web ではブラウザの再許可プロンプトが
  /// 要り、それはユーザー操作起点でしか出せない。
  Future<void> _reopenLastProjectDir() async {
    final dir = await reopenLastProjectFolder();
    if (!mounted) return;
    if (dir == null) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(
            title: t.home.reopenLastFolderFailed,
            level: NotificationLevel.warning,
          );
      setState(() => _lastFolderName = null);
      return;
    }
    await _openProjectDir(dir);
  }

  /// チェンジログの未読状態を確認
  Future<void> _checkChangelogUnread() async {
    final unread = await ChangelogService.instance.hasUnread();
    if (mounted) {
      setState(() => _hasUnreadChangelog = unread);
    }
  }

  /// チェンジログ画面を開く
  void _openChangelog() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => ChangelogScreen(
              onRead: () {
                if (mounted) {
                  setState(() => _hasUnreadChangelog = false);
                }
              },
            ),
      ),
    );
  }

  /// オンボーディング確認 → 権限チェック
  Future<void> _initPermissions() async {
    // オンボーディングが必要か判定
    final needsOnboarding = await OnboardingScreen.shouldShow();
    if (needsOnboarding && mounted) {
      // オンボーディング画面を表示
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (context) => const OnboardingScreen(),
          fullscreenDialog: true,
        ),
      );
    }
    // オンボーディング完了後（または不要の場合）、通常の権限チェックを実行
    _initCompleted = true;
    await _checkPermissions();
    await _maybeAutoOpenProjectDir();
    _maybeOpenPartyInvite();
    // はじめての人にだけ一度聞く（あとからはホームと設定から）
    if (needsOnboarding) await _offerTutorial();
  }

  /// チュートリアルを使えるか（練習プロジェクトを実際のフォルダに作る。web は未対応）
  // web は練習用フォルダをブラウザのサイト専用領域（OPFS）に作るので、フォルダを選べなくても始められる
  bool get _canTutorial => kIsWeb || (fs.hasRealPaths && PlatformCapabilities.canOpenLocalProject);

  Future<void> _offerTutorial() async {
    if (!mounted || !_canTutorial || !_permissionsGranted || _navigatedToMapPage) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.tutorial.offerTitle),
        content: Text(t.tutorial.offerBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.tutorial.later)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.tutorial.start)),
        ],
      ),
    );
    if (yes == true) await _startTutorial();
  }

  /// 設定から頼まれた。地図の上からなら、地図が閉じてから始める
  bool _tutorialPending = false;
  void _onTutorialRequest() {
    if (_navigatedToMapPage) {
      _tutorialPending = true;
    } else {
      unawaited(_startTutorial());
    }
  }

  /// 練習プロジェクトを作り直して開き、案内を始める
  Future<void> _startTutorial() async {
    if (!mounted || !_canTutorial || _isOpeningProject || _navigatedToMapPage) return;
    if (!_permissionsGranted) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.permissions.storageNotGranted,
            level: NotificationLevel.error,
          );
      return;
    }
    setState(() {
      _isOpeningProject = true;
      _openingProjectStatus = t.tutorial.preparing;
    });
    final PracticeProject proj;
    try {
      proj = await PracticeProject.recreate();
    } catch (e) {
      AppLogger.debug('[HomeScreen] 練習プロジェクトを作れない: $e');
      if (!mounted) return;
      setState(() => _isOpeningProject = false);
      ref.read(notificationCenterProvider.notifier).add(
            title: t.tutorial.failed,
            level: NotificationLevel.error,
          );
      return;
    }
    // 地図は自分のいる場所（GPS）から始める。練習のデータへは「データの仕組み」でダブルタップして飛ぶ（MapPage 側）
    ref.read(expandedGeoPackagesProvider.notifier).addExpanded(proj.gpkgPath);
    ref.read(tutorialProvider.notifier).start();
    await _openProjectDir(proj.dir);
  }

  /// 招待URL（web の `?room=CODE`）で開かれたら、フォルダ選択を挟まず
  /// 地図画面へ直行する（参加ダイアログは MapPage 側がコード充填済みで開く）。
  ///
  /// 「ルーム参加がURLで済む」= web版の主力機能。ゲストはプロジェクトを
  /// 持っていない前提なので、プロジェクト無しの地図で十分。
  void _maybeOpenPartyInvite() {
    if (!hasPendingRoomCode()) return;
    if (_navigatedToMapPage) return;
    AppLogger.debug('[HomeScreen] 招待URLを検出、地図画面へ直行');
    _openMapWithoutProject();
  }

  /// フォルダ選択を挟まずに開く。指示は 2 通り:
  /// - `--dart-define=PROJECT_DIR=...`（開発・デバッグ用）
  /// - 起動ルート `/map?project=<絶対パス>`（CLI・AI から。`LaunchRequest`）
  ///
  /// 指定が無い／パスが存在しない／権限が無い場合は何もしない（通常の選択画面のまま）。
  Future<void> _maybeAutoOpenProjectDir() async {
    if (_autoOpenAttempted) return;
    _autoOpenAttempted = true;

    final requested = LaunchRequest.pending?.project;
    final dir = LaunchOptions.hasProjectDir ? LaunchOptions.projectDir : requested;
    if (dir == null) return;
    await _openRequestedProject(dir);
  }

  Future<void> _openRequestedProject(String dir) async {
    if (!_permissionsGranted) {
      AppLogger.debug('[HomeScreen] 自動オープン: 権限が無いため見送り ($dir)');
      return;
    }
    // native は絶対パス、web は OPFS（`opfs:<名前>`）
    final opened = await openRequestedProjectFolder(dir);
    if (opened == null) {
      AppLogger.debug('[HomeScreen] 自動オープン: 開けない ($dir)');
      return;
    }
    AppLogger.debug('[HomeScreen] 自動オープン ($dir)');
    await _openProjectDir(opened);
  }

  /// 起動中に `/map?project=...` が届いた（ホームにいる間だけ受ける。地図にいる間は MapPage が受ける）
  void _onLaunchRequest() {
    final req = LaunchRequest.incoming.value;
    if (req?.project == null || _navigatedToMapPage || _isOpeningProject) return;
    if (req!.hasCamera) LaunchRequest.defer(req); // カメラは次に組まれる MapPage が拾う
    _openRequestedProject(req.project!);
  }

  @override
  void dispose() {
    LaunchRequest.incoming.removeListener(_onLaunchRequest);
    LaunchRequest.sharedLinks.removeListener(_onSharedLink);
    tutorialRequests.removeListener(_onTutorialRequest);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // アプリがフォアグラウンドに戻ったときに権限を再確認
      // ただし、初期化未完了・権限チェック中・マップ画面遷移済みの場合はスキップ
      if (_initCompleted && !_isCheckingPermissions && !_navigatedToMapPage) {
        _checkPermissions();
      }
    }
  }

  /// ストレージ権限の確認・リクエスト
  Future<void> _checkPermissions() async {
    if (!PlatformCapabilities.needsRuntimePermissions) {
      if (mounted) {
        setState(() {
          _permissionsGranted = true;
        });
        unawaited(_loadProjects());
      }
      return;
    }

    // 既に権限チェック中の場合はスキップ
    if (_isCheckingPermissions) {
      AppLogger.debug('[HomeScreen] 権限チェックが既に実行中のため、スキップします');
      return;
    }

    _isCheckingPermissions = true; // フラグをセット
    AppLogger.debug('[HomeScreen] 権限チェック開始');

    try {
      // Android 11 (API level 30) 以降での権限管理
      final manageStorageGranted =
          await Permission.manageExternalStorage.isGranted;
      AppLogger.debug(
        '[HomeScreen] MANAGE_EXTERNAL_STORAGE権限状態: $manageStorageGranted',
      );

      if (manageStorageGranted) {
        AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が既に許可済み');
        // ストレージ権限OK後、位置情報→Bluetooth権限をチェック
        await _checkLocationPermission();
        return;
      }

      AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限をリクエスト中...');
      // MANAGE_EXTERNAL_STORAGE権限をリクエスト
      final status = await Permission.manageExternalStorage.request();
      AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限リクエスト結果: $status');

      if (status.isGranted) {
        AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が許可されました');
        // ストレージ権限OK後、位置情報→Bluetooth権限をチェック
        await _checkLocationPermission();
      } else if (status.isPermanentlyDenied) {
        AppLogger.debug('[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が恒久的に拒否されました');
        // 権限が恒久的に拒否された場合、設定画面を開く
        _showPermissionDeniedDialog();
      } else {
        AppLogger.debug(
          '[HomeScreen] MANAGE_EXTERNAL_STORAGE権限が拒否されました。従来の権限を試行',
        );
        // 従来のストレージ権限を試行
        await _requestLegacyStoragePermissions();
      }
    } catch (e) {
      AppLogger.debug('[HomeScreen] 権限チェック中にエラーが発生: $e');
    } finally {
      _isCheckingPermissions = false; // フラグをクリア
      AppLogger.debug('[HomeScreen] 権限チェック終了');
    }
  }

  /// 従来のストレージ権限をリクエスト
  Future<void> _requestLegacyStoragePermissions() async {
    AppLogger.debug('[HomeScreen] 従来のストレージ権限チェック開始');

    final permissions = [Permission.storage];

    AppLogger.debug('[HomeScreen] ストレージ権限をリクエスト中...');
    final statuses = await permissions.request();
    AppLogger.debug('[HomeScreen] ストレージ権限リクエスト結果: $statuses');

    if (statuses[Permission.storage]?.isGranted == true) {
      AppLogger.debug('[HomeScreen] ストレージ権限が許可されました');
      // ストレージ権限OK後、位置情報→Bluetooth権限をチェック
      await _checkLocationPermission();
    } else {
      AppLogger.debug('[HomeScreen] ストレージ権限が拒否されました');
      _showPermissionDeniedDialog();
    }
  }

  /// 位置情報権限の確認（ストレージ権限の後に実行）
  Future<void> _checkLocationPermission() async {
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

    // 位置情報権限の結果に関わらず、Bluetooth権限の状態確認へ進む
    await _checkBluetoothPermissions();
  }

  /// Bluetooth権限の状態確認（起動時はリクエストしない）
  ///
  /// Bluetoothは外部機器（GNSS受信機・レーザー距離計）を使うときだけ必要なので、
  /// 起動時に「付近のデバイス」のシステムプロンプトを出さない。
  /// オンボーディングでスキップしたのにここで2回出ていた（2026-09-01 修正）。
  /// 実際のリクエストは外部機器設定画面・GPS設定画面が接続操作の直前に行う。
  Future<void> _checkBluetoothPermissions() async {
    final bluetoothScan = await Permission.bluetoothScan.status;
    final bluetoothConnect = await Permission.bluetoothConnect.status;

    AppLogger.debug(
      '[HomeScreen] Bluetooth権限状態: SCAN=$bluetoothScan, CONNECT=$bluetoothConnect'
      '（起動時はリクエストしない）',
    );

    if (!mounted) return;
    setState(() {
      _permissionsGranted = true;
    });
    unawaited(_loadProjects());
  }

  /// 権限拒否ダイアログを表示
  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
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
  Future<GlobalFolderResolution?> _resolveGlobalFolder() async {
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
  /// [resolved] は [_resolveGlobalFolder] で先に決めた結果（決められなかったら null で、ここでもう一度試す）
  Future<void> _initializeGlobalFolder(GlobalFolderResolution? resolved) async {
    // ⚠ グローバルフォルダは「アプリのドキュメント領域」に置く仕組みで、
    // web にはその概念が無い（path_provider が未対応）。
    // web でプロジェクトを開いたときは黙って飛ばす。
    if (!PlatformCapabilities.hasLocalFileSystem) {
      AppLogger.debug('[HomeScreen] GlobalFolder: skipped (web)');
      return;
    }
    try {
      final resolution = resolved ?? await _resolveGlobalFolder();
      if (resolution == null) return;
      final globalPath = resolution.path;

      // グローバルフォルダパスを保存
      ref.read(globalFolderPathProvider.notifier).set(globalPath);
      AppLogger.debug('[HomeScreen] グローバルフォルダパス: $globalPath');

      final notifier = ref.read(notificationCenterProvider.notifier);
      if (resolution.migrated) {
        notifier.add(
          title: t.globalFolder.migrated(count: resolution.migratedFiles),
          detail: globalPath,
          level: NotificationLevel.info,
        );
      }
      if (resolution.fellBack) {
        notifier.add(
          title: t.globalFolder.fallback,
          detail: resolution.fallbackReason,
          level: NotificationLevel.warning,
        );
      }

      // 含有関係チェック（プロジェクトフォルダとの重複警告）
      final projectDir = ref.read(projectRootDirProvider);
      if (projectDir != null) {
        final warning = checkContainmentRelation(globalPath, projectDir);
        if (warning != null) {
          ref
              .read(notificationCenterProvider.notifier)
              .add(title: warning, level: NotificationLevel.warning);
        }
      }

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

  Future<void> _pickProjectDir() async {
    AppLogger.debug('[HomeScreen] プロジェクトフォルダ選択開始');
    AppLogger.debug('[HomeScreen] 権限状態: $_permissionsGranted');

    if (!_permissionsGranted) {
      AppLogger.debug('[HomeScreen] 権限が許可されていません');
      ref
          .read(notificationCenterProvider.notifier)
          .add(
            title: t.permissions.storageNotGranted,
            level: NotificationLevel.error,
          );
      return;
    }

    AppLogger.debug('[HomeScreen] ファイルピッカーを開いています...');
    // native はいつもの地図の中をたどるアプリ内の画面（外は画面のメニューから OS のピッカー）、web は File System Access API
    final String? dir = PlatformCapabilities.hasLocalFileSystem
        ? await FolderBrowserScreen.show(context)
        : await pickProjectFolder();
    AppLogger.debug('[HomeScreen] 選択されたディレクトリ: $dir');

    if (dir != null) {
      await _openProjectDir(dir);
    }
  }

  /// プロジェクトフォルダを開いて地図画面へ遷移する
  ///
  /// フォルダの出所（ピッカー / `--dart-define=PROJECT_DIR`）に依らず同じ経路を通す。
  Future<void> _openProjectDir(String dir) async {
    if (!mounted) return;
    setState(() {
      _projectDir = dir;
      _isOpeningProject = true;
      _openingProjectStatus = t.home.initializingProject;
    });
    AppLogger.debug('[HomeScreen] フォルダ選択完了、初期化を開始');
    ref.read(projectRootDirProvider.notifier).set(dir);
    AppLogger.debug('[HomeScreen] projectRootDirProvider 設定完了');
    // Global の置き場所を先に決める（旧 Global を .kokage へ移し、移せなかった旧フォルダを地図に出さない印を付ける）。
    // 決めた結果は下の _initializeGlobalFolder でそのまま使う（以前は二度決めていて、移した件数のお知らせが出なかった）
    final globalResolution = await _resolveGlobalFolder();
    if (_usesProjectsHome) unawaited(ProjectsHome.remember(dir));
    final rootNode = await FolderNode.createRootNode(dir);
    ref.read(folderTreeProvider.notifier).set(rootNode);
    AppLogger.debug('[HomeScreen] rootNode 設定完了 (${rootNode.runtimeType})');

    setState(() {
      _openingProjectStatus = t.home.preparingSharedFolder;
    });
    await _initializeGlobalFolder(globalResolution);
    AppLogger.debug('[HomeScreen] GlobalFolder 初期化完了');

    // フォルダ選択後すぐ地図編集画面へ遷移
    if (mounted) {
      AppLogger.debug('[HomeScreen] 地図画面に遷移中...');
      // マップ画面遷移後は権限チェックを無効化（GPS権限リクエストとの競合防止）
      _navigatedToMapPage = true;
      unawaited(Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RootMapsHomePage()),
      ).then((_) {
        if (!mounted) return;
        ref.read(tutorialProvider.notifier).stop(); // 地図を閉じたら案内も終わり
        setState(() {
          _navigatedToMapPage = false;
          _isOpeningProject = false;
          _openingProjectStatus = '';
        });
        unawaited(_loadProjects());
        if (_tutorialPending) {
          _tutorialPending = false;
          unawaited(_startTutorial());
        }
      }));
    }
  }

  /// フォルダを開けない環境向けの入口カード（地図だけ見る）
  ///
  /// いま該当するのは **File System Access API を持たないブラウザ**
  /// （Firefox / Safari）だけ。Chrome / Edge なら通常のフォルダ選択が出る。
  Widget _buildWebPreviewCard() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const Icon(Icons.public, size: 48, color: Colors.blue),
            const SizedBox(height: 16),
            Text(
              t.home.webUnsupportedBrowserTitle,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t.home.webUnsupportedBrowserDesc,
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _openMapWithoutProject,
              icon: const Icon(Icons.map),
              label: Text(t.home.openMap),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// プロジェクトフォルダを開かずに地図画面へ遷移する。
  ///
  /// `projectRootDirProvider` は null のまま。ツリーは空のルートだけになり、
  /// `PathResolver` が全て null を返すのでファイルには一切触らない。
  void _openMapWithoutProject() {
    // ⚠ ツリーは**遷移前に**入れておく。MapPage の initState は
    //   folderTreeProvider が null だと自分で set しようとするが、
    //   それは build 中のプロバイダ変更にあたって riverpod が例外を投げる
    //   （プロジェクトを開く経路では HomeScreen が事前に set 済みなので露出しない）。
    ref
        .read(folderTreeProvider.notifier)
        .set(FolderNode('Home', visible: true));

    _navigatedToMapPage = true;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RootMapsHomePage()),
    ).then((_) {
      if (!mounted) return;
      setState(() => _navigatedToMapPage = false);
    });
  }

  /// 置き場所のホーム（native）。権限が無い間は案内とやり直しだけ
  Widget _buildLauncher() {
    if (!_permissionsGranted) {
      return Column(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 40),
          const SizedBox(height: 8),
          Text(t.home.permissionRequired, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _checkPermissions,
            icon: const Icon(Icons.refresh),
            label: Text(t.home.recheckPermission),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProjectLauncher(
          last: _lastProject,
          enabled: !_isOpeningProject,
          onOpenMyMap: _openMyMap,
          onOpenLast: _openProjectDir,
          onPickOther: _pickProjectDir,
          onReceive: PlatformCapabilities.supportsDriveSync ? _receiveFromDialog : null,
        ),
        if (_isOpeningProject) ...[
          const SizedBox(height: 16),
          Text(_openingProjectStatus, style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const LinearProgressIndicator(color: kKokageGreen),
        ],
        if (_canTutorial && !_isOpeningProject) ...[
          const SizedBox(height: 12),
          Align(
            child: TextButton.icon(
              onPressed: _startTutorial,
              icon: const Icon(Icons.school_outlined),
              label: Text(t.tutorial.homeButton),
              style: TextButton.styleFrom(foregroundColor: kKokageGreen),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 名前は下の帯に出すので、ここは道具だけ
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        actions: [
          // ユーザーガイドボタン
          IconButton(
            icon: const Icon(Icons.menu_book),
            tooltip: t.userGuide.title,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UserGuideScreen()),
              );
            },
          ),
          // チェンジログボタン（常時表示、小さめ）
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: t.changelog.title,
            onPressed: _openChangelog,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder:
            (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(0, constraints.maxHeight - 40),
                ),
                child: Column(
                  // 置き場所のホームは上から並べる（一覧が伸びる）
                  mainAxisAlignment: _usesProjectsHome ? MainAxisAlignment.start : MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const HomeHeader(),
                    // 更新通知バナー（未読時のみ表示）
                    AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child:
                          _hasUnreadChangelog
                              ? Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: _UpdateBanner(onTap: _openChangelog),
                              )
                              : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 20),
                    if (!PlatformCapabilities.canOpenLocalProject)
                      _buildWebPreviewCard()
                    else if (_usesProjectsHome)
                      _buildLauncher()
                    else
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.folder_open,
                                size: 48,
                                color: Colors.orange,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                t.home.startProject,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                t.home.selectProjectFolder,
                                style: const TextStyle(color: Colors.grey),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              ElevatedButton.icon(
                                onPressed:
                                    (_permissionsGranted && !_isOpeningProject)
                                        ? _pickProjectDir
                                        : null,
                                icon: Icon(
                                  _isOpeningProject
                                      ? Icons.hourglass_top
                                      : (_permissionsGranted
                                          ? Icons.folder
                                          : Icons.warning),
                                ),
                                label: Text(
                                  _isOpeningProject
                                      ? t.home.launching
                                      : (_permissionsGranted
                                          ? t.home.selectFolder
                                          : t.home.permissionRequired),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      (_permissionsGranted && !_isOpeningProject)
                                          ? Colors.blue
                                          : Colors.grey,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 32,
                                    vertical: 16,
                                  ),
                                  textStyle: const TextStyle(fontSize: 16),
                                ),
                              ),
                              if (_lastFolderName != null &&
                                  !_isOpeningProject) ...[
                                const SizedBox(height: 12),
                                TextButton.icon(
                                  onPressed:
                                      _permissionsGranted
                                          ? _reopenLastProjectDir
                                          : null,
                                  icon: const Icon(Icons.history),
                                  label: Text(
                                    '${t.home.reopenLastFolder}'
                                    '（$_lastFolderName）',
                                  ),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.blue,
                                  ),
                                ),
                              ],
                              if (_canTutorial && !_isOpeningProject) ...[
                                const SizedBox(height: 4),
                                TextButton.icon(
                                  onPressed: _permissionsGranted ? _startTutorial : null,
                                  icon: const Icon(Icons.school_outlined),
                                  label: Text(t.tutorial.homeButton),
                                ),
                              ],
                              if (_isOpeningProject) ...[
                                const SizedBox(height: 12),
                                Text(
                                  _openingProjectStatus,
                                  style: const TextStyle(color: Colors.grey),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                const LinearProgressIndicator(),
                              ],
                              if (!_permissionsGranted) ...[
                                const SizedBox(height: 16),
                                TextButton.icon(
                                  onPressed: _checkPermissions,
                                  icon: const Icon(Icons.refresh),
                                  label: Text(t.home.recheckPermission),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.blue,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    if (_projectDir != null && !_usesProjectsHome) ...[
                      const SizedBox(height: 16),
                      // 地図から戻ってきたときの導線。タップでピッカーを通さず同じフォルダを開き直す
                      Card(
                        color: Colors.green[50],
                        child: InkWell(
                          onTap: _isOpeningProject ? null : () => _openProjectDir(_projectDir!),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 24,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  t.common.selectedFolder,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _projectDir!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  t.home.tapToOpenMap,
                                  style: TextStyle(color: Colors.green[800]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
      ),
    );
  }
}

/// 更新通知バナー（アニメーション付き）
///
/// アイコン直下に表示され、タップでチェンジログ画面に遷移する。
class _UpdateBanner extends StatefulWidget {
  final VoidCallback onTap;
  const _UpdateBanner({required this.onTap});

  @override
  State<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<_UpdateBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.elasticOut,
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    // 少し遅らせてアニメーション開始（画面描画完了後に注目させる）
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Card(
          elevation: 0,
          color: const Color(0xFFFFF4D6), // ホームの緑に合う淡い黄
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    color: Color(0xFF6B4E00),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    t.changelog.updated,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF6B4E00),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right,
                    color: Color(0xFF6B4E00),
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
