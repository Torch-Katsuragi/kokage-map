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
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/db/database_factory_setup.dart';
import 'core/path_resolver.dart';
import 'core/platform_capabilities.dart';
import 'i18n/strings.g.dart';
import 'models/nodes/feature_node.dart';
import 'providers/drawing_provider.dart';
import 'providers/project_providers.dart';
import 'providers/selection_providers.dart';
import 'providers/service_providers.dart';
import 'providers/ui_state_providers.dart';
import 'screens/home_screen.dart';
import 'screens/map_page/map_page.dart';
import 'services/google_drive/index.dart';
import 'services/internal_gps_location_store.dart';
import 'services/kmeta_service.dart';
import 'services/party/party_firebase.dart';
import 'services/qgis/qgs_auto_refresh.dart';
import 'utils/background_save_manager.dart';
import 'widgets/debug_log_overlay.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _setupErrorHandlers();
  _setupDebugPrintFilter();

  // Android: ナビゲーションバー（◁□○）を非表示にする（ステータスバーは維持）
  if (PlatformCapabilities.hidesSystemNavigationBar) {
    unawaited(SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    ));
    // ジェスチャーでナビバーが表示された後、自動的に再非表示にする
    unawaited(SystemChrome.setSystemUIChangeCallback((systemOverlaysAreVisible) async {
      if (systemOverlaysAreVisible) {
        await Future.delayed(const Duration(seconds: 3));
        unawaited(SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: [SystemUiOverlay.top],
        ));
      }
    }));
  }

  // 言語設定: 保存値があればそれを使用、なければ端末の言語設定を自動検出
  await _initLocale();

  // 位置共有(パーティ機能)用のFirebase初期化を**非ブロッキングで**温める。
  // 山岳=常時オフライン前提のため、await せず起動クリティカルパスから外す
  // （runAppをブロックしない＝オフラインでも地図画面まで確実に到達できる）。
  // 実際の完了待ちはパーティ機能の入口（createRoom/joinRoom）で行う。
  unawaited(PartyFirebase.ensureInitialized());

  // sqflite の実装をプラットフォームごとに選ぶ（web は sqlite3 WASM）
  setupDatabaseFactory();

  AppLogger.debug('[Boot] runApp');
  runApp(TranslationProvider(child: const ProviderScope(child: RootMapsApp())));
}

/// 言語設定のSharedPreferencesキー
const kAppLocaleKey = 'app_locale';

/// 言語設定を初期化
/// 保存値がなければ端末から自動検出して初期値を設定
Future<void> _initLocale() async {
  final prefs = await SharedPreferences.getInstance();
  final savedLocale = prefs.getString(kAppLocaleKey);

  if (savedLocale != null) {
    // 保存済みの言語設定を使用
    final locale =
        AppLocale.values
            .where((l) => l.languageCode == savedLocale)
            .firstOrNull;
    if (locale != null) {
      await LocaleSettings.instance.setLocale(locale);
      return;
    }
  }

  // 保存値がない場合は端末の言語設定を自動検出して初期値に設定
  LocaleSettings.useDeviceLocaleSync();
  // 検出結果を保存（次回起動時に使用）
  await prefs.setString(
    kAppLocaleKey,
    LocaleSettings.currentLocale.languageCode,
  );
}

void _setupErrorHandlers() {
  final originalOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    final errorString = details.exception.toString();

    // Windows IME切り替え時のキーイベント不整合を握りつぶす
    // (デバッグモードのassertのみ発火、リリースでは無害)
    if (errorString.contains('_pressedKeys') ||
        (errorString.contains('KeyDownEvent') &&
            errorString.contains('physical key is already pressed')) ||
        (errorString.contains('KeyRepeatEvent') &&
            errorString.contains('physical key is not pressed'))) {
      if (kDebugMode) {
        AppLogger.debug('[Root Maps] IME関連キーイベント不整合を無視');
      }
      return;
    }

    if (originalOnError != null) {
      originalOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
}

/// Flutterエンジンが出す「Unable to parse JSON message」を抑制
void _setupDebugPrintFilter() {
  if (!kDebugMode) return;
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null &&
        (message.contains('Unable to parse JSON message') ||
            message.contains('The document is empty'))) {
      return;
    }
    original(message, wrapWidth: wrapWidth);
  };
}

class RootMapsApp extends ConsumerStatefulWidget {
  const RootMapsApp({super.key});

  @override
  ConsumerState<RootMapsApp> createState() => _RootMapsAppState();
}

