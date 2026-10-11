// GPS 軌跡の GPX 1.1 書き出し（QGIS で開ける形: trk / trkseg / trkpt、時刻・標高つき）
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/gps_track.dart';
import 'package:root_maps/utils/gpx_writer.dart';
import 'package:xml/xml.dart';

GpsTrackPoint _pt(double lat, double lon, DateTime time, {double? ele}) =>
    GpsTrackPoint(latitude: lat, longitude: lon, altitude: ele, timestamp: time, sourceType: 'GPS');

void main() {
  final t0 = DateTime.utc(2026, 10, 12, 0, 30, 5, 250);

  test('GPX 1.1 の trk / trkseg / trkpt に、時刻（UTC）と標高を書く', () {
    final gpx = buildTrackGpx([
      [
        _pt(34.12345678, 135.98765432, t0, ele: 412.345),
        _pt(34.1235, 135.9877, t0.add(const Duration(seconds: 1))),
      ],
    ], name: 'GPS軌跡 2026/10/12');

    final doc = XmlDocument.parse(gpx);
    final root = doc.rootElement;
    expect(root.name.local, 'gpx');
    expect(root.getAttribute('version'), '1.1');
    expect(root.name.namespaceUri, 'http://www.topografix.com/GPX/1/1');

    final trk = root.findElements('trk').single;
    expect(trk.findElements('name').single.innerText, 'GPS軌跡 2026/10/12');
    final pts = trk.findElements('trkseg').single.findElements('trkpt').toList();
    expect(pts, hasLength(2));
    expect(pts[0].getAttribute('lat'), '34.12345678');
    expect(pts[0].getAttribute('lon'), '135.98765432');
    expect(pts[0].findElements('ele').single.innerText, '412.35');
    expect(pts[0].findElements('time').single.innerText, '2026-10-12T00:30:05Z');
    // 子要素の順は ele → time（スキーマの順）
    expect(pts[0].childElements.map((e) => e.name.local).toList(), ['ele', 'time']);
    expect(pts[1].findElements('ele'), isEmpty, reason: '標高の無い点は ele を省く');
  });

  test('地方時の時刻も UTC にする', () {
    final local = DateTime(2026, 10, 12, 9, 0, 0);
    final gpx = buildTrackGpx([
      [_pt(34, 135, local)],
    ], name: 'x');
    final time = XmlDocument.parse(gpx).findAllElements('trkpt').single.findElements('time').single.innerText;
    expect(DateTime.parse(time), local.toUtc());
    expect(time.endsWith('Z'), isTrue);
  });

  test('区間ごとに trkseg。空の区間は書かない。名前は XML として逃がす', () {
    final gpx = buildTrackGpx([
      [_pt(34, 135, t0)],
      [],
      [_pt(34.1, 135.1, t0.add(const Duration(minutes: 20)))],
    ], name: 'A & <B>');
    final doc = XmlDocument.parse(gpx);
    expect(doc.findAllElements('trkseg'), hasLength(2));
    expect(doc.findAllElements('trk').single.findElements('name').single.innerText, 'A & <B>');
    expect(doc.findAllElements('metadata').single.findElements('time').single.innerText, '2026-10-12T00:30:05Z');
  });
}
