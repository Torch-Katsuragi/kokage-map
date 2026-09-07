// turf → geobase 変換（地図に流す GeoJSON の素）の純粋関数を検査する
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:root_maps/utils/turf_geo_convert.dart';
import 'package:turf/turf.dart' as turf;

turf.Position p(num lng, num lat) => turf.Position(lng, lat);

void main() {
  final line = turf.LineString(coordinates: [p(135, 34), p(136, 35)]);
  final multiLine = turf.MultiLineString(
    coordinates: [
      [p(135, 34), p(136, 35)],
      [p(137, 36), p(138, 37), p(139, 38)],
    ],
  );
  // 閉じたリング（先頭と末尾が同じ）
  final square = [p(0, 0), p(1, 0), p(1, 1), p(0, 1), p(0, 0)];
  final hole = [p(0.2, 0.2), p(0.4, 0.2), p(0.4, 0.4), p(0.2, 0.4), p(0.2, 0.2)];
  final polygon = turf.Polygon(coordinates: [square, hole]);
  final multiPolygon = turf.MultiPolygon(
    coordinates: [
      [square],
      [
        [p(5, 5), p(6, 5), p(6, 6), p(5, 5)],
      ],
    ],
  );
  final point = turf.Point(coordinates: p(1, 2));

  group('turfLineToGeo', () {
    test('LineString は座標順を保って変換される', () {
      final g = turfLineToGeo(line) as geo.LineString;
      expect(g.chain.positionCount, 2);
      expect(g.chain.x(0), 135);
      expect(g.chain.y(0), 34);
      expect(g.chain.x(1), 136);
    });

    test('MultiLineString はパートごとに変換される', () {
      final g = turfLineToGeo(multiLine) as geo.MultiLineString;
      expect(g.chains.length, 2);
      expect(g.chains[1].positionCount, 3);
    });

    test('ライン以外は null', () {
      expect(turfLineToGeo(polygon), isNull);
      expect(turfLineToGeo(point), isNull);
      expect(turfLineToGeo(null), isNull);
    });
  });

  group('turfPolygonToGeo', () {
    test('Polygon は外周と穴を保つ', () {
      final g = turfPolygonToGeo(polygon) as geo.Polygon;
      expect(g.rings.length, 2);
      expect(g.exterior!.positionCount, 5);
      expect(g.rings[1].x(0), 0.2);
    });

    test('MultiPolygon はポリゴンごとに変換される', () {
      final g = turfPolygonToGeo(multiPolygon) as geo.MultiPolygon;
      expect(g.ringArrays.length, 2);
      expect(g.ringArrays[1][0].positionCount, 4);
    });

    test('ポリゴン以外は null', () {
      expect(turfPolygonToGeo(line), isNull);
      expect(turfPolygonToGeo(null), isNull);
    });
  });

  group('頂点の抽出', () {
    test('ラインは全パートの頂点を連結する', () {
      expect(turfLineVertices(line).length, 2);
      expect(turfLineVertices(multiLine).length, 5);
      expect(turfLineVertices(polygon), isEmpty);
    });

    test('ポリゴンは各リングの閉じ点を除く', () {
      // 外周 4 + 穴 4
      expect(turfPolygonVertices(polygon).length, 8);
      // 4 + 3
      expect(turfPolygonVertices(multiPolygon).length, 7);
      expect(turfPolygonVertices(line), isEmpty);
    });

    test('閉じていないリングはそのまま数える', () {
      final open = turf.Polygon(coordinates: [
        [p(0, 0), p(1, 0), p(1, 1)],
      ]);
      expect(turfPolygonVertices(open).length, 3);
    });
  });
}
