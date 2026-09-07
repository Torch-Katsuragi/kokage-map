// Root Maps: turf_dart統合テスト
// turf_dartのFeature/FeatureCollectionとの統合機能をテストする

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/converters/turf_converter.dart';
import 'package:turf/turf.dart' as turf;

void main() {
  group('TurfConverter Tests', () {
    test('LatLng to Position conversion', () {
      // テスト用座標
      const latlng = LatLng(35.6895, 139.6917); // 東京駅

      // LatLng → Position変換
      final position = TurfConverter.latlngToPosition(latlng);

      // Position形式は [longitude, latitude] の順
      expect(position[0], equals(139.6917)); // longitude
      expect(position[1], equals(35.6895)); // latitude

      // Position → LatLng変換（逆変換）
      final convertedBack = TurfConverter.positionToLatlng(position);
      expect(convertedBack.latitude, equals(latlng.latitude));
      expect(convertedBack.longitude, equals(latlng.longitude));

      // ignore: avoid_print
      print('[TEST] LatLng⇄Position変換テスト成功: $latlng ⇄ $position');
    });

    test('Point Feature creation and conversion', () {
      // テスト用座標
      const latlng = LatLng(35.6895, 139.6917);

      // turf_dartのPointを作成
      final point = TurfConverter.createPoint(latlng);
      expect(point.coordinates.lng, equals(139.6917));
      expect(point.coordinates.lat, equals(35.6895));

      // Point → LatLng変換
      final convertedLatLng = TurfConverter.pointToLatlng(point);
      expect(convertedLatLng.latitude, equals(latlng.latitude));
      expect(convertedLatLng.longitude, equals(latlng.longitude));

      // ignore: avoid_print
      print('[TEST] Point Feature作成・変換テスト成功');
    });

    test('LineString Feature creation and conversion', () {
      // テスト用線分座標
      final line = [
        const LatLng(35.6895, 139.6917), // 東京駅
        const LatLng(35.6762, 139.6503), // 新宿駅
        const LatLng(35.6584, 139.7016), // 渋谷駅
      ];

      // turf_dartのLineStringを作成
      final lineString = TurfConverter.createLineString(line);
      expect(lineString.coordinates.length, equals(3));

      // LineString → LatLng変換
      final convertedLine = TurfConverter.lineStringToLatlngs(lineString);
      expect(convertedLine.length, equals(3));
      expect(convertedLine[0].latitude, equals(line[0].latitude));
      expect(convertedLine[0].longitude, equals(line[0].longitude));

      // ignore: avoid_print
      print('[TEST] LineString Feature作成・変換テスト成功');
    });

    test('Polygon Feature creation and conversion', () {
      // テスト用ポリゴン座標（四角形）
      final polygon = [
        [
          const LatLng(35.6895, 139.6917), // 右上
          const LatLng(35.6762, 139.6917), // 右下
          const LatLng(35.6762, 139.6503), // 左下
          const LatLng(35.6895, 139.6503), // 左上
          const LatLng(35.6895, 139.6917), // 閉じる（最初の点と同じ）
        ],
      ];

      // turf_dartのPolygonを作成
      final turfPolygon = TurfConverter.createPolygon(polygon);
      expect(turfPolygon.coordinates.length, equals(1)); // 外環のみ
      expect(turfPolygon.coordinates[0].length, equals(5)); // 5頂点（閉じた形）

      // Polygon → LatLng変換
      final convertedPolygon = TurfConverter.polygonToLatlngs(turfPolygon);
      expect(convertedPolygon.length, equals(1));
      expect(convertedPolygon[0].length, equals(5));
      expect(convertedPolygon[0][0].latitude, equals(polygon[0][0].latitude));

      // ignore: avoid_print
      print('[TEST] Polygon Feature作成・変換テスト成功');
    });

    test('Feature creation from row data', () {
      // GeoPackageから取得したrowデータをシミュレート
      final rowData = {
        'id': 1,
        'name': 'Test Point',
        'description': 'テスト用ポイント',
        'geometry': [const LatLng(35.6895, 139.6917)], // Point形式
        'rmaps_metadata': {'test': 'data'},
      };

      // turf_dartのFeatureを作成
      final feature = TurfConverter.createFeatureFromRow(rowData, 'Point');
      expect(feature, isNotNull);
      expect(feature!.properties?['name'], equals('Test Point'));
      expect(feature.properties?['description'], equals('テスト用ポイント'));
      expect(feature.geometry, isA<turf.Point>());

      // Feature → rowData変換
      // featureToRowData は属性のみを返す契約。ジオメトリは feature.geometry 側に
      // 残るため rowData には載らない（geometry/geom キーは意図的に除外される）。
      final convertedRowData = TurfConverter.featureToRowData(feature);
      expect(convertedRowData, isNotNull);
      expect(convertedRowData!['name'], equals('Test Point'));
      expect(convertedRowData.containsKey('geometry'), isFalse);
      expect(convertedRowData.containsKey('geom'), isFalse);

      // ジオメトリは専用の変換で取り出す
      final latlng = TurfConverter.pointToLatlng(feature.geometry as turf.Point);
      expect(latlng.latitude, closeTo(35.6895, 1e-6));
      expect(latlng.longitude, closeTo(139.6917, 1e-6));

      // ignore: avoid_print
      print('[TEST] RowData⇄Feature変換テスト成功');
    });

    test('Centroid calculation', () {
      // テスト用ポリゴン
      final polygon = [
        [
          const LatLng(0, 0),
          const LatLng(0, 2),
          const LatLng(2, 2),
          const LatLng(2, 0),
          const LatLng(0, 0), // 閉じる
        ],
      ];

      final turfPolygon = TurfConverter.createPolygon(polygon);
      final feature = turf.Feature(geometry: turfPolygon, properties: {});

      // 重心計算
      final centroid = TurfConverter.calculateCentroid(feature);
      expect(centroid, isNotNull);

      // 正方形の重心は中央 (1, 1) 付近になるはず
      expect(centroid!.latitude, closeTo(1.0, 0.1));
      expect(centroid.longitude, closeTo(1.0, 0.1));

      // ignore: avoid_print
      print('[TEST] 重心計算テスト成功: centroid = $centroid');
    });

    test('Area and length calculations', () {
      // 面積計算テスト用ポリゴン
      final polygon = [
        [
          const LatLng(0, 0),
          const LatLng(0, 0.01), // 約1km
          const LatLng(0.01, 0.01),
          const LatLng(0.01, 0),
          const LatLng(0, 0),
        ],
      ];

      final turfPolygon = TurfConverter.createPolygon(polygon);
      final polygonFeature = turf.Feature(
        geometry: turfPolygon,
        properties: {},
      );

      // 面積計算
      final area = TurfConverter.calculateArea(polygonFeature);
      expect(area, isNotNull);
      expect(area, greaterThan(0));

      // 長さ計算テスト用ライン
      final line = [
        const LatLng(0, 0),
        const LatLng(0, 0.01), // 約1km
      ];

      final lineString = TurfConverter.createLineString(line);
      final lineFeature = turf.Feature(geometry: lineString, properties: {});

      // 長さ計算
      final length = TurfConverter.calculateLength(lineFeature);
      expect(length, isNotNull);
      expect(length, greaterThan(0));

      // ignore: avoid_print
      print('[TEST] 面積・長さ計算テスト成功: area=$area m², length=$length m');
    });
  });
}
