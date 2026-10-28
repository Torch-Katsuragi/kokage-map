import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/services/google_drive/sync_progress.dart';

void main() {
  group('SyncProgress', () {
    test('scanning and finalizing phases report null fraction (indeterminate)', () {
      const scanning = SyncProgress(
        phase: SyncPhase.scanning,
        transferredBytes: 50,
        totalBytes: 100,
      );
      expect(scanning.fraction, isNull);
      expect(scanning.percent, isNull);

      const finalizing = SyncProgress(
        phase: SyncPhase.finalizing,
        transferredBytes: 100,
        totalBytes: 100,
      );
      expect(finalizing.fraction, isNull);
      expect(finalizing.percent, isNull);
    });

    test('transferring phase computes byte-weighted fraction and percent', () {
      const progress = SyncProgress(
        phase: SyncPhase.transferring,
        completedFiles: 1,
        totalFiles: 3,
        transferredBytes: 25 * 1024 * 1024,
        totalBytes: 100 * 1024 * 1024,
        currentFileName: 'trail.gpkg',
      );
      expect(progress.fraction, closeTo(0.25, 1e-6));
      expect(progress.percent, 25);
      expect(progress.formattedBytes, '25.0 MB / 100.0 MB');
    });

    test('transferring phase falls back to file ratio when totalBytes is 0', () {
      const progress = SyncProgress(
        phase: SyncPhase.transferring,
        completedFiles: 2,
        totalFiles: 5,
        transferredBytes: 0,
        totalBytes: 0,
      );
      expect(progress.fraction, closeTo(0.4, 1e-6));
      expect(progress.percent, 40);
      expect(progress.formattedBytes, isNull);
    });

    test('formatBytes formats B, KB, and MB accurately', () {
      expect(SyncProgress.formatBytes(512), '512 B');
      expect(SyncProgress.formatBytes(2048), '2 KB');
      expect(SyncProgress.formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('SyncByteTracker', () {
    test('tracks per-file chunks, skipped full credit, and retry resets without exceeding 100%', () {
      final tracker = SyncByteTracker({
        'a.json': 200,
        'b.gpkg': 500,
        'c.gpkg': 300,
      });

      // File 1: skipped (unchanged) -> full 200 bytes credited immediately
      tracker.markCompleted('a.json', fileName: 'a.json');
      expect(tracker.completedFiles, 1);
      expect(tracker.transferredBytes, 200);

      // File 2: downloads 300 bytes, fails mid-way, resets, then downloads 500 bytes
      tracker.addChunk('b.gpkg', 300, fileName: 'b.gpkg');
      expect(tracker.transferredBytes, 500);

      tracker.resetFile('b.gpkg');
      expect(tracker.transferredBytes, 200);

      tracker.addChunk('b.gpkg', 500, fileName: 'b.gpkg');
      tracker.markCompleted('b.gpkg', fileName: 'b.gpkg');
      expect(tracker.completedFiles, 2);
      expect(tracker.transferredBytes, 700);

      // File 3: streams 300 bytes
      tracker.addChunk('c.gpkg', 300, fileName: 'c.gpkg');
      tracker.markCompleted('c.gpkg', fileName: 'c.gpkg');
      expect(tracker.completedFiles, 3);
      expect(tracker.transferredBytes, 1000);

      final snap = tracker.snapshot();
      expect(snap.fraction, 1.0);
      expect(snap.percent, 100);
      expect(snap.currentFileName, 'c.gpkg');
    });
  });

  group('ProgressThrottler', () {
    test('throttles rapid transferring updates but bypasses on phase change and 100%', () {
      final emitted = <SyncProgress>[];
      final throttler = ProgressThrottler(
        emitted.add,
        minInterval: const Duration(milliseconds: 200),
      );
      final t0 = DateTime(2026, 10, 25, 12, 0, 0);

      // 1. Scanning phase emitted immediately
      throttler.add(const SyncProgress(phase: SyncPhase.scanning), now: t0);
      expect(emitted.length, 1);

      // 2. Phase transition to transferring emitted immediately
      throttler.add(
        const SyncProgress(
          phase: SyncPhase.transferring,
          completedFiles: 0,
          totalFiles: 2,
          transferredBytes: 10,
          totalBytes: 100,
        ),
        now: t0.add(const Duration(milliseconds: 10)),
      );
      expect(emitted.length, 2);

      // 3. Rapid intermediate transferring update within interval is throttled
      throttler.add(
        const SyncProgress(
          phase: SyncPhase.transferring,
          completedFiles: 1,
          totalFiles: 2,
          transferredBytes: 50,
          totalBytes: 100,
        ),
        now: t0.add(const Duration(milliseconds: 50)),
      );
      expect(emitted.length, 2);

      // 4. 100% completion bypasses throttle
      throttler.add(
        const SyncProgress(
          phase: SyncPhase.transferring,
          completedFiles: 2,
          totalFiles: 2,
          transferredBytes: 100,
          totalBytes: 100,
        ),
        now: t0.add(const Duration(milliseconds: 80)),
      );
      expect(emitted.length, 3);

      // 5. Phase transition to finalizing bypasses throttle
      throttler.add(
        const SyncProgress(
          phase: SyncPhase.finalizing,
          completedFiles: 2,
          totalFiles: 2,
          transferredBytes: 100,
          totalBytes: 100,
        ),
        now: t0.add(const Duration(milliseconds: 90)),
      );
      expect(emitted.length, 4);
    });
  });
}
