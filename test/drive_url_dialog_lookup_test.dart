// Drive クローンのダイアログは、フォルダを確かめられない理由で文言を分ける。
// 圏外で「共有設定を確認してください」と出し、直す必要のない共有設定を触らせていた（2026-10-12、Pixel 9）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/services/google_drive/drive_auth_state.dart';
import 'package:root_maps/widgets/dialogs/drive_url_input_dialog.dart';

import 'support/fake_google_drive.dart';

void main() {
  late FakeGoogleDrive fake;
  late String folderId;

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.ja);
    fake = FakeGoogleDrive();
    fake.authState.setAuthenticated(const DriveUser(id: 'x', email: 'a@example.com'));
    folderId = fake.createRootFolder('施業地');
  });

  Future<void> openAndEnter(WidgetTester tester, String id) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => DriveUrlInputDialog.show(context, driveService: fake),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://drive.google.com/drive/folders/$id');
    // 打ち終わりを待ってから確かめる
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  testWidgets('通信できないときは圏外の文言と再試行。共有設定は疑わせない', (tester) async {
    fake.lookupError = http.ClientException(
      "SocketException: Failed host lookup: 'www.googleapis.com'",
    );
    await openAndEnter(tester, folderId);

    expect(find.text(t.drive.folderOffline), findsOneWidget);
    expect(find.text(t.drive.accessDenied), findsNothing);
    expect(find.text(t.drive.retry), findsOneWidget);

    // 電波が戻ったら、再試行で見つかる
    fake.lookupError = null;
    await tester.tap(find.text(t.drive.retry));
    await tester.pumpAndSettle();
    expect(find.text(t.drive.folderOffline), findsNothing);
    expect(find.text(t.drive.folderDetected), findsOneWidget);
    expect(find.text('施業地'), findsOneWidget);
    expect(fake.calls['lookupFolder'], 2);
  });

  testWidgets('403 は共有設定の文言（再試行は出さない）', (tester) async {
    fake.lookupError = drive.DetailedApiRequestError(403, 'The user does not have sufficient permissions');
    await openAndEnter(tester, folderId);

    expect(find.text(t.drive.accessDenied), findsOneWidget);
    expect(find.text(t.drive.retry), findsNothing);
  });

  testWidgets('404 は「見つからない」の文言', (tester) async {
    await openAndEnter(tester, 'noSuchFolder123');

    expect(find.text(t.drive.folderNotFound), findsOneWidget);
    expect(find.text(t.drive.accessDenied), findsNothing);
    expect(find.text(t.drive.retry), findsNothing);
  });

  testWidgets('それ以外は短い文言にコードを添え、再試行を出す', (tester) async {
    fake.lookupError = drive.DetailedApiRequestError(500, 'Internal Error');
    await openAndEnter(tester, folderId);

    expect(find.text(t.drive.folderLookupFailed(code: 'HTTP 500')), findsOneWidget);
    expect(find.text(t.drive.retry), findsOneWidget);
  });
}
