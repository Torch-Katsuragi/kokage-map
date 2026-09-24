// 同期ダイアログの「行ごとに合わせる」（MergeChoice.merge）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/widgets/layer_drawer/sync_merge_dialog.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.ja));

  const mergeable = MergeFileEntry(
    relativePath: 'data.gpkg',
    localChange: MergeChangeType.modified,
    remoteChange: MergeChangeType.modified,
    driveFileId: 'f1',
    mergeable: true,
  );
  const photoConflict = MergeFileEntry(
    relativePath: 'photo.jpg',
    localChange: MergeChangeType.modified,
    remoteChange: MergeChangeType.modified,
    driveFileId: 'f2',
  );

  Future<List<MergeDecision>?> open(WidgetTester tester, List<MergeFileEntry> entries,
      {Future<void> Function()? before}) async {
    List<MergeDecision>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await SyncMergeDialog.show(context, folderName: 'proj', entries: entries, mode: SyncMode.upload);
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await before?.call();
    await tester.tap(find.text(t.layerDrawer.folder.syncExecute));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('mergeable な gpkg は「行ごとに合わせる」が出て、既定で選ばれている', (tester) async {
    final r = await open(tester, [mergeable], before: () async {
      expect(find.text(t.layerDrawer.folder.mergeLabel), findsOneWidget);
    });
    expect(r, hasLength(1));
    expect(r!.single.choice, MergeChoice.merge);
  });

  testWidgets('端末側を選び直せば local になる', (tester) async {
    final r = await open(tester, [mergeable], before: () async {
      await tester.tap(find.text('data.gpkg').first); // 端末側の行
      await tester.pumpAndSettle();
    });
    expect(r!.single.choice, MergeChoice.local);
  });

  testWidgets('mergeable でない衝突（写真など）には出ない', (tester) async {
    final r = await open(tester, [photoConflict], before: () async {
      expect(find.text(t.layerDrawer.folder.mergeLabel), findsNothing);
    });
    expect(r!.single.choice, isNot(MergeChoice.merge));
  });
}
