// こかげマップ: geobase ジオメトリ統合・空間計算網羅テスト
// geo_converter / GeometryCalc / FeatureSearch / Geodesic の変換・境界条件を検証する

import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/feature_row.dart';
import 'package:root_maps/utils/feature_calc_utils.dart';
import 'package:root_maps/utils/geo_converter.dart';
import 'package:root_maps/utils/geodesic.dart';

void main() {
  group('geobase ジオメトリ変換・Row 往復', () {
    test('LatLng ⇄ Geographic 変換', () {
      const latlng = LatLng(35.6895, 139.6917); // 東京都庁
      final pos = latlng.toGeographic();
      expect(pos.lon, equals(139.6917));
      expect(pos.lat, equals(35.6895));

      final convertedBack = pos.toLatLng();
      expect(convertedBack.latitude, equals(latlng.latitude));
      expect(convertedBack.longitude, equals(latlng.longitude));
    });

    test('Point / LineString / Polygon 作成と逆変換', () {
      const pt = LatLng(35.6895, 139.6917);
      final geoPt = createGeoPoint(pt);
      expect(geoPointToLatLng(geoPt), equals(pt));

      const line = [
        LatLng(35.6895, 139.6917),
        LatLng(35.6762, 139.6503),
        LatLng(35.6584, 139.7016),
      ];
      final geoLine = createGeoLineString(line);
      expect(geoLine.chain.positionCount, equals(3));
      expect(geoLineToLatLngs(geoLine), equals(line));

      const polygon = [
        [
          LatLng(35.6895, 139.6917),
          LatLng(35.6762, 139.6917),
          LatLng(35.6762, 139.6503),
          LatLng(35.6895, 139.6503),
          LatLng(35.6895, 139.6917),
        ],
      ];
      final geoPoly = createGeoPolygon(polygon);
      expect(geoPoly.rings.length, equals(1));
      expect(geoPoly.rings[0].positionCount, equals(5));
      expect(geoPolygonToLatLngs(geoPoly), equals(polygon));
    });

    test('Row データからの Feature 生成と属性抽出', () {
      final rowData = <String, dynamic>{
        featureIdKey: 1,
        'name': 'Test Point',
        'description': 'テスト用ポイント',
        featureGeometryKey: const [LatLng(35.6895, 139.6917)],
        'rmaps_metadata': {'test': 'data'},
      };

      final feature = createGeoFeatureFromRow(rowData, 'Point');
      expect(feature, isNotNull);
      expect(feature!.properties['name'], equals('Test Point'));
      expect(feature.properties['description'], equals('テスト用ポイント'));
      expect(feature.geometry, isA<geo.Point>());

      final convertedRowData = propertiesToRowData(feature.properties);
      expect(convertedRowData, isNotNull);
      expect(convertedRowData!['name'], equals('Test Point'));
      expect(convertedRowData['rmaps_metadata'], equals('{"test":"data"}'));
      expect(convertedRowData.containsKey(featureGeometryKey), isFalse);
      expect(convertedRowData.containsKey(featureIdKey), isFalse);
      expect(convertedRowData.containsKey('geometry'), isFalse);
      expect(convertedRowData.containsKey('geom'), isFalse);

      final latlng = geoPointToLatLng(feature.geometry! as geo.Point);
      expect(latlng.latitude, closeTo(35.6895, 1e-6));
      expect(latlng.longitude, closeTo(139.6917, 1e-6));
    });
  });

  group('GeometryCalc 距離・重心・面積・内外判定・当たり判定', () {
    test('calcDistance（Haversine R=6371008.8m）の精度と境界値', () {
      const a = LatLng(35.681236, 139.767125); // 東京駅
      const b = LatLng(35.689487, 139.691706); // 新宿付近
      expect(GeometryCalc.calcDistance(a, a), equals(0.0));
      expect(GeometryCalc.calcDistance(a, b), closeTo(GeometryCalc.calcDistance(b, a), 1e-9));
      // 球面 Haversine (R = 6371008.8 m) の理論値と一致し、WGS84 楕円体距離とも 0.5% 未満
      expect(GeometryCalc.calcDistance(a, b), closeTo(6873.073188, 1e-5));
      final geod = Geodesic.distance(a, b);
      expect((GeometryCalc.calcDistance(a, b) - geod).abs() / geod, lessThan(0.005));
    });

    test('重心計算: 閉じたリング・開いたリング・Multi・空ジオメトリ', () {
      const closedPoly = [
        [
          LatLng(0, 0),
          LatLng(0, 2),
          LatLng(2, 2),
          LatLng(2, 0),
          LatLng(0, 0),
        ],
      ];
      const openPoly = [
        [
          LatLng(0, 0),
          LatLng(0, 2),
          LatLng(2, 2),
          LatLng(2, 0),
        ],
      ];
      final cClosed = GeometryCalc.calcGeoCentroid(createGeoPolygon(closedPoly))!;
      final cOpen = GeometryCalc.calcGeoCentroid(createGeoPolygon(openPoly))!;
      expect(cClosed.latitude, closeTo(1.0, 1e-9));
      expect(cClosed.longitude, closeTo(1.0, 1e-9));
      expect(cOpen.latitude, closeTo(1.0, 1e-9));
      expect(cOpen.longitude, closeTo(1.0, 1e-9));

      expect(GeometryCalc.calcGeoCentroid(createGeoLineString(const [])), isNull);
      expect(GeometryCalc.calcGeoCentroid(null), isNull);
    });

    test('pointInPolygonWithHoles / pointInGeoPolygon: 内外・辺上・頂点・穴・未閉環・壊れた入力', () {
      // 外周 (0,0)-(0,10)-(10,10)-(10,0)、穴 (3,3)-(3,7)-(7,7)-(7,3)
      const outer = [
        LatLng(0, 0),
        LatLng(0, 10),
        LatLng(10, 10),
        LatLng(10, 0),
        LatLng(0, 0),
      ];
      const hole = [
        LatLng(3, 3),
        LatLng(3, 7),
        LatLng(7, 7),
        LatLng(7, 3),
        LatLng(3, 3),
      ];
      const polyWithHole = [outer, hole];
      final geoPolyWithHole = createGeoPolygon(polyWithHole);

      // 外周の内部（穴の外）
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(1, 1), polyWithHole), isTrue);
      expect(GeometryCalc.pointInGeoPolygon(const LatLng(1, 1), geoPolyWithHole), isTrue);

      // 外周の外
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(-1, 5), polyWithHole), isFalse);
      expect(GeometryCalc.pointInGeoPolygon(const LatLng(5, 11), geoPolyWithHole), isFalse);

      // 穴の内部 → ポリゴン外
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(5, 5), polyWithHole), isFalse);
      expect(GeometryCalc.pointInGeoPolygon(const LatLng(5, 5), geoPolyWithHole), isFalse);

      // 外周の辺上・四隅の頂点（水平辺を含む） → true
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(0, 5), polyWithHole), isTrue);
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(5, 0), polyWithHole), isTrue);
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(10, 10), polyWithHole), isTrue);

      // 穴の境界・頂点上 → ポリゴン境界なので true
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(3, 5), polyWithHole), isTrue);
      expect(GeometryCalc.pointInGeoPolygon(const LatLng(7, 7), geoPolyWithHole), isTrue);

      // ひし形の上下左右の尖端頂点（極大・極小頂点）
      const diamond = [
        [LatLng(1, 0), LatLng(0, 1), LatLng(-1, 0), LatLng(0, -1)], // 未閉環でも動く
      ];
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(1, 0), diamond), isTrue);
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(-1, 0), diamond), isTrue);
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(0, 0), diamond), isTrue);
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(0.6, 0.6), diamond), isFalse);

      // 空・3点未満の退化リング
      expect(GeometryCalc.pointInPolygonWithHoles(const LatLng(0, 0), const []), isFalse);
      expect(
        GeometryCalc.pointInPolygonWithHoles(
          const LatLng(0, 0),
          const [
            [LatLng(0, 0), LatLng(1, 1)],
          ],
        ),
        isFalse,
      );
      expect(
        GeometryCalc.pointInPolygonWithHoles(
          const LatLng(0, 0),
          const [
            [LatLng(0, 0), LatLng(1, 1), LatLng(0, 0)],
          ],
        ),
        isFalse,
      );
    });

    test('FeatureSearch.calcPointToFeatureDistance: Multi 系を含む geobase と LatLng リストの一致', () {
      const target = LatLng(35.001, 135.005);
      const line1 = [LatLng(35.0, 135.0), LatLng(35.0, 135.01)];
      const line2 = [LatLng(36.0, 136.0), LatLng(36.0, 136.01)];

      final dLatLng = FeatureSearch.calcPointToFeatureDistance(target, line1, 'line');
      final dGeo = FeatureSearch.calcPointToFeatureDistance(target, createGeoLineString(line1), 'line');
      final dMulti = FeatureSearch.calcPointToFeatureDistance(
        target,
        createGeoMultiLineString(const [line2, line1]),
        'line',
      );
      expect(dGeo, closeTo(dLatLng, 1e-9));
      expect(dMulti, closeTo(dLatLng, 1e-9));

      // MultiPolygon の 2 個目のパート内部なら距離 0
      final mp = createGeoMultiPolygon(const [
        [
          [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1), LatLng(1, 0), LatLng(0, 0)],
        ],
        [
          [LatLng(10, 10), LatLng(10, 11), LatLng(11, 11), LatLng(11, 10), LatLng(10, 10)],
        ],
      ]);
      expect(FeatureSearch.calcPointToFeatureDistance(const LatLng(10.5, 10.5), mp, 'polygon'), 0.0);

      // MultiPoint の最近傍点
      final mpt = createGeoMultiPoint(const [LatLng(0, 0), LatLng(35.0, 135.0)]);
      expect(
        FeatureSearch.calcPointToFeatureDistance(const LatLng(35.0, 135.0), mpt, 'point'),
        equals(0.0),
      );
    });

    test('calculateBounds と面積・長さ計算', () {
      const polygon = [
        [
          LatLng(0, 0),
          LatLng(0, 0.01),
          LatLng(0.01, 0.01),
          LatLng(0.01, 0),
          LatLng(0, 0),
        ],
      ];
      final geoPoly = createGeoPolygon(polygon);
      final bounds = geoPoly.calculateBounds()!;
      expect(bounds.minX, 0.0);
      expect(bounds.minY, 0.0);
      expect(bounds.maxX, 0.01);
      expect(bounds.maxY, 0.01);
      expect(createGeoLineString(const []).calculateBounds(), isNull);

      expect(Geodesic.areaOf(geoPoly), greaterThan(1e6));
      expect(Geodesic.lengthOf(createGeoLineString(const [LatLng(0, 0), LatLng(0, 0.01)])), greaterThan(1000));
    });
  });
}
