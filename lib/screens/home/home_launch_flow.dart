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
/// 起動時ディープリンク・LaunchRequest・ルーム招待・オンボーディング・練習プロジェクト導線
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/fs/project_folder_picker.dart';
import '../../core/launch_options.dart';
import '../../core/launch_request.dart';
import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/party/party_invite.dart';
import '../../tutorial/practice_project.dart';
import '../../tutorial/tutorial.dart';
import '../onboarding_screen.dart';

/// チュートリアルを使えるか（練習プロジェクトを実際のフォルダに作る）
/// web は練習用フォルダをブラウザのサイト専用領域（OPFS）に作るので、フォルダを選べなくても始められる
bool get canRunTutorial => kIsWeb || (fs.hasRealPaths && PlatformCapabilities.canOpenLocalProject);

/// オンボーディングが必要なら表示し、初回だったかどうかを返す
Future<bool> runOnboardingIfNeeded(BuildContext context) async {
  final needsOnboarding = await OnboardingScreen.shouldShow();
  if (needsOnboarding && context.mounted) {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => const OnboardingScreen(),
        fullscreenDialog: true,
      ),
    );
  }
  return needsOnboarding;
}

/// はじめての人にチュートリアルを開始するか尋ねる
Future<bool> showTutorialOfferDialog(BuildContext context) async {
  if (!context.mounted) return false;
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
  return yes == true;
}

/// 練習プロジェクトを作り直してプロバイダに案内開始をセットし、開くべきディレクトリを返す
Future<String> preparePracticeProjectForTutorial(WidgetRef ref) async {
  final proj = await PracticeProject.recreate();
  // 地図は自分のいる場所（GPS）から始める。練習のデータへは「データの仕組み」でダブルタップして飛ぶ（MapPage 側）
  ref.read(expandedGeoPackagesProvider.notifier).addExpanded(proj.gpkgPath);
  ref.read(tutorialProvider.notifier).start();
  return proj.dir;
}

/// 起動オプション（`--dart-define=PROJECT_DIR`）または起動ルート（`/map?project=...`）から
/// 自動オープン対象のパスを取り出す。無ければ null。
String? resolveInitialAutoOpenDir() {
  final requested = LaunchRequest.pending?.project;
  return LaunchOptions.hasProjectDir ? LaunchOptions.projectDir : requested;
}

/// 指定されたプロジェクトフォルダを開ける形に解決する（native は絶対パス、web は OPFS `opfs:<名前>`）
Future<String?> resolveRequestedProjectDir(String dir, {required bool permissionsGranted}) async {
  if (!permissionsGranted) {
    AppLogger.debug('[HomeScreen] 自動オープン: 権限が無いため見送り ($dir)');
    return null;
  }
  final opened = await openRequestedProjectFolder(dir);
  if (opened == null) {
    AppLogger.debug('[HomeScreen] 自動オープン: 開けない ($dir)');
    return null;
  }
  AppLogger.debug('[HomeScreen] 自動オープン ($dir)');
  return opened;
}

/// 招待URL（web の `?room=CODE`）が待機中か判定する
///
/// 「ルーム参加がURLで済む」= web版の主力機能。ゲストはプロジェクトを
/// 持っていない前提なので、プロジェクト無しの地図へ直行する。
bool shouldOpenPartyInviteDirectly({required bool navigatedToMapPage}) {
  if (!hasPendingRoomCode() || navigatedToMapPage) return false;
  AppLogger.debug('[HomeScreen] 招待URLを検出、地図画面へ直行');
  return true;
}
