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
/// アプリの最新バージョン確認と Google Play ストアへの誘導を行うサービス
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/platform_capabilities.dart';
import '../utils/app_logger.dart';

/// インストール済みバージョンと最新バージョンの差分情報
class AppUpdateInfo {
  /// 現在インストールされているバージョン名（例: `0.15.1`）
  final String currentVersion;

  /// 現在インストールされているビルド番号（例: `35`）
  final int? currentBuildNumber;

  /// リモートの最新バージョン名（例: `0.15.2`）
  final String latestVersion;

  /// リモートの最新ビルド番号（例: `36`）
  final int? latestBuildNumber;

  /// パッケージ名（例: `com.k_root.k_maps`）
  final String packageName;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.latestVersion,
    required this.latestBuildNumber,
    required this.packageName,
  });
}

class AppUpdateService {
  AppUpdateService._();
  static final instance = AppUpdateService._();

  static const String defaultPackageName = 'com.k_root.k_maps';
  static const String _pubspecUrl =
      'https://raw.githubusercontent.com/Torch-Katsuragi/kokage-map/master/pubspec.yaml';

  static final RegExp _versionLineRe = RegExp(
    r'^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$',
    multiLine: true,
  );

  /// `pubspec.yaml` のテキストから `(version, buildNumber)` を抽出する
  @visibleForTesting
  static ({String version, int? buildNumber})? parsePubspecVersion(
    String pubspecContent,
  ) {
    final match = _versionLineRe.firstMatch(pubspecContent);
    if (match == null) return null;
    final version = match.group(1)!;
    final buildNumber =
        match.group(2) != null ? int.tryParse(match.group(2)!) : null;
    return (version: version, buildNumber: buildNumber);
  }

  /// セマンティックバージョン（`X.Y.Z`）を比較する。
  /// `a > b` なら正、`a < b` なら負、同じなら `0` を返す。
  @visibleForTesting
  static int compareSemver(String a, String b) {
    final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  /// リモート版が現在版より新しいかどうか判定する
  @visibleForTesting
  static bool isNewerVersion({
    required String currentVersion,
    required int? currentBuildNumber,
    required String latestVersion,
    required int? latestBuildNumber,
  }) {
    final cmp = compareSemver(latestVersion, currentVersion);
    if (cmp > 0) return true;
    if (cmp < 0) return false;
    if (latestBuildNumber != null && currentBuildNumber != null) {
      return latestBuildNumber > currentBuildNumber;
    }
    return false;
  }

  /// 最新バージョンを確認し、更新があれば [AppUpdateInfo] を返す。
  ///
  /// 山岳（オフライン）環境を前提とし、タイムアウトや通信エラー時は黙って `null` を返す。
  Future<AppUpdateInfo?> checkForUpdate({
    @visibleForTesting http.Client? httpClient,
    @visibleForTesting Future<PackageInfo> Function()? packageInfoLoader,
    @visibleForTesting bool? forcePlatformSupport,
  }) async {
    final supported =
        forcePlatformSupport ?? PlatformCapabilities.supportsPlayStoreUpdate;
    if (!supported) return null;

    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    try {
      final info = await (packageInfoLoader ?? PackageInfo.fromPlatform)();
      final currentVersion = info.version.trim();
      if (currentVersion.isEmpty) return null;
      final currentBuild = int.tryParse(info.buildNumber.trim());
      final packageName =
          info.packageName.isNotEmpty ? info.packageName : defaultPackageName;

      final response = await client
          .get(Uri.parse(_pubspecUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;

      final parsed = parsePubspecVersion(response.body);
      if (parsed == null) return null;

      if (!isNewerVersion(
        currentVersion: currentVersion,
        currentBuildNumber: currentBuild,
        latestVersion: parsed.version,
        latestBuildNumber: parsed.buildNumber,
      )) {
        return null;
      }

      return AppUpdateInfo(
        currentVersion: currentVersion,
        currentBuildNumber: currentBuild,
        latestVersion: parsed.version,
        latestBuildNumber: parsed.buildNumber,
        packageName: packageName,
      );
    } catch (e) {
      AppLogger.debug('[AppUpdateService] バージョン確認スキップ（オフライン等）: $e');
      return null;
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// Google Play ストアのアプリ詳細ページを開く。
  /// `market://` スキームを優先し、開けない場合は Web URL にフォールバックする。
  Future<void> openPlayStore({String packageName = defaultPackageName}) async {
    final marketUri = Uri.parse('market://details?id=$packageName');
    try {
      final launched = await launchUrl(
        marketUri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return;
    } catch (_) {
      // Web URL へフォールバック
    }
    final webUri = Uri.parse(
      'https://play.google.com/store/apps/details?id=$packageName',
    );
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }
}
