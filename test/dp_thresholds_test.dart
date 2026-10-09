import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/feature_calc_utils.dart';

void main() {
  test('許容幅 ε で残る点は、閾値が ε より大きい点と一致する（DP と同じ結果）', () {
    final rnd = Random(7);
    for (var trial = 0; trial < 30; trial++) {
      final line = [
        for (var i = 0; i < 5 + rnd.nextInt(60); i++)
          LatLng(34 + i * 0.0002 + rnd.nextDouble() * 0.0003, 135 + rnd.nextDouble() * 0.0005),
      ];
      final th = LineSimplification.douglasPeuckerThresholds(line);
      expect(th.first, double.infinity);
      expect(th.last, double.infinity);
      final finite = th.where((t) => t.isFinite).toList()..sort();
      for (final eps in [0.0, ...finite, ...finite.map((t) => t * 1.0001), 1e9]) {
        final dp = LineSimplification.simplifyLineDouglasPeucker(line, eps);
        final kept = [for (var i = 0; i < line.length; i++) if (th[i] > eps) line[i]];
        expect(dp, kept, reason: 'trial $trial eps $eps');
      }
    }
  });
}
