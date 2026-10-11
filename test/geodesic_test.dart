// 楕円体の上の長さ・面積（参照値は pyproj の Geod(ellps='WGS84')。GeographicLib の Karney 法）
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/geodesic.dart';
import 'package:turf/turf.dart' as turf;

void main() {
  // 北山村あたりの 65 ha ほどの林班風の面
  const lons = [135.9650, 135.9712, 135.9748, 135.9731, 135.9668, 135.9641];
  const lats = [33.9290, 33.9302, 33.9271, 33.9228, 33.9219, 33.9256];
  final ring = [for (var i = 0; i < lons.length; i++) LatLng(lats[i], lons[i])];
  const hole = [
    LatLng(33.9250, 135.9680),
    LatLng(33.9250, 135.9700),
    LatLng(33.9265, 135.9700),
    LatLng(33.9265, 135.9680),
  ];

  void near(double actual, double expected, double relTol) {
    expect((actual - expected).abs() / expected, lessThan(relTol), reason: 'actual=$actual expected=$expected');
  }

  test('面積は参照値と 0.5% 以内（実際は 0.01% 以内）', () {
    near(Geodesic.ringArea(ring), 655222.7235953212, 0.0001);
    near(Geodesic.ringArea(hole), 30768.97325861454, 0.0001);
  });

  test('向き・閉じ方によらない', () {
    final closed = [...ring, ring.first];
    expect(Geodesic.ringArea(ring.reversed.toList()), closeTo(Geodesic.ringArea(ring), 1e-6));
    expect(Geodesic.ringArea(closed), closeTo(Geodesic.ringArea(ring), 1e-6));
  });

  test('穴を引く・周は穴も足す', () {
    near(Geodesic.polygonArea([ring, hole]), 655222.7235953212 - 30768.97325861454, 0.0001);
    near(Geodesic.polygonPerimeter([ring]), 3026.9081241840213, 0.00001);
    near(Geodesic.polygonPerimeter([ring, hole]), 3026.9081241840213 + 702.6234951643169, 0.00001);
  });

  test('長さ（短い折れ線・長い測地線）', () {
    near(Geodesic.lineLength(ring), 2640.7043402025693, 0.00001);
    near(Geodesic.distance(const LatLng(33.0, 135.0), const LatLng(34.5, 136.0)), 190433.47423649824, 0.000001);
    expect(Geodesic.distance(const LatLng(34, 136), const LatLng(34, 136)), 0);
  });

  test('turf の形（Multi は合計）', () {
    turf.Position pos(LatLng p) => turf.Position(p.longitude, p.latitude);
    final poly = turf.Polygon(coordinates: [
      [for (final p in [...ring, ring.first]) pos(p)],
    ]);
    final multi = turf.MultiPolygon(coordinates: [poly.coordinates, poly.coordinates]);
    near(Geodesic.areaOf(poly)!, 655222.7235953212, 0.0001);
    near(Geodesic.areaOf(multi)!, 2 * 655222.7235953212, 0.0001);
    near(Geodesic.perimeterOf(poly)!, 3026.9081241840213, 0.00001);
    final line = turf.LineString(coordinates: [for (final p in ring) pos(p)]);
    near(Geodesic.lengthOf(line)!, 2640.7043402025693, 0.00001);
    expect(Geodesic.areaOf(line), isNull);
    expect(Geodesic.lengthOf(poly), isNull);
  });

  test('表示', () {
    expect(Geodesic.formatLength(12.34), '12.3 m');
    expect(Geodesic.formatLength(1234.6), '1,234.6 m（1.235 km）');
    expect(Geodesic.formatArea(12345.6), '12,345.6 m²（1.2346 ha）');
    expect(Geodesic.formatLengthShort(12.34), '12.3 m');
    expect(Geodesic.formatLengthShort(1234.6), '1.23 km');
    expect(Geodesic.formatArea(5), '5.0 m²（0.0005 ha）');
  });
}
