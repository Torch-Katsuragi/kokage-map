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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/fs/k_file_system.dart';
import 'package:root_maps/models/nodes/drive_folder_set_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/services/google_drive/drive_folder_set_service.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DriveFolderSetManifest.parse', () {
    test('parses object format with name and folders array', () {
      const jsonStr = '''
      {
        "name": "現在の現場地図",
        "folders": [
          "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
          {
            "url": "https://drive.google.com/drive/folders/2BcDeFgHiJkLmNoPqRsTuVwXyZ",
            "readOnly": true
          },
          {
            "driveId": "3CdEfGhIjKlMnOpQrStUvWxYzA",
            "readOnly": false
          }
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.name, '現在の現場地図');
      expect(manifest.items.length, 3);

      expect(manifest.items[0].driveId, '1AbCdEfGhIjKlMnOpQrStUvWxYz');
      expect(manifest.items[0].readOnly, isFalse);

      expect(manifest.items[1].driveId, '2BcDeFgHiJkLmNoPqRsTuVwXyZ');
      expect(manifest.items[1].readOnly, isTrue);

      expect(manifest.items[2].driveId, '3CdEfGhIjKlMnOpQrStUvWxYzA');
      expect(manifest.items[2].readOnly, isFalse);
    });

    test('parses top-level array format and uses fallbackName', () {
      const jsonStr = '''
      [
        "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
        "https://kokage-map.sleeptree.jp/open?drive=2BcDeFgHiJkLmNoPqRsTuVwXyZ"
      ]
      ''';

      final manifest = DriveFolderSetManifest.parse(
        jsonStr,
        fallbackName: 'site_maps.json',
      );
      expect(manifest.name, 'site_maps');
      expect(manifest.items.length, 2);
      expect(manifest.items[0].driveId, '1AbCdEfGhIjKlMnOpQrStUvWxYz');
      expect(manifest.items[1].driveId, '2BcDeFgHiJkLmNoPqRsTuVwXyZ');
    });

    test('deduplicates duplicate folder IDs', () {
      const jsonStr = '''
      {
        "folders": [
          "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
          "1AbCdEfGhIjKlMnOpQrStUvWxYz"
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.items.length, 1);
      expect(manifest.invalidEntryCount, 0);
    });

    test('counts invalid entries in invalidEntryCount to prevent accidental deletion', () {
      const jsonStr = '''
      {
        "folders": [
          "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
          "not-a-valid-url-or-id!!",
          {"wrongKey": "https://drive.google.com/drive/folders/2BcDeFgHiJkLmNoPqRsTuVwXyZ"}
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.items.length, 1);
      expect(manifest.invalidEntryCount, 2);
    });
  });

  group('GoogleDriveService.extractFolderIdFromUrl', () {
    test('extracts ID from Google Drive file URL (/file/d/<id>/view)', () {
      const url =
          'https://drive.google.com/file/d/1JsonFileIdAbCdEfGhIjKlMnOp/view?usp=sharing';
      expect(
        GoogleDriveService.extractFolderIdFromUrl(url),
        '1JsonFileIdAbCdEfGhIjKlMnOp',
      );
    });
  });

  group('FolderNode / DriveFolderSetNode persistence', () {
    late Directory tempDir;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('folder_set_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('creates DriveFolderSetNode when isFolderSet is saved in KMetaSync (including after cache clear / SyncLedger overlay)', () async {
      final setPath = p.join(tempDir.path, '現在の現場地図');
      await fs.createDirectory(setPath);
      await KMetaService.instance.setDriveSync(
        setPath,
        driveId: 'json_file_id_123',
        driveFolderName: '現在の現場地図',
        driveUrl: 'https://drive.google.com/file/d/json_file_id_123/view',
        isReadOnly: true,
        isFolderSet: true,
        lastSynced: DateTime(2026, 10, 28, 12),
        driveRevisionId: 'md5_abc',
      );
      KMetaService.instance.invalidateCache(setPath);

      final parent = FolderNode('共有');
      final node = await FolderNode.tryCreateDriveFolderNode(
        setPath,
        '現在の現場地図',
        parent,
      );
      expect(node, isA<DriveFolderSetNode>());
      final setNode = node! as DriveFolderSetNode;
      expect(setNode.driveId, 'json_file_id_123');
      expect(setNode.manifestFileId, 'json_file_id_123');
    });
  });
}
