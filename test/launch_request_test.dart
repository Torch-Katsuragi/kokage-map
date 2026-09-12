// 起動要求（`/map?...`）の読み書き
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/launch_request.dart';

void main() {
  test('ルート・ハッシュ・URL 全体のどれからでも読める', () {
    final a = LaunchRequest.tryParse('/map?project=/sdcard/FieldSurvey/K&lat=33.9&lon=135.57&zoom=15&bearing=30&pitch=45&reload=1')!;
    expect(a.project, '/sdcard/FieldSurvey/K');
    expect(a.lat, 33.9);
    expect(a.lon, 135.57);
    expect(a.zoom, 15);
    expect(a.bearing, 30);
    expect(a.pitch, 45);
    expect(a.reload, isTrue);
    expect(a.hasCamera, isTrue);

    final b = LaunchRequest.tryParse('#/map?lat=1&lng=2&z=3')!;
    expect(b.center?.latitude, 1);
    expect(b.center?.longitude, 2);
    expect(b.zoom, 3);
    expect(b.project, isNull);

    final c = LaunchRequest.tryParse('https://kokage-map.sleeptree.jp/?room=ABCD#/map?zoom=12')!;
    expect(c.zoom, 12);
    expect(c.hasCenter, isFalse);
  });

  test('/map 以外は null、素の /map は空の要求', () {
    expect(LaunchRequest.tryParse('/'), isNull);
    expect(LaunchRequest.tryParse('/terrain-spike'), isNull);
    expect(LaunchRequest.tryParse('/mapfoo?lat=1'), isNull);
    expect(LaunchRequest.tryParse(null), isNull);
    final plain = LaunchRequest.tryParse('/map')!;
    expect(plain.isEmpty, isTrue);
  });

  test('toRoute は往復する（パスの空白や日本語もそのまま）', () {
    const req = LaunchRequest(project: '/sdcard/現場 A/森', lat: 33.9, lon: 135.5, zoom: 14.5, reload: true);
    final back = LaunchRequest.tryParse(req.toRoute())!;
    expect(back.project, req.project);
    expect(back.lat, 33.9);
    expect(back.zoom, 14.5);
    expect(back.reload, isTrue);
    expect(const LaunchRequest().toRoute(), '/map');
  });

  test('起動時の要求は 1 回だけ取り出せる', () {
    LaunchRequest.setPendingForTest(const LaunchRequest(zoom: 10));
    expect(LaunchRequest.pending?.zoom, 10);
    expect(LaunchRequest.consumePending()?.zoom, 10);
    expect(LaunchRequest.consumePending(), isNull);
  });
}
