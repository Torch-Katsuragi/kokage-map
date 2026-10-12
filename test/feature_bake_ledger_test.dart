// フィーチャの焼き込みの台帳（2026-10-12）。
// 地図を置いたままで GPS 軌跡の統合のたびに 6 枚焼き直していた。変化の掛からないタイル・中身の変わらないとき・
// 線だけの変化での寄った段（塗りしか焼かない）は焼き直さない
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/feature_bake_ledger.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';

void main() {
  // 引いた段 z12 の 1 枚と、その中の寄った段 z15 の 1 枚
  const low = TileKey(12, 3600, 1620);
  const high = TileKey(15, 3600 * 8 + 3, 1620 * 8 + 3);
  const far = TileKey(12, 3610, 1620);

  /// 全部を今の世代で焼いた状態にする（読み込んで貼った）
  FeatureBakeLedger bakedLedger() {
    final l = FeatureBakeLedger(fillsOnlyAbove: 13)..addEvent(null);
    final stale = l.takeStale([low, high, far]);
    expect(stale, {low, high, far}, reason: '最初は全部焼く');
    for (final k in stale) {
      l
        ..composed(k)
        ..applied(k);
    }
    expect(l.takeStale([low, high, far]), isEmpty);
    return l;
  }

  Rect inside(TileKey k) => Rect.fromCenter(center: k.bounds.center, width: k.span / 10, height: k.span / 10);

  test('中身が変わらなければ（出来事なし）何も焼き直さない', () {
    final l = bakedLedger();
    expect(l.takeStale([low, high, far]), isEmpty);
    expect(l.takeStale([low, high, far]), isEmpty);
  });

  test('線だけの変化: 掛かる引いた段だけ焼き直し、寄った段（塗りだけ）と掛からないタイルは焼き直さない', () {
    final l = bakedLedger();
    final before = l.gen;
    l.addEvent(inside(high), fills: false);
    // 寄った段の形の作り直し（シーン）は線も描くので、焼き込みでなければ掛かる扱い
    expect(l.touchedSince(high, before), isTrue);
    expect(l.touchedSince(high, before, forBake: true), isFalse);
    expect(l.takeStale([low, high, far]), {low});
    expect(l.baked[high], l.gen, reason: '掛からないタイルは今の世代で焼けている扱い');
  });

  test('面の変化: 掛かるタイルは段に関わらず焼き直す', () {
    final l = bakedLedger()..addEvent(inside(high));
    expect(l.takeStale([low, high, far]), {low, high});
  });

  test('スタイルの変化（範囲なし）は全部', () {
    final l = bakedLedger()..addEvent(null, fills: false);
    expect(l.takeStale([low, high, far]), {low, high, far});
  });

  test('頼んだ焼き直しが貼られずに打ち切られたら、取り下げてまた頼める', () {
    final l = bakedLedger()..addEvent(inside(low), fills: false);
    final gen = l.gen;
    final stale = l.takeStale([low, high, far]);
    expect(stale, {low});
    expect(l.takeStale([low, high, far]), isEmpty, reason: '頼んだままは二重に頼まない');
    expect(l.withdrawUnapplied(stale, gen, (_) => true), isTrue);
    expect(l.takeStale([low, high, far]), {low});
  });
}
