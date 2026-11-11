// LatLng ↔ geobase 変換（地図に流す GeoJSON の素・DB 行との相互変換）の純粋関数を検査する
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/feature_row.dart';
import 'package:root_maps/utils/geo_converter.dart';

void main() {
  final line = createGeoLineString(const [LatLng(34, 135), LatLng(35, 136)]);
  final multiLine = createGeoMultiLineString(const [
    [LatLng(34, 135), LatLng(35, 136)],
    [LatLng(36, 137), LatLng(37, 138), LatLng(38, 139)],
  ]);
  // 閉じたリング（先頭と末尾が同じ）
  const square = [
    LatLng(0, 0),
    LatLng(0, 1),
    LatLng(1, 1),
    LatLng(1, 0),
    LatLng(0, 0),
  ];
  const hole = [
    LatLng(0.2, 0.2),
    LatLng(0.2, 0.4),
    LatLng(0.4, 0.4),
    LatLng(0.4, 0.2),
    LatLng(0.2, 0.2),
  ];
  final polygon = createGeoPolygon(const [square, hole]);
  final multiPolygon = createGeoMultiPolygon(const [
    [square],
    [
      [LatLng(5, 5), LatLng(5, 6), LatLng(6, 6), LatLng(5, 5)],
    ],
  ]);
  final point = createGeoPoint(const LatLng(2, 1));

  group('PositionSeries と基本変換', () {
    test('LatLng と Geographic の相互変換は経度=x, 緯度=y を保つ', () {
      const p = LatLng(35.6895, 139.6917);
      final g = p.toGeographic();
      expect(g.lon, 139.6917);
      expect(g.lat, 35.6895);
      expect(g.toLatLng(), p);
    });

    test('createGeoLine は 1 点の退化線でも assert せず保持する', () {
      final single = createGeoLine(const [LatLng(34, 135)]);
      expect(single, isA<geo.MultiLineString>());
      expect(geoMultiLineToLatLngs(single as geo.MultiLineString).single, const [LatLng(34, 135)]);

      final empty = createGeoLine(const []);
      expect(empty, isA<geo.LineString>());
      expect(geoLineToLatLngs(empty as geo.LineString), isEmpty);
    });
  });

  group('asGeoLine', () {
    test('LineString / MultiLineString は再確保せずそのまま返す', () {
      expect(identical(asGeoLine(line), line), isTrue);
      expect(identical(asGeoLine(multiLine), multiLine), isTrue);
      expect(line.chain.positionCount, 2);
      expect(line.chain.x(0), 135);
      expect(line.chain.y(0), 34);
      expect(line.chain.x(1), 136);
      expect(multiLine.chains.length, 2);
      expect(multiLine.chains[1].positionCount, 3);
    });

    test('ライン以外は null', () {
      expect(asGeoLine(polygon), isNull);
      expect(asGeoLine(point), isNull);
      expect(asGeoLine(null), isNull);
    });
  });

  group('asGeoPolygon', () {
    test('Polygon / MultiPolygon は外周と穴を保ってそのまま返す', () {
      expect(identical(asGeoPolygon(polygon), polygon), isTrue);
      expect(identical(asGeoPolygon(multiPolygon), multiPolygon), isTrue);
      expect(polygon.rings.length, 2);
      expect(polygon.exterior!.positionCount, 5);
      expect(polygon.rings[1].x(0), 0.2);
      expect(multiPolygon.ringArrays.length, 2);
      expect(multiPolygon.ringArrays[1][0].positionCount, 4);
    });

    test('ポリゴン以外は null', () {
      expect(asGeoPolygon(line), isNull);
      expect(asGeoPolygon(null), isNull);
    });
  });

  group('頂点の抽出', () {
    test('ラインは全パートの頂点を連結する', () {
      expect(geoLineVertices(line).length, 2);
      expect(geoLineVertices(multiLine).length, 5);
      expect(geoLineVertices(polygon), isEmpty);
    });

    test('ポリゴンは各リングの閉じ点を除く', () {
      // 外周 4 + 穴 4
      expect(geoPolygonVertices(polygon).length, 8);
      // 4 + 3
      expect(geoPolygonVertices(multiPolygon).length, 7);
      expect(geoPolygonVertices(line), isEmpty);
    });

    test('閉じていないリングはそのまま数える', () {
      final open = createGeoPolygon(const [
        [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1)],
      ]);
      expect(geoPolygonVertices(open).length, 3);
    });
  });

  group('createGeoFeatureFromRow / propertiesToRowData', () {
    test('MultiPoint を含む各ジオメトリ型と属性の往復', () {
      final mpFeature = createGeoFeatureFromRow({
        featureIdKey: 10,
        featureGeometryKey: const [LatLng(34, 135), LatLng(35, 136)],
        'name': 'mp',
        'meta': {'a': 1},
      }, 'point')!;
      expect(mpFeature.geometry, isA<geo.MultiPoint>());
      expect((mpFeature.geometry! as geo.MultiPoint).positions.length, 2);
      expect(mpFeature.properties.containsKey(featureIdKey), isFalse);
      expect(mpFeature.properties.containsKey(featureGeometryKey), isFalse);

      final row = propertiesToRowData(mpFeature.properties)!;
      expect(row['name'], 'mp');
      expect(row['meta'], '{"a":1}');
    });
  });
}
