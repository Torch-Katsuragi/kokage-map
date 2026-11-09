import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/fs/k_file_system_io.dart';
import 'package:root_maps/services/google_drive/drive_transfer_registry.dart';
import 'package:root_maps/services/google_drive/sync_progress.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DriveTransferRegistry', () {
    final registry = DriveTransferRegistry.instance;

    test('normalizes keys and tracks active transfers and progress', () {
      const rawPath = r'C:\temp\map_project\共有\trail_folder\';
      final normalized = DriveTransferRegistry.normalizeKey(rawPath);
      expect(normalized.endsWith('/'), isFalse);
      expect(normalized.contains(r'\'), isFalse);

      final notifier = registry.progressOf(rawPath);
      expect(notifier.value, isNull);
      expect(registry.isBusy(rawPath), isFalse);

      registry.beginTransfer(
        rawPath,
        folderName: 'trail_folder',
        initial: const SyncProgress.scanning(),
        showOsNotification: false,
      );
      expect(registry.isBusy(rawPath), isTrue);
      expect(registry.activeCount.value, greaterThanOrEqualTo(1));
      expect(notifier.value?.phase, SyncPhase.scanning);

      registry.updateProgress(
        rawPath,
        const SyncProgress(
          phase: SyncPhase.transferring,
          transferredBytes: 50,
          totalBytes: 100,
          currentFileName: 'a.gpkg',
        ),
        showOsNotification: false,
      );
      expect(notifier.value?.percent, 50);

      registry.endTransfer(
        rawPath,
        success: true,
        showOsNotification: false,
      );
      expect(registry.isBusy(rawPath), isFalse);
      expect(notifier.value, isNull);
    });

    test('runDeduplicatedClone deduplicates concurrent requests for same driveId', () async {
      var runCount = 0;
      final completer = Completer<String>();

      final f1 = registry.runDeduplicatedClone('drive_123', () {
        runCount++;
        return completer.future;
      });
      final f2 = registry.runDeduplicatedClone('drive_123', () {
        runCount++;
        return Future.value('should_not_run');
      });

      expect(registry.isCloningDriveId('drive_123'), isTrue);
      expect(runCount, 1);

      completer.complete('C:/done');
      final results = await Future.wait([f1, f2]);
      expect(results, ['C:/done', 'C:/done']);
      expect(registry.isCloningDriveId('drive_123'), isFalse);
    });

    test('manages .sync/clone.pending marker lifecycle', () async {
      final tempDir = await Directory.systemTemp.createTemp('kokage_clone_test_');
      try {
        expect(await registry.hasClonePending(tempDir.path), isFalse);

        await registry.markClonePending(tempDir.path);
        expect(await registry.hasClonePending(tempDir.path), isTrue);

        await registry.clearClonePending(tempDir.path);
        expect(await registry.hasClonePending(tempDir.path), isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('aggregates bound child transfer progress into parent without zombie busy state or duplicate completion events', () async {
      const parentPath = r'C:\temp\map_project\共有\プリセットA';
      const childStorePath = r'C:\temp\map_project\.kokage\drive_store\id_1\子フォルダ1';

      final completedEvents = <DriveTransferCompletionEvent>[];
      final sub = registry.onTransferCompleted.listen(completedEvents.add);
      try {
        registry.beginTransfer(
          parentPath,
          folderName: 'プリセットA',
          initial: const SyncProgress.scanning(currentFileName: 'プリセット確認中'),
          showOsNotification: false,
        );
        registry.bindParentTransfer(childStorePath, parentPath);

        registry.beginTransfer(
          childStorePath,
          folderName: '子フォルダ1',
          initial: const SyncProgress.scanning(),
          showOsNotification: false,
        );
        // 子転送は親へ集約されるため activeCount は増えず 1 のまま
        expect(registry.activeCount.value, 1);
        expect(registry.isBusy(childStorePath), isTrue);
        expect(registry.isBusy(parentPath), isTrue);

        registry.updateProgress(
          childStorePath,
          const SyncProgress(
            phase: SyncPhase.transferring,
            transferredBytes: 30,
            totalBytes: 100,
            currentFileName: 'layer.gpkg',
          ),
          showOsNotification: false,
        );
        // updateProgress でも activeCount が増えないこと
        expect(registry.activeCount.value, 1);
        expect(
          registry.progressOf(parentPath).value?.currentFileName,
          '子フォルダ1 / layer.gpkg',
        );

        registry.endTransfer(
          childStorePath,
          success: true,
          showOsNotification: false,
        );
        await Future<void>.delayed(Duration.zero);
        expect(completedEvents, isEmpty);
        expect(registry.isBusy(parentPath), isTrue);

        registry.unbindParentTransfer(childStorePath);
        registry.endTransfer(
          parentPath,
          success: true,
          showOsNotification: false,
        );
        await Future<void>.delayed(Duration.zero);
        expect(registry.isBusy(parentPath), isFalse);
        expect(registry.isBusy(childStorePath), isFalse);
        expect(registry.activeCount.value, 0);
        expect(completedEvents.length, 1);
        expect(
          DriveTransferRegistry.normalizeKey(completedEvents.single.localPath),
          DriveTransferRegistry.normalizeKey(parentPath),
        );
      } finally {
        await sub.cancel();
      }
    });
  });

  group('IoFileSystem.writeStream', () {
    test('writes via .part temporary file and renames atomically on success', () async {
      final tempDir = await Directory.systemTemp.createTemp('kokage_stream_test_');
      const fs = IoFileSystem();
      try {
        final targetPath = p.join(tempDir.path, 'data.gpkg');
        final chunks = <List<int>>[
          [1, 2, 3, 4],
          [5, 6, 7, 8, 9],
        ];
        final received = <int>[];

        await fs.writeStream(
          targetPath,
          Stream.fromIterable(chunks),
          onChunk: received.add,
        );

        expect(received, [4, 5]);
        expect(await File(targetPath).exists(), isTrue);
        expect(await File('$targetPath.part').exists(), isFalse);
        expect(await File(targetPath).readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('cleans up .part file when stream throws an error', () async {
      final tempDir = await Directory.systemTemp.createTemp('kokage_stream_err_');
      const fs = IoFileSystem();
      try {
        final targetPath = p.join(tempDir.path, 'broken.gpkg');
        Stream<List<int>> failingStream() async* {
          yield [1, 2, 3];
          throw const SocketException('Connection reset');
        }

        await expectLater(
          fs.writeStream(targetPath, failingStream()),
          throwsA(isA<SocketException>()),
        );

        expect(await File(targetPath).exists(), isFalse);
        expect(await File('$targetPath.part').exists(), isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('readHeaderBytes reads only requested header prefix and returns full fileSize', () async {
      final tempDir = await Directory.systemTemp.createTemp('kokage_header_test_');
      const fs = IoFileSystem();
      try {
        final targetPath = p.join(tempDir.path, 'photo.jpg');
        final fullBytes = List<int>.generate(1024, (i) => i % 256);
        await File(targetPath).writeAsBytes(fullBytes);

        final res = await fs.readHeaderBytes(targetPath, 64);
        expect(res.fileSize, 1024);
        expect(res.bytes.length, 64);
        expect(res.bytes, fullBytes.sublist(0, 64));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
