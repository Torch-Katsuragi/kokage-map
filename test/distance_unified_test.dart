// 利用者に見せる距離は Geodesic（WGS84 楕円体、QGIS と同じ Karney 法）で測る。
// 参照値は pyproj の Geod(ellps='WGS84').inv
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/gnss_quality.dart';
import 'package:root_maps/utils/geodesic.dart';

void main() {
  test('Geodesic.distance: 対蹠点の近くでも落ちず、QGIS と同じ値', () {
    expect(Geodesic.distance(const LatLng(0, 0), const LatLng(0, 179.8)), closeTo(20000239.43772467, 0.001));
    expect(Geodesic.distance(const LatLng(34, 136), const LatLng(34.0001, 136)), closeTo(11.09223868892756, 1e-6));
  });

  test('緯度・経度 1° の長さは楕円体の上で（北緯 34°）', () {
    expect(Geodesic.metersPerDegreeLat(34) * 0.0001, closeTo(11.09223868892756, 1e-6));
    expect(Geodesic.metersPerDegreeLon(34) * 0.0001, closeTo(9.23847861084627, 1e-6));
  });

  test('GNSS のばらつき: 2 点なら中心からの距離は半分ずつ（北緯 34°）', () {
    const north = [
      GnssSample(latitude: 34, longitude: 136),
      GnssSample(latitude: 34.0001, longitude: 136),
    ];
    expect(GnssQuality.horizontalSpread(north), closeTo(11.09223868892756 / 2, 1e-4));
    const east = [
      GnssSample(latitude: 34, longitude: 136),
      GnssSample(latitude: 34, longitude: 136.0001),
    ];
    expect(GnssQuality.horizontalSpread(east), closeTo(9.23847861084627 / 2, 1e-4));
  });
}
