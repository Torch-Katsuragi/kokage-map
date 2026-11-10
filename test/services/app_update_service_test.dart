import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:root_maps/services/app_update_service.dart';

void main() {
  group('AppUpdateService', () {
    test('parsePubspecVersion extracts version and optional buildNumber', () {
      final parsed = AppUpdateService.parsePubspecVersion('''
name: root_maps
description: "こかげマップ"
version: 0.15.2+36
''');
      expect(parsed, isNotNull);
      expect(parsed!.version, '0.15.2');
      expect(parsed.buildNumber, 36);

      final noBuild = AppUpdateService.parsePubspecVersion('version: 1.2.3\n');
      expect(noBuild, isNotNull);
      expect(noBuild!.version, '1.2.3');
      expect(noBuild.buildNumber, isNull);
    });

    test('isNewerVersion compares semver and buildNumber accurately', () {
      expect(
        AppUpdateService.isNewerVersion(
          currentVersion: '0.15.1',
          currentBuildNumber: 35,
          latestVersion: '0.15.2',
          latestBuildNumber: 36,
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isNewerVersion(
          currentVersion: '0.15.2',
          currentBuildNumber: 35,
          latestVersion: '0.15.2',
          latestBuildNumber: 36,
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isNewerVersion(
          currentVersion: '0.15.2',
          currentBuildNumber: 36,
          latestVersion: '0.15.2',
          latestBuildNumber: 36,
        ),
        isFalse,
      );
      expect(
        AppUpdateService.isNewerVersion(
          currentVersion: '0.15.3',
          currentBuildNumber: 37,
          latestVersion: '0.15.2',
          latestBuildNumber: 36,
        ),
        isFalse,
      );
    });

    test('checkForUpdate returns AppUpdateInfo when remote version is newer', () async {
      final client = MockClient((_) async {
        return http.Response('name: root_maps\nversion: 0.16.0+40\n', 200);
      });

      final info = await AppUpdateService.instance.checkForUpdate(
        forcePlatformSupport: true,
        httpClient: client,
        packageInfoLoader: () async => PackageInfo(
          appName: 'こかげマップ',
          packageName: 'com.k_root.k_maps',
          version: '0.15.2',
          buildNumber: '36',
        ),
      );

      expect(info, isNotNull);
      expect(info!.currentVersion, '0.15.2');
      expect(info.currentBuildNumber, 36);
      expect(info.latestVersion, '0.16.0');
      expect(info.latestBuildNumber, 40);
      expect(info.packageName, 'com.k_root.k_maps');
    });

    test('checkForUpdate returns null when up-to-date or offline', () async {
      final sameClient = MockClient((_) async {
        return http.Response('name: root_maps\nversion: 0.15.2+36\n', 200);
      });
      final sameResult = await AppUpdateService.instance.checkForUpdate(
        forcePlatformSupport: true,
        httpClient: sameClient,
        packageInfoLoader: () async => PackageInfo(
          appName: 'こかげマップ',
          packageName: 'com.k_root.k_maps',
          version: '0.15.2',
          buildNumber: '36',
        ),
      );
      expect(sameResult, isNull);

      final offlineClient = MockClient((_) async {
        throw Exception('No network');
      });
      final offlineResult = await AppUpdateService.instance.checkForUpdate(
        forcePlatformSupport: true,
        httpClient: offlineClient,
        packageInfoLoader: () async => PackageInfo(
          appName: 'こかげマップ',
          packageName: 'com.k_root.k_maps',
          version: '0.15.1',
          buildNumber: '35',
        ),
      );
      expect(offlineResult, isNull);
    });
  });
}
