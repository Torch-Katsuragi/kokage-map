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
}
