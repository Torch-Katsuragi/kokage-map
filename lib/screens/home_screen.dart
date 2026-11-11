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
import 'package:root_maps/utils/app_logger.dart';

import '../core/fs/project_folder_picker.dart';
import '../core/launch_request.dart';
import '../core/platform_capabilities.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/folder_node.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/app_update_service.dart';
import '../services/changelog_service.dart';
import '../services/projects_home.dart';
import '../tutorial/tutorial.dart';
import 'changelog_screen.dart';
import 'home/folder_browser_screen.dart';
import 'home/home_header_banners.dart';
import 'home/home_launch_flow.dart';
import 'home/home_permissions.dart';
import 'home/project_launcher.dart';
import 'home/shared_map_receiver.dart';
import 'map_page/map_page.dart';
import 'user_guide_screen.dart';

export 'settings_screen.dart' show kGlobalFolderCustomPathKey;

/// ホーム画面（最小構成）
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final HomePermissionChecker _permissionChecker = HomePermissionChecker();
  final SharedLinkDeduplicator _sharedLinkDeduplicator = SharedLinkDeduplicator();

  String? _projectDir;
  bool _permissionsGranted = false;
  bool _navigatedToMapPage = false; // マップ画面に遷移済みフラグ
  bool _isOpeningProject = false; // プロジェクト開始中フラグ

  /// 前回開いたフォルダの名前（web のみ。無ければ null）
  String? _lastFolderName;
  String _openingProjectStatus = '';
  bool _initCompleted = false; // 初期化（オンボーディング含む）完了フラグ
  bool _hasUnreadChangelog = false; // チェンジログ未読フラグ
  AppUpdateInfo? _availableUpdate; // リモートに新しい版があるときの情報
  bool _autoOpenAttempted = false; // --dart-define=PROJECT_DIR の自動オープンを試したか

  /// 設定から頼まれた。地図の上からなら、地図が閉じてから始める
  bool _tutorialPending = false;

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
    _checkAppUpdate();
    _loadLastFolderName();
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
      if (_initCompleted && !_permissionChecker.isChecking && !_navigatedToMapPage) {
        _checkPermissions();
        _checkAppUpdate();
      }
    }
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

  /// QR の共有リンクが届いた（App Links）。地図を開いていればホームに戻ってから取り込む
  void _onSharedLink() {
    final link = LaunchRequest.sharedLinks.value;
    if (link == null || !_usesProjectsHome) return;
    if (!_permissionsGranted || _isOpeningProject) {
      // 権限が取れたら（_loadProjects の後で）もう一度見る
      return;
    }
    LaunchRequest.sharedLinks.value = null;
    final id = _sharedLinkDeduplicator.acceptAndExtractDriveId(link);
    if (id == null) return;
    if (_navigatedToMapPage) Navigator.of(context).popUntil((r) => r.isFirst);
    unawaited(_receiveFromDrive(id));
  }

  /// Drive フォルダを、いつもの地図の 共有/ に取り込んで開く（QR のリンク）
  Future<void> _receiveFromDrive(String driveId) => _receiveAndOpen(
        () => receiveSharedFromDriveId(
          driveId: driveId,
          notifications: ref.read(notificationCenterProvider.notifier),
          confirmReceive: (name, owner) => showReceiveConfirmDialog(
            context,
            folderName: name,
            owner: owner,
          ),
        ),
      );

  /// ホームの「QR で受け取る」: アプリのカメラで読む（Drive の URL を貼っても読める）
  Future<void> _receiveFromDialog() => promptAndReceiveSharedMap(
        context,
        notifications: ref.read(notificationCenterProvider.notifier),
        runReceiveAndOpen: _receiveAndOpen,
      );

  /// 共有の地図を取り込んで（[receive] がいつもの地図のパスを返す。やめたら null）開く。取り込み中は進み具合を出す
  Future<void> _receiveAndOpen(Future<String?> Function() receive) async {
    _setOpening(t.home.receivingShared);
    try {
      final root = await receive();
      if (root == null || !mounted) return;
      _setOpening(null);
      await _openProjectDir(root);
    } catch (e) {
      AppLogger.debug('[HomeScreen] 共有の地図を取り込めない: $e');
      _notify(t.home.receiveFailed, NotificationLevel.error);
    } finally {
      if (mounted && !_navigatedToMapPage) _setOpening(null);
    }
  }

  /// 開いている途中の表示。[status] が null なら終わり
  void _setOpening(String? status) {
    if (!mounted) return;
    setState(() {
      _isOpeningProject = status != null;
      _openingProjectStatus = status ?? '';
    });
  }

  void _notify(String title, NotificationLevel level, {String? detail}) {
    ref.read(notificationCenterProvider.notifier).add(title: title, detail: detail, level: level);
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
      _notify(t.home.reopenLastFolderFailed, NotificationLevel.warning);
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

  /// 最新版アップデートを確認
  Future<void> _checkAppUpdate() async {
    final update = await AppUpdateService.instance.checkForUpdate();
    if (mounted) {
      setState(() => _availableUpdate = update);
    }
  }

  /// Google Play ストアのアプリページを開く
  Future<void> _openPlayStore() async {
    final pkg = _availableUpdate?.packageName ?? AppUpdateService.defaultPackageName;
    await AppUpdateService.instance.openPlayStore(packageName: pkg);
  }

  void _openChangelog() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChangelogScreen(
          onRead: () {
            if (mounted) {
              setState(() => _hasUnreadChangelog = false);
            }
          },
        ),
      ),
    );
  }

  /// オンボーディング確認 → 権限チェック → 起動時ディープリンク・招待・チュートリアル案内
  Future<void> _initPermissions() async {
    final needsOnboarding = await runOnboardingIfNeeded(context);
    _initCompleted = true;
    await _checkPermissions();
    await _maybeAutoOpenProjectDir();
    if (shouldOpenPartyInviteDirectly(navigatedToMapPage: _navigatedToMapPage)) {
      _openMapWithoutProject();
    }
    // はじめての人にだけ一度聞く（あとからはホームと設定から）
    if (needsOnboarding) await _offerTutorial();
  }

  Future<void> _offerTutorial() async {
    if (!mounted || !canRunTutorial || !_permissionsGranted || _navigatedToMapPage) return;
    if (await showTutorialOfferDialog(context)) {
      await _startTutorial();
    }
  }

  void _onTutorialRequest() {
    if (_navigatedToMapPage) {
      _tutorialPending = true;
    } else {
      unawaited(_startTutorial());
    }
  }

  /// 練習プロジェクトを作り直して開き、案内を始める
  Future<void> _startTutorial() async {
    if (!mounted || !canRunTutorial || _isOpeningProject || _navigatedToMapPage) return;
    if (!_permissionsGranted) {
      _notify(t.permissions.storageNotGranted, NotificationLevel.error);
      return;
    }
    _setOpening(t.tutorial.preparing);
    final String dir;
    try {
      dir = await preparePracticeProjectForTutorial(ref);
    } catch (e) {
      AppLogger.debug('[HomeScreen] 練習プロジェクトを作れない: $e');
      if (!mounted) return;
      setState(() => _isOpeningProject = false);
      _notify(t.tutorial.failed, NotificationLevel.error);
      return;
    }
    await _openProjectDir(dir);
  }

  /// フォルダ選択を挟まずに開く（`--dart-define=PROJECT_DIR` または `/map?project=...`）
  Future<void> _maybeAutoOpenProjectDir() async {
    if (_autoOpenAttempted) return;
    _autoOpenAttempted = true;

    final dir = resolveInitialAutoOpenDir();
    if (dir == null) return;
    await _openRequestedProject(dir);
  }

  Future<void> _openRequestedProject(String dir) async {
    final opened = await resolveRequestedProjectDir(
      dir,
      permissionsGranted: _permissionsGranted,
    );
    if (opened != null) {
      await _openProjectDir(opened);
    }
  }

  /// 起動中に `/map?project=...` が届いた（ホームにいる間だけ受ける。地図にいる間は MapPage が受ける）
  void _onLaunchRequest() {
    final req = LaunchRequest.incoming.value;
    if (req?.project == null || _navigatedToMapPage || _isOpeningProject) return;
    if (req!.hasCamera) LaunchRequest.defer(req); // カメラは次に組まれる MapPage が拾う
    _openRequestedProject(req.project!);
  }

  /// ストレージ・位置情報権限の確認・リクエスト
  Future<void> _checkPermissions() => _permissionChecker.checkPermissions(
        onGranted: () {
          if (!mounted) return;
          setState(() => _permissionsGranted = true);
          unawaited(_loadProjects());
        },
        onDenied: () {
          if (mounted) showPermissionDeniedDialog(context);
        },
      );

  Future<void> _pickProjectDir() async {
    AppLogger.debug('[HomeScreen] プロジェクトフォルダ選択開始');
    AppLogger.debug('[HomeScreen] 権限状態: $_permissionsGranted');

    if (!_permissionsGranted) {
      AppLogger.debug('[HomeScreen] 権限が許可されていません');
      _notify(t.permissions.storageNotGranted, NotificationLevel.error);
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
    _projectDir = dir;
    await bootstrapProjectIntoProviders(
      ref,
      dir: dir,
      usesProjectsHome: _usesProjectsHome,
      onStatus: _setOpening,
    );

    // フォルダ選択後すぐ地図編集画面へ遷移
    if (!mounted) return;
    AppLogger.debug('[HomeScreen] 地図画面に遷移中...');
    _pushMapPage(onReturned: () {
      ref.read(tutorialProvider.notifier).stop(); // 地図を閉じたら案内も終わり
      _setOpening(null);
      unawaited(_loadProjects());
      if (_tutorialPending) {
        _tutorialPending = false;
        unawaited(_startTutorial());
      }
    });
  }

  /// 地図画面へ移る。戻ってきたら [onReturned]（画面が残っていれば）
  void _pushMapPage({VoidCallback? onReturned}) {
    // マップ画面遷移後は権限チェックを無効化（GPS権限リクエストとの競合防止）
    _navigatedToMapPage = true;
    unawaited(Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RootMapsHomePage()),
    ).then((_) {
      if (!mounted) return;
      setState(() => _navigatedToMapPage = false);
      onReturned?.call();
    }));
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
    ref.read(folderTreeProvider.notifier).set(FolderNode('Home', visible: true));
    _pushMapPage();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 名前は下の帯に出すので、ここは道具だけ
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        actions: [
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
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: t.changelog.title,
            onPressed: _openChangelog,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
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
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: _availableUpdate != null
                      ? Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: PlayStoreUpdateBanner(
                            updateInfo: _availableUpdate!,
                            onTap: _openPlayStore,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: _hasUnreadChangelog
                      ? Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: ChangelogUpdateBanner(onTap: _openChangelog),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 20),
                if (!PlatformCapabilities.canOpenLocalProject)
                  WebPreviewCard(onOpenMapWithoutProject: _openMapWithoutProject)
                else if (_usesProjectsHome)
                  NativeHomeLauncher(
                    permissionsGranted: _permissionsGranted,
                    isOpeningProject: _isOpeningProject,
                    openingProjectStatus: _openingProjectStatus,
                    lastProject: _lastProject,
                    canTutorial: canRunTutorial,
                    onRecheckPermissions: _checkPermissions,
                    onOpenMyMap: _openMyMap,
                    onOpenLast: _openProjectDir,
                    onPickOther: _pickProjectDir,
                    onReceive: PlatformCapabilities.supportsDriveSync ? _receiveFromDialog : null,
                    onStartTutorial: _startTutorial,
                  )
                else
                  WebFolderPickerCard(
                    permissionsGranted: _permissionsGranted,
                    isOpeningProject: _isOpeningProject,
                    openingProjectStatus: _openingProjectStatus,
                    lastFolderName: _lastFolderName,
                    canTutorial: canRunTutorial,
                    onPickProjectDir: _pickProjectDir,
                    onReopenLastFolder: _reopenLastProjectDir,
                    onStartTutorial: _startTutorial,
                    onRecheckPermissions: _checkPermissions,
                  ),
                if (_projectDir != null && !_usesProjectsHome) ...[
                  const SizedBox(height: 16),
                  ReopenProjectCard(
                    dir: _projectDir!,
                    isOpeningProject: _isOpeningProject,
                    onReopen: _openProjectDir,
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
