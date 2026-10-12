// Drive フォルダの確認の失敗を「圏外」「権限なし」「無い」「その他」に分ける
// （2026-10-12、名前解決が一瞬落ちただけで「共有設定を確認してください」と出ていた）
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/services/google_drive/folder_lookup.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/services/google_drive/network_error.dart';

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.ja));

  group('isNetworkError', () {
    test('名前解決の失敗・接続切れ・時間切れは通信の失敗', () {
      expect(
        isNetworkError(http.ClientException("SocketException: Failed host lookup: 'www.googleapis.com'")),
        isTrue,
      );
      expect(isNetworkError(http.ClientException('Software caused connection abort')), isTrue);
      expect(isNetworkError(TimeoutException('x')), isTrue);
      // dart:io の SocketException は web に無いので文字で見る
      expect(isNetworkError(Exception("SocketException: Failed host lookup: 'x'")), isTrue);
    });

    test('それ以外は通信の失敗ではない', () {
      expect(isNetworkError(StateError('bad state')), isFalse);
      expect(isNetworkError(const FormatException('bad json')), isFalse);
    });
  });

  group('classifyFolderLookupError', () {
    test('通信の失敗は offline', () {
      expect(
        classifyFolderLookupError(
          http.ClientException("SocketException: Failed host lookup: 'www.googleapis.com'"),
        ),
        FolderLookupFailure.offline,
      );
      expect(classifyFolderLookupError(TimeoutException('x')), FolderLookupFailure.offline);
    });

    test('403 は権限なし、404 は無い、ほかの状態コードはその他', () {
      expect(classifyFolderLookupError(drive.DetailedApiRequestError(403, 'forbidden')),
          FolderLookupFailure.forbidden);
      expect(classifyFolderLookupError(drive.DetailedApiRequestError(404, 'File not found')),
          FolderLookupFailure.notFound);
      expect(classifyFolderLookupError(drive.DetailedApiRequestError(500, 'backend error')),
          FolderLookupFailure.other);
    });

    test('API の応答は文言に「timed out」があっても状態コードで見る', () {
      expect(classifyFolderLookupError(drive.DetailedApiRequestError(503, 'request timed out')),
          FolderLookupFailure.other);
    });

    test('知らない例外はその他', () {
      expect(classifyFolderLookupError(StateError('x')), FolderLookupFailure.other);
    });
  });

  group('FolderLookup の文言', () {
    test('圏外は共有設定を疑わせず、取り直せる', () {
      final l = FolderLookup.fromError(http.ClientException('Failed host lookup'));
      expect(l.message, t.drive.folderOffline);
      expect(l.message, isNot(contains('共有設定')));
      expect(l.canRetry, isTrue);
    });

    test('403 はいまの共有設定の文言、404 は別の文言。どちらも取り直しは出さない', () {
      final forbidden = FolderLookup.fromError(drive.DetailedApiRequestError(403, 'x'));
      final notFound = FolderLookup.fromError(drive.DetailedApiRequestError(404, 'x'));
      expect(forbidden.message, t.drive.accessDenied);
      expect(notFound.message, t.drive.folderNotFound);
      expect(notFound.message, isNot(t.drive.accessDenied));
      expect((forbidden.canRetry, notFound.canRetry), (false, false));
    });

    test('その他はコードを添える', () {
      final l = FolderLookup.fromError(drive.DetailedApiRequestError(500, 'x'));
      expect(l.message, contains('HTTP 500'));
      expect(l.canRetry, isTrue);
    });
  });

  group('retryTransient', () {
    setUp(() => GoogleDriveService.transientRetryDelay = Duration.zero);

    test('通信の失敗は 1 回だけ取り直す', () async {
      var n = 0;
      final r = await GoogleDriveService.retryTransient(() async {
        if (++n == 1) throw http.ClientException('Software caused connection abort');
        return 'ok';
      });
      expect((r, n), ('ok', 2));
    });

    test('API のエラーは取り直さない', () async {
      var n = 0;
      await expectLater(
        GoogleDriveService.retryTransient(() async {
          n++;
          throw drive.DetailedApiRequestError(404, 'connection timed out');
        }),
        throwsA(isA<drive.DetailedApiRequestError>()),
      );
      expect(n, 1);
    });
  });
}
