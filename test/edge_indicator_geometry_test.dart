import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/utils/edge_indicator_geometry.dart';

void main() {
  const viewport = Size(400, 800);

  group('computeEdgeIndicator', () {
    test('ターゲットが画面内なら null', () {
      expect(computeEdgeIndicator(viewport, const Offset(200, 400)), isNull);
      expect(computeEdgeIndicator(viewport, const Offset(0, 0)), isNull);
      // Rect.contains は右下の縁を含まないので、少し内側で見る
      expect(computeEdgeIndicator(viewport, const Offset(399.9, 799.9)), isNull);
    });

    test('visibleMargin の内側（マーカーが一部見えている）なら null', () {
      expect(
        computeEdgeIndicator(viewport, const Offset(420, 400), visibleMargin: 32),
        isNull,
      );
      expect(
        computeEdgeIndicator(viewport, const Offset(440, 400), visibleMargin: 32),
        isNotNull,
      );
    });

    test('右方向のターゲット → 右端・0°', () {
      final p = computeEdgeIndicator(viewport, const Offset(2000, 400), inset: 28)!;
      expect(p.position.dx, closeTo(400 - 28, 1e-6));
      expect(p.position.dy, closeTo(400, 1e-6));
      expect(p.angle, closeTo(0, 1e-9));
    });

    test('上方向のターゲット → 上端・-90°', () {
      final p = computeEdgeIndicator(viewport, const Offset(200, -5000), inset: 28)!;
      expect(p.position.dx, closeTo(200, 1e-6));
      expect(p.position.dy, closeTo(28, 1e-6));
      expect(p.angle, closeTo(-math.pi / 2, 1e-9));
    });

    test('斜め方向は矩形の縁に乗る（矩形の外に出ない）', () {
      final p = computeEdgeIndicator(viewport, const Offset(3000, 3000), inset: 28)!;
      // 中心(200,400)から(3000,3000)方向: dx=2800, dy=2600 → 横のほうが先に縁に届く
      expect(p.position.dx, closeTo(400 - 28, 1e-6));
      expect(p.position.dy, lessThan(800 - 28 + 1e-6));
      expect(p.position.dy, greaterThan(400));
      expect(p.angle, closeTo(math.atan2(2600, 2800), 1e-9));
    });

    test('無限遠でも向きが出る', () {
      final p = computeEdgeIndicator(viewport, const Offset(1e12, -1e12))!;
      expect(p.position.dx.isFinite, isTrue);
      expect(p.position.dy.isFinite, isTrue);
      expect(p.angle, closeTo(-math.pi / 4, 1e-6));
    });

    test('NaN / Infinity は null', () {
      expect(computeEdgeIndicator(viewport, const Offset(double.nan, 0)), isNull);
      expect(
        computeEdgeIndicator(viewport, const Offset(double.infinity, 0)),
        isNull,
      );
    });

    test('obscured（右にドロワー）があると見える範囲の縁に置かれる', () {
      // 右 150px がドロワーで隠れている
      const obscured = EdgeInsets.only(right: 150);
      // ドロワーの下に居る点は「見えていない」扱い → 矢印が出る
      final p = computeEdgeIndicator(
        viewport,
        const Offset(330, 400),
        inset: 28,
        obscured: obscured,
      )!;
      expect(p.position.dx, closeTo(400 - 150 - 28, 1e-6));
      expect(p.angle, closeTo(0, 1e-9));

      // 見える範囲の中心は (125, 400)
      final up = computeEdgeIndicator(
        viewport,
        const Offset(125, -100),
        inset: 28,
        obscured: obscured,
      )!;
      expect(up.position.dx, closeTo(125, 1e-6));
      expect(up.position.dy, closeTo(28, 1e-6));
    });

    test('見える範囲が潰れていれば null', () {
      expect(
        computeEdgeIndicator(
          const Size(40, 40),
          const Offset(500, 500),
          inset: 28,
        ),
        isNull,
      );
      expect(
        computeEdgeIndicator(
          viewport,
          const Offset(500, 500),
          obscured: const EdgeInsets.only(right: 500),
        ),
        isNull,
      );
    });
  });
}
