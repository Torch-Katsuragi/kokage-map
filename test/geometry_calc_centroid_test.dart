// 面の重心（頂点の平均）: 閉じたリングでも閉じていないリングでも、実在の頂点をすべて数える
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/feature_calc_utils.dart';

void main() {
  // 4 頂点の平均は (1, 1)。最後の頂点を落とすと (2/3, 2/3) になる
  const open = [LatLng(0, 0), LatLng(0, 2), LatLng(2, 2), LatLng(2, 0)];
  final closed = [...open, open.first];

  void expectAt(LatLng c, double lat, double lng) {
    expect(c.latitude, closeTo(lat, 1e-12));
    expect(c.longitude, closeTo(lng, 1e-12));
  }

  test('閉じていないリングでも最後の頂点を落とさない', () {
    expectAt(GeometryCalc.calcPolygonCentroid([open]), 1, 1);
  });

  test('閉じたリングは閉じの点を二重に数えない', () {
    expectAt(GeometryCalc.calcPolygonCentroid([closed]), 1, 1);
  });

  test('穴が閉じていなくても同じ', () {
    const holeOpen = [LatLng(0.5, 0.5), LatLng(0.5, 1.5), LatLng(1.5, 1.5), LatLng(1.5, 0.5)];
    final a = GeometryCalc.calcPolygonCentroid([open, holeOpen]);
    final b = GeometryCalc.calcPolygonCentroid([closed, [...holeOpen, holeOpen.first]]);
    expectAt(a, b.latitude, b.longitude);
  });
}
