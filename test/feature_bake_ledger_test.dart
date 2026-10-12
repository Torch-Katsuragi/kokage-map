// フィーチャの焼き込みの台帳（2026-10-12）。
// 地図を置いたままで GPS 軌跡の統合のたびに 6 枚焼き直していた。変化の掛からないタイル・中身の変わらないとき・
// 線だけの変化での寄った段（塗りしか焼かない）・1 texel に届かない線の伸び（GPS の揺れ）は焼き直さない
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
    expect(l.withdrawUnapplied(stale, gen, (_) => true), 1);
    expect(l.takeStale([low, high, far]), {low});
  });

  group('1 texel に届かない線の伸び', () {
    // z12 のテクスチャは 512²（1 texel ≒ 19 m）
    final texel = low.span / 512;
    Rect jitter(double size) => Rect.fromCenter(center: low.bounds.center, width: size, height: size);
    void bake(FeatureBakeLedger l, Set<TileKey> ks) {
      for (final k in ks) {
        l
          ..composed(k)
          ..applied(k);
      }
    }

    test('対角で 1 texel に届かなければ見送る。届けば焼く', () {
      expect(FeatureBakeLedger.subTexel(jitter(texel * 0.5), texel), isTrue);
      expect(FeatureBakeLedger.subTexel(jitter(texel * 0.8), texel), isFalse, reason: '対角 0.8√2 ≒ 1.13 texel');
      expect(FeatureBakeLedger.subTexel(Rect.fromLTRB(0, 1, texel * 0.9, 0), texel), isTrue, reason: '上下が逆でも幅で見る');
    });

    test('GPS の揺れ数 m は焼き直さず、見送った数を数える', () {
      final l = bakedLedger();
      final r = jitter(3);
      l.addEvent(r.inflate(50), fills: false, extension: r);
      expect(l.takeStale([low, high, far]), isEmpty);
      expect(l.lastDeferred, 1);
      expect(l.pending[low]?.$1, r);
      expect(l.baked[low], l.gen, reason: '同じ出来事を何度も数えない');
      expect(l.takeStale([low, high, far]), isEmpty);
    });

    test('貯まった範囲が 1 texel を超えたら焼き、貼れば貯めは消える', () {
      final l = bakedLedger();
      final c = low.bounds.center;
      // 歩いて 4 m ずつ東へ: 1 texel（約 19 m）に届くまでは見送る
      var x = c.dx;
      var baked = 0;
      for (var i = 0; i < 10; i++) {
        final r = Rect.fromLTRB(x, c.dy, x + 4, c.dy + 1);
        x += 4;
        l.addEvent(r.inflate(50), fills: false, extension: r);
        final stale = l.takeStale([low, high, far]);
        if (stale.isNotEmpty) {
          expect(stale, {low});
          expect(x - c.dx, greaterThanOrEqualTo(texel), reason: '貯めた分が 1 texel を超えてから');
          bake(l, stale);
          expect(l.pending.containsKey(low), isFalse);
          baked++;
        }
      }
      expect(baked, 2, reason: '40 m 歩けば約 19 m ごとに 1 回ずつ');
    });

    test('見送っている間に描いた・消した・スタイルを変えたら必ず焼く', () {
      final l = bakedLedger();
      final r = jitter(3);
      l.addEvent(r.inflate(50), fills: false, extension: r);
      expect(l.takeStale([low, high, far]), isEmpty);
      // 同じ小さな範囲でも「伸ばしただけ」でなければ焼く（新しい点・短い線は太さぶん見える）
      l.addEvent(r.inflate(50), fills: false);
      expect(l.takeStale([low, high, far]), {low});
      final l2 = bakedLedger()..addEvent(r.inflate(50), extension: r);
      expect(l2.takeStale([low, high, far]), {low, high}, reason: '面の塗りが変わったら伸ばしただけ扱いにしない');
    });

    test('描いてから貼るまでに見送った分は、その絵を貼っても消さない', () {
      final l = bakedLedger();
      l.composed(low); // 別の作り直し（オーバーレイなど）で描いた（まだ貼っていない）
      final r = jitter(3);
      l.addEvent(r.inflate(50), fills: false, extension: r);
      expect(l.takeStale([low, high, far]), isEmpty);
      l.applied(low);
      expect(l.pending.containsKey(low), isTrue, reason: '描いた後の伸びは絵に入っていない');
      // 次に描いて貼れば消える
      l
        ..composed(low)
        ..applied(low);
      expect(l.pending.containsKey(low), isFalse);
    });

    test('粗い段ほど texel が大きいので見送り、細かい段は焼く', () {
      // 同じ 30 m の伸び: z12（19 m）は焼く、z8（約 300 m）は見送る
      const coarse = TileKey(8, 3600 >> 4, 1620 >> 4);
      final l = FeatureBakeLedger(fillsOnlyAbove: 13)..addEvent(null);
      bake(l, l.takeStale([low, coarse]));
      final r = Rect.fromCenter(center: low.bounds.center, width: 30, height: 1);
      l.addEvent(r.inflate(50), fills: false, extension: r);
      expect(l.takeStale([low, coarse]), {low});
      expect(l.lastDeferred, 1);
      expect(l.pending.containsKey(coarse), isTrue);
    });
  });
}
