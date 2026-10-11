// GeoPackage のジオメトリ blob（GP ヘッダー + WKB）の読み書き。
// QGIS / GDAL が書く形（範囲の種類 XYZ・XYM・XYZM、big endian の WKB、Z 付き）を読めること
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/geo_converter.dart';
import 'package:root_maps/utils/wkb_utils.dart';

/// GP ヘッダー（little endian、範囲の種類 [envelopeType]、範囲の値は [envelope]）+ [wkb]
Uint8List gpBlob(Uint8List wkb, {int envelopeType = 0, List<double> envelope = const [], int srsId = 4326}) {
  final b = BytesBuilder()
    ..add([0x47, 0x50, 0x00, 0x01 | (envelopeType << 1)])
    ..add((ByteData(4)..setInt32(0, srsId, Endian.little)).buffer.asUint8List());
  for (final v in envelope) {
    b.add((ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List());
  }
  b.add(wkb);
  return b.toBytes();
}

void main() {
  const a = LatLng(33.93, 135.96);
  const b = LatLng(33.94, 135.97);
  const c = LatLng(33.95, 135.96);

  group('書く', () {
    test('ヘッダーは GP・little endian・範囲 XY・srs_id を持つ', () {
      final blob = createGpkgWkb(geo.LineString.from([a.toGeographic(), b.toGeographic()]), srsId: 6674);
      expect(blob.sublist(0, 3), [0x47, 0x50, 0x00]);
      expect(blob[3], 0x01 | (1 << 1));
      expect(ByteData.sublistView(blob, 4, 8).getInt32(0, Endian.little), 6674);
      final env = gpkgEnvelope(blob)!;
      expect([env.minX, env.maxX, env.minY, env.maxY], [135.96, 135.97, 33.93, 33.94]);
    });

    test('点・線・面の簡易版は読み戻すと同じ形', () {
      expect(geobaseGeometryToLatLngs(parseGpkgGeometry(createWkbPoint(a.longitude, a.latitude))!), [a]);
      expect(geobaseGeometryToLatLngs(parseGpkgGeometry(createWkbLineString([a, b, c]))!), [a, b, c]);
      final ring = [a, b, c, a];
      expect(geobaseGeometryToLatLngs(parseGpkgGeometry(createWkbPolygon([ring]))!), [ring]);
    });

    test('空の線・面は空の blob（書かない）', () {
      expect(createWkbLineString(const []), isEmpty);
      expect(createWkbPolygon(const []), isEmpty);
      expect(createWkbPolygon(const [[]]), isEmpty);
    });
  });

  group('読む', () {
    Uint8List wkbOf(geo.Geometry g, {Endian endian = Endian.little}) => g.toBytes(endian: endian);

    for (final (type, n) in [(2, 6), (3, 6), (4, 8)]) {
      test('範囲の種類 $type（${n * 8} バイト）を飛ばして読む', () {
        final pt = geo.Point.build(const [135.96, 33.93, 120.5]);
        final blob = gpBlob(wkbOf(pt), envelopeType: type, envelope: List.filled(n, 0));
        final g = parseGpkgGeometry(blob)! as geo.Point;
        expect(g.position.x, 135.96);
        expect(g.position.y, 33.93);
        expect(g.position.z, 120.5);
      });
    }

    test('範囲の無いヘッダー（GDAL の点）と big endian の WKB', () {
      final pt = geo.Point.build(const [135.96, 33.93]);
      final g = parseGpkgGeometry(gpBlob(wkbOf(pt, endian: Endian.big)))! as geo.Point;
      expect(g.position.x, 135.96);
      expect(g.position.y, 33.93);
    });

    test('ヘッダーの無い素の WKB も読む', () {
      final g = parseGpkgGeometry(wkbOf(geo.Point.build(const [1.0, 2.0])))! as geo.Point;
      expect((g.position.x, g.position.y), (1.0, 2.0));
    });

    test('壊れた blob は null', () {
      expect(parseGpkgGeometry(Uint8List.fromList([0x47, 0x50, 0, 1, 0, 0, 0, 0, 9, 9])), isNull);
      expect(parseGpkgGeometry(Uint8List(0)), isNull);
    });

    test('マルチの形は部分ごとの点列にする', () {
      final ml = geo.MultiLineString.from([
        [a.toGeographic(), b.toGeographic()],
        [b.toGeographic(), c.toGeographic()],
      ]);
      expect(geobaseGeometryToLatLngs(parseGpkgGeometry(createGpkgWkb(ml))!), [
        [a, b],
        [b, c],
      ]);
      final ring = [a, b, c, a];
      final mp = geo.MultiPolygon.from([
        [ring.map((p) => p.toGeographic())],
        [ring.map((p) => p.toGeographic())],
      ]);
      final out = geobaseGeometryToLatLngs(parseGpkgGeometry(createGpkgWkb(mp))!) as List;
      expect(out, hasLength(2));
      expect(out.first, [ring]);
      final mpt = geo.MultiPoint.from([a.toGeographic(), b.toGeographic()]);
      expect(geobaseGeometryToLatLngs(parseGpkgGeometry(createGpkgWkb(mpt))!), [a, b]);
      final env = gpkgEnvelope(createGpkgWkb(mp))!;
      expect([env.minX, env.maxX, env.minY, env.maxY], [135.96, 135.97, 33.93, 33.95]);
    });

    test('範囲が NaN のヘッダーは座標から出し直す', () {
      final line = geo.LineString.from([a.toGeographic(), b.toGeographic()]);
      final blob = gpBlob(wkbOf(line), envelopeType: 1, envelope: [double.nan, double.nan, double.nan, double.nan]);
      final env = gpkgEnvelope(blob)!;
      expect([env.minX, env.maxX, env.minY, env.maxY], [135.96, 135.97, 33.93, 33.94]);
    });
  });

  test('blob の大きさの検査', () {
    expect(validateWkbData(createWkbPoint(135, 34)), isTrue);
    expect(validateWkbData(Uint8List(4)), isFalse);
    expect(validateWkbData(Uint8List.fromList([0x47, 0x50, ...List.filled(20, 0)])), isFalse);
    expect(validateWkbData(Uint8List(21)), isTrue);
  });
}
