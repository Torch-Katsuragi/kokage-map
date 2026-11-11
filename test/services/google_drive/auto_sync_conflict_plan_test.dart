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

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:root_maps/services/google_drive/auto_sync_service.dart';
import 'package:root_maps/services/google_drive/drive_transfer_registry.dart';
import 'package:root_maps/services/google_drive/drive_url_parser.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';

void main() {
  group('AutoSyncService.planAutoMergeDecisions', () {
    test('auto-merges disjoint local and remote file changes without flagging conflict', () async {
      final entries = [
        const MergeFileEntry(
          relativePath: 'local_only.gpkg',
          localChange: MergeChangeType.modified,
          remoteChange: MergeChangeType.none,
        ),
        const MergeFileEntry(
          relativePath: 'photos/remote_added.jpg',
          localChange: MergeChangeType.none,
          remoteChange: MergeChangeType.added,
        ),
      ];

      final plan = await AutoSyncService.planAutoMergeDecisions(
        entries: entries,
        localPath: '/proj/shared',
        failedMergeAt: const {},
        isRenamedProjectFile: (_, _) async => false,
      );

      expect(plan.hasRealConflict, isFalse);
      expect(plan.needsTreeRefresh, isTrue);
      expect(plan.decisions.length, 2);
      expect(plan.decisions[0].entry.relativePath, 'local_only.gpkg');
      expect(plan.decisions[0].choice, MergeChoice.local);
      expect(plan.decisions[1].entry.relativePath, 'photos/remote_added.jpg');
      expect(plan.decisions[1].choice, MergeChoice.remote);
    });

    test('schedules row-level merge for mergeable gpkg, suppresses same failed remote version, and retries on newer version', () async {
      final t1 = DateTime.utc(2026, 11, 10, 12);
      final t2 = DateTime.utc(2026, 11, 10, 13);

      const path = '/proj/shared';
      final conflictV1 = MergeFileEntry(
        relativePath: 'survey.gpkg',
        localChange: MergeChangeType.modified,
        remoteChange: MergeChangeType.modified,
        remoteModifiedTime: t1,
        mergeable: true,
      );

      // 1. 初回: mergeable なので MergeChoice.merge が計画される
      final firstPlan = await AutoSyncService.planAutoMergeDecisions(
        entries: [conflictV1],
        localPath: path,
        failedMergeAt: const {},
        isRenamedProjectFile: (_, _) async => false,
      );
      expect(firstPlan.hasRealConflict, isFalse);
      expect(firstPlan.needsTreeRefresh, isTrue);
      expect(firstPlan.decisions.single.choice, MergeChoice.merge);

      // 2. 同じ remoteModifiedTime (t1) で前回失敗していた場合: 再試行せずユーザー解決待ちにする
      final suppressedPlan = await AutoSyncService.planAutoMergeDecisions(
        entries: [conflictV1],
        localPath: path,
        failedMergeAt: {'$path/survey.gpkg': t1},
        isRenamedProjectFile: (_, _) async => false,
      );
      expect(suppressedPlan.hasRealConflict, isTrue);
      expect(suppressedPlan.decisions, isEmpty);

      // 3. Drive 側が新しい版 (t2) に更新された場合: 再び行単位マージを試みる
      final conflictV2 = MergeFileEntry(
        relativePath: 'survey.gpkg',
        localChange: MergeChangeType.modified,
        remoteChange: MergeChangeType.modified,
        remoteModifiedTime: t2,
        mergeable: true,
      );
      final retryPlan = await AutoSyncService.planAutoMergeDecisions(
        entries: [conflictV2],
        localPath: path,
        failedMergeAt: {'$path/survey.gpkg': t1},
        isRenamedProjectFile: (_, _) async => false,
      );
      expect(retryPlan.hasRealConflict, isFalse);
      expect(retryPlan.decisions.single.choice, MergeChoice.merge);
    });

    test('skips local deletions except renamed .qgs project files and marks non-mergeable conflicts', () async {
      final entries = [
        const MergeFileEntry(
          relativePath: 'deleted_data.gpkg',
          localChange: MergeChangeType.deleted,
          remoteChange: MergeChangeType.none,
        ),
        const MergeFileEntry(
          relativePath: 'old_name.qgs',
          localChange: MergeChangeType.deleted,
          remoteChange: MergeChangeType.none,
        ),
        const MergeFileEntry(
          relativePath: 'photo.jpg',
          localChange: MergeChangeType.modified,
          remoteChange: MergeChangeType.modified,
          mergeable: false,
        ),
      ];

      final plan = await AutoSyncService.planAutoMergeDecisions(
        entries: entries,
        localPath: '/proj/shared',
        failedMergeAt: const {},
        isRenamedProjectFile: (_, rel) async => rel == 'old_name.qgs',
      );

      expect(plan.hasRealConflict, isTrue);
      expect(plan.decisions.length, 1);
      expect(plan.decisions.single.entry.relativePath, 'old_name.qgs');
      expect(plan.decisions.single.choice, MergeChoice.local);
    });
  });

  group('DriveTransferRegistry path helpers & DriveUrlParser', () {
    test('normalizes Windows/POSIX separators and checks strict vs inclusive descendants', () {
      expect(
        DriveTransferRegistry.sameNormalizedPath(
          r'C:\Users\test\共有\現場A\',
          'C:/Users/test/共有/現場A',
        ),
        isTrue,
      );
      expect(
        DriveTransferRegistry.isStrictDescendantPath(
          r'C:\Users\test\共有\現場A\子フォルダ',
          'C:/Users/test/共有/現場A/',
        ),
        isTrue,
      );
      expect(
        DriveTransferRegistry.isStrictDescendantPath(
          'C:/Users/test/共有/現場A',
          'C:/Users/test/共有/現場A',
        ),
        isFalse,
      );
      expect(
        DriveTransferRegistry.isSameOrDescendantPath(
          'C:/Users/test/共有/現場A',
          'C:/Users/test/共有/現場A',
        ),
        isTrue,
      );
      // プレフィックスが似ている別フォルダ（現場A2）を子孫と誤判定しないこと
      expect(
        DriveTransferRegistry.isSameOrDescendantPath(
          'C:/Users/test/共有/現場A2',
          'C:/Users/test/共有/現場A',
        ),
        isFalse,
      );
    });

    test('parses Drive URLs across folders, /file/d/, ?id=, and kokage share links and classifies metadata', () {
      expect(
        extractDriveIdFromUrl(
          'https://drive.google.com/drive/u/0/folders/1FolderIdAbCdEfGhIjKlMn?usp=sharing',
        ),
        '1FolderIdAbCdEfGhIjKlMn',
      );
      expect(
        extractDriveIdFromUrl(
          'https://drive.google.com/open?id=1QueryIdAbCdEfGhIjKlMnOp',
        ),
        '1QueryIdAbCdEfGhIjKlMnOp',
      );
      expect(
        extractDriveIdFromUrl('https://example.com/drive/folders/not_drive'),
        isNull,
      );

      expect(
        isDriveFolderMetadata(
          drive.File(mimeType: 'application/vnd.google-apps.folder'),
        ),
        isTrue,
      );
      expect(
        isDriveJsonFileMetadata(
          drive.File(name: 'preset.JSON', mimeType: 'text/plain'),
        ),
        isTrue,
      );
      expect(
        isDriveJsonFileMetadata(
          drive.File(
            name: 'folder.json',
            mimeType: 'application/vnd.google-apps.folder',
          ),
        ),
        isFalse,
      );
    });
  });
}
