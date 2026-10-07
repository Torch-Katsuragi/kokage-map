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
}