class _RootMapsAppState extends ConsumerState<RootMapsApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupGlobalCallbacks();
    _initializeServices();
  }

  void _setupGlobalCallbacks() {
    ProjectPathResolver.instance.setRootPathGetter(
      () => ref.read(projectRootDirProvider),
    );
    GlobalPathResolver.instance.setRootPathGetter(
      () => ref.read(globalFolderPathProvider),
    );
    // メタデータが変わるたびに root の `<dir名>.qgs` を追従させる
    QgsAutoRefresh.instance.rootGetter = () => ref.read(folderTreeProvider);
    KMetaService.instance.onSaved = QgsAutoRefresh.instance.schedule;
    FeatureNode.setOnDisposeCallback((node) {
      final features = ref.read(selectedFeaturesProvider);
      if (features.contains(node)) {
        ref.read(selectedFeaturesProvider.notifier).remove(node);
      }
    });
  }

  bool _driveRestoreInFlight = false;

  /// ユーザーの操作に便乗して、web のDrive認可を無音で取り直す。
  ///
  /// ⚠ **1回きりにしないこと。** 最初のクリックの時点では GIS の
  /// スクリプトがまだ読み込まれていないことがあり、その回は必ず失敗する。
  /// 失敗は速いので、繋がるまで操作のたびに試してよい。
  void _restoreDriveOnce() {
    if (_driveRestoreInFlight) return;
    if (!PlatformCapabilities.supportsDriveSync) return;
    final service = GoogleDriveService();
    if (service.isDriveApiAvailable) return;
    _driveRestoreInFlight = true;
    // 待たない。失敗しても通常のサインインUIが受け止める
    unawaited(
      service.restoreWebAuthorization().whenComplete(
            () => _driveRestoreInFlight = false,
          ),
    );
  }

  Future<void> _initializeServices() async {
    // UIスケールを早期に読み込み
    await ref.read(uiScaleLevelProvider.notifier).load();

    // シングルトンサービスにRefを注入（プロバイダ初回読み込みでsetRef()が呼ばれる）
    ref.read(drawingStateProvider);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(gpsManagerServiceProvider).initialize();
        AppLogger.debug('[Root Maps] GPS管理サービス初期化完了（待機状態）');
      } catch (e) {
        AppLogger.debug('[Root Maps] GPS管理サービス初期化エラー: $e');
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(baseMapServiceProvider).initialize();
        AppLogger.debug('[Root Maps] 背景地図サービス初期化完了');
      } catch (e) {
        AppLogger.debug('[Root Maps] 背景地図サービス初期化エラー: $e');
      }
    });
    // Drive のサインインを起動時に仕込んでおく。
    //
    // web はここで One Tap（Chromeがアドレスバー下に出すログイン提案）が走る。
    // Driveダイアログを開いてから呼ぶと、提案が出るころには画面が出揃っていて
    // 気づかれない。**先に済ませておくと、ダイアログはスコープ認可だけになる。**
    //
    // ⚠ One Tap は出ないことがある（FedCMのクールダウン、Chromeの
    // 「サイト間のログイン」オフ、シークレットウィンドウ等）。
    // 出ない前提でボタン側の経路を残しておくこと。
    if (PlatformCapabilities.supportsDriveSync) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          // 無音で復元できるときだけサインイン済みにする。
          // アカウント選択を出すのは Drive 操作のボタン直下だけ
          await GoogleDriveService().restoreSessionSilently();
        } catch (e) {
          AppLogger.debug('[Root Maps] Drive初期化エラー: $e');
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.detached) {
      _cleanupOnAppExit();
    } else if (state == AppLifecycleState.paused) {
      BackgroundSaveManager.instance.flushAllChanges();
    }
  }

  Future<void> _cleanupOnAppExit() async {
    AppLogger.debug('[Root Maps] アプリ終了クリーンアップ開始');
    try {
      await InternalGpsLocationStore().dispose();
      await BackgroundSaveManager.instance.dispose();
      ref.read(gpsManagerServiceProvider).dispose();
      AppLogger.debug('[Root Maps] アプリ終了クリーンアップ完了');
    } catch (e) {
      AppLogger.debug('[Root Maps] クリーンアップエラー: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaleLevel = ref.watch(uiScaleLevelProvider);
    final scaleFactor = ref.read(uiScaleLevelProvider.notifier).scaleFactor;
    // scaleLevel を使用して依存関係を確立（watchで再構築をトリガー）
    assert(scaleLevel >= 0);

    return MaterialApp(
      title: t.common.appName,
      locale: TranslationProvider.of(context).flutterLocale,
      supportedLocales: AppLocaleUtils.supportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      builder: (context, child) {
        Widget content = child!;
        if (scaleFactor != 1.0) {
          // 論理サイズを逆スケールして、Transform.scaleで拡大した時に
          // 実際の画面サイズにぴったり収まるようにする
          final mq = MediaQuery.of(context);
          content = MediaQuery(
            data: mq.copyWith(
              size: mq.size / scaleFactor,
              padding: mq.padding / scaleFactor,
              viewInsets: mq.viewInsets / scaleFactor,
              viewPadding: mq.viewPadding / scaleFactor,
            ),
            child: FractionallySizedBox(
              widthFactor: 1.0 / scaleFactor,
              heightFactor: 1.0 / scaleFactor,
              alignment: Alignment.topLeft,
              child: Transform.scale(
                scale: scaleFactor,
                alignment: Alignment.topLeft,
                child: content,
              ),
            ),
          );
        }
        // ⚠ web の認可ポップアップは**ユーザー操作の直後（Chromeで約5秒）**
        // でしか開けない。Driveの操作を押してから復元しようとすると、
        // ダイアログを組み立てているうちに切れてブロックされる。
        // アプリ内の最初の操作でここで済ませておけば、Driveに触る頃には
        // もう繋がっている。何も起きない環境ではすぐ諦めるので害は無い。
        //
        // ⚠ この Listener はスケールの有無に関わらず**必ず**通すこと。
        // 以前は等倍のとき `return child!` で早期に抜けており、
        // **復元が一度も走らない**というバグになっていた（2026-08-28に発見）。
        return DebugLogOverlay(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _restoreDriveOnce(),
            child: content,
          ),
        );
      },
      home: const HomeScreen(),
      routes: {'/map': (context) => const RootMapsHomePage()},
    );
  }
}
