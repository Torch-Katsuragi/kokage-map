// Drive のフォルダ一覧は 1 ページで切れるので、全ページたどる（2026-10-07）。
//
// 以前は 1 ページ目（100 件）しか見ておらず、101 件目からは「Drive に無い」扱いになって
// 同期が手元のファイルを消していた。本物の googleapis に偽の HTTP を挟んで確かめる。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';

void main() {
  test('nextPageToken をたどって全部返す', () async {
    final requests = <Uri>[];
    final api = drive.DriveApi(MockClient((req) async {
      requests.add(req.url);
      final token = req.url.queryParameters['pageToken'];
      final body = token == null
          ? {
              'nextPageToken': 'p2',
              'files': [for (var i = 0; i < 3; i++) {'id': 'a$i', 'name': 'a$i.jpg'}],
            }
          : {
              'files': [{'id': 'b0', 'name': 'b0.jpg'}],
            };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    }));

    final files = await GoogleDriveService.listAllPages(api, "'root' in parents", fields: 'files(id, name)');

    expect(files.map((f) => f.id), ['a0', 'a1', 'a2', 'b0']);
    expect(requests, hasLength(2));
    expect(requests.first.queryParameters['fields'], 'nextPageToken, files(id, name)');
    expect(requests.first.queryParameters['pageSize'], '1000');
    expect(requests.last.queryParameters['pageToken'], 'p2');
  });

  // Wi-Fi の切り替わりで名前解決が一瞬落ちる（2026-10-12、Pixel 9）。読むだけの呼び出しは 1 回だけ取り直す
  group('通信の一時的な失敗', () {
    setUp(() => GoogleDriveService.transientRetryDelay = Duration.zero);

    test('一覧は 1 回だけ取り直す', () async {
      var n = 0;
      final api = drive.DriveApi(MockClient((req) async {
        if (n++ == 0) throw http.ClientException("Failed host lookup: 'www.googleapis.com'");
        return http.Response(jsonEncode({'files': [{'id': 'a0', 'name': 'a0.jpg'}]}), 200,
            headers: {'content-type': 'application/json'});
      }));
      final files = await GoogleDriveService.listAllPages(api, "'root' in parents", fields: 'files(id, name)');
      expect(files.map((f) => f.id), ['a0']);
      expect(n, 2);
    });

    test('2 回続けて落ちたら投げる（空を返さない）', () async {
      var n = 0;
      final api = drive.DriveApi(MockClient((req) async {
        n++;
        throw http.ClientException('Failed host lookup');
      }));
      await expectLater(
        GoogleDriveService.listAllPages(api, "'root' in parents", fields: 'files(id, name)'),
        throwsA(isA<http.ClientException>()),
      );
      expect(n, 2);
    });

    test('API のエラーは取り直さない', () async {
      var n = 0;
      final api = drive.DriveApi(MockClient((req) async {
        n++;
        return http.Response(jsonEncode({'error': {'code': 404, 'message': 'not found'}}), 404,
            headers: {'content-type': 'application/json'});
      }));
      await expectLater(
        GoogleDriveService.listAllPages(api, "'root' in parents", fields: 'files(id, name)'),
        throwsA(isA<drive.DetailedApiRequestError>()),
      );
      expect(n, 1);
    });
  });
}
