// Drive クローンのダイアログは、キーボードが出て背が低くなってもはみ出さない
// （2026-09-24、Fold で「BOTTOM OVERFLOWED BY 15 PIXELS」）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/services/google_drive/drive_auth_state.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/widgets/dialogs/drive_url_input_dialog.dart';

void main() {
  for (final keyboard in [0.0, 1100.0]) {
    testWidgets('Fold 相当の画面で、キーボード ${keyboard > 0 ? "あり" : "なし"}でもはみ出さない', (
      tester,
    ) async {
      await LocaleSettings.setLocale(AppLocale.ja);
      GoogleDriveService().authState.setAuthenticated(
        const DriveUser(id: 'x', email: 'a@example.com'),
      );
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(1080, 2342);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => DriveUrlInputDialog.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(DriveUrlInputDialog), findsOneWidget);
      expect(find.byType(TabBarView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
