import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/gpu/part_cache.dart';

void main() {
  test('伸びたぶんだけ足し、1 秒伸びなければ 1 本に上げ直し、古いものは手放す', () {
    final released = <String>[];
    final cache = GpuPartCache<int, String>(released.add);
    final list = [1, 2, 3];
    String pack(List<int> l, int from) => '${l.sublist(from)}';

    var (parts, took) = cache.partsFor(list, 0, pack);
    expect(parts.parts, ['[1, 2, 3]']);
    expect(took, isNotNull);

    list.addAll([4, 5]);
    (parts, took) = cache.partsFor(list, 100, pack);
    expect(parts.parts, ['[1, 2, 3]', '[4, 5]']);

    // 伸びていない・1 秒たっていない → そのまま
    (parts, took) = cache.partsFor(list, 500, pack);
    expect(took, isNull);
    expect(parts.parts, hasLength(2));

    // 1 秒たった → 1 本に。古い 2 本は手放す
    (parts, took) = cache.partsFor(list, 1200, pack);
    expect(parts.parts, ['[1, 2, 3, 4, 5]']);
    expect(released, ['[1, 2, 3]', '[4, 5]']);

    // 同じ中身でも別のリストは別のキー
    cache.partsFor([1, 2, 3, 4, 5], 1200, pack);
    expect(cache.length, 2);

    cache.sweep(1200 + 3001, 3000);
    expect(cache.length, 0);
    expect(released, hasLength(4));
  });

  group('BumpRingPlanner', () {
    test('ブロック境界を跨ぐ書き込み（aligned < blockSize < aligned + length）で新ブロックへ切り替え、範囲外にならない', () {
      // 上流 flutter_gpu.HostBuffer で例外になっていた境界条件の再現:
      // GeoTIFF 選択枠や高ズーム TruPulse 測線で 1 フレーム合計が 64KB を跨ぐケース
      const blockSize = 64 * 1024;
      final planner = BumpRingPlanner(frameCount: 4, blockLengthInBytes: blockSize, alignment: 256);

      planner.reset();
      // まずタイル uniform 相当（20回 × 80B → 256B アライメントで 20 × 256 = 5120B 付近）
      for (var i = 0; i < 20; i++) {
        final a = planner.allocate(80);
        expect(a.blockIndex, 0);
        expect(a.offsetInBytes % 256, 0);
        expect(a.offsetInBytes + 80, lessThanOrEqualTo(blockSize));
      }

      // 続けて中規模チャンク（各 24,000B ≤ 64KB）を 3 回入れる。3 回目で 64KB を跨ぐ
      final a1 = planner.allocate(24000);
      expect(a1.blockIndex, 0);
      expect(a1.offsetInBytes + 24000, lessThanOrEqualTo(blockSize));

      final a2 = planner.allocate(24000);
      expect(a2.blockIndex, 0);
      expect(a2.offsetInBytes + 24000, lessThanOrEqualTo(blockSize));

      // ここで aligned < 65536 かつ aligned + 24000 > 65536 → ブロック 1 の先頭へ移る
      final a3 = planner.allocate(24000);
      expect(a3.blockIndex, 1);
      expect(a3.offsetInBytes, 0);
      expect(a3.newBlockSize, blockSize);

      final active = planner.activeBlocks().toList();
      expect(active, hasLength(2));
      for (final (idx, used) in active) {
        expect(used, greaterThan(0));
        expect(used, lessThanOrEqualTo(planner.blockSizesForFrame(planner.currentFrame)[idx]));
      }
    });

    test('frameCount 周回後に既存ブロックを再利用し、ブロック配列が増殖しない', () {
      const blockSize = 1024;
      final planner = BumpRingPlanner(frameCount: 4, blockLengthInBytes: blockSize, alignment: 64);

      // 1 周目（4 フレーム）で各フレーム 2 ブロックずつ確保させる
      for (var f = 0; f < 4; f++) {
        planner.reset();
        expect(planner.allocate(700).newBlockSize, blockSize);
        expect(planner.allocate(700).newBlockSize, blockSize);
        expect(planner.blockSizesForFrame(planner.currentFrame), [blockSize, blockSize]);
      }

      // 2 周目以降は既存ブロックを再利用し、新規確保（newBlockSize != null）が発生しない
      for (var f = 0; f < 8; f++) {
        planner.reset();
        final first = planner.allocate(700);
        final second = planner.allocate(700);
        expect(first.newBlockSize, isNull);
        expect(second.newBlockSize, isNull);
        expect(first.blockIndex, 0);
        expect(second.blockIndex, 1);
        expect(planner.blockSizesForFrame(planner.currentFrame), [blockSize, blockSize]);
      }
    });

    test('単体で blockLengthInBytes を超える要求と、ちょうどブロック末尾に収まる要求を正しく扱う', () {
      const blockSize = 1024;
      final planner = BumpRingPlanner(frameCount: 2, blockLengthInBytes: blockSize, alignment: 256);

      planner.reset();
      // ちょうど 1024B ぴったりの確保 → 次の確保はブロック 1 へ移る
      final exact = planner.allocate(1024);
      expect(exact.blockIndex, 0);
      expect(exact.offsetInBytes, 0);
      expect(exact.newBlockSize, 1024);

      final next = planner.allocate(64);
      expect(next.blockIndex, 1);
      expect(next.offsetInBytes, 0);
      expect(next.newBlockSize, 1024);

      // ブロック長を超える 5000B の確保 → ブロック 2 に 5000B で確保される
      final huge = planner.allocate(5000);
      expect(huge.blockIndex, 2);
      expect(huge.offsetInBytes, 0);
      expect(huge.newBlockSize, 5000);

      // その後さらに 64B → 5000B ブロックの末尾を超えるのでブロック 3 へ
      final afterHuge = planner.allocate(64);
      expect(afterHuge.blockIndex, 3);
      expect(afterHuge.offsetInBytes, 0);
      expect(afterHuge.newBlockSize, 1024);
    });
  });
}
