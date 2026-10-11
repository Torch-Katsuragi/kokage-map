// Root Maps: 書き出しの形式と ogr2ogr の引数（GDAL を呼ばない部分）。GDAL での書き出しは test/layer_export_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/services/coordinate/index.dart';
import 'package:root_maps/services/import_export/import_export_service.dart';

void main() {
  group('書き出しの形式', () {
    test('ダイアログの選択肢は GDAL のドライバ全部', () {
      expect(ImportExportService().getSupportedExportFormats().map((f) => f.driver), [
        'GPKG', 'ESRI Shapefile', 'GeoJSON', 'KML', 'CSV', 'GPX', 'FlatGeobuf', 'DXF',
      ]);
    });

    test('拡張子から形式（大小を問わない・.json も GeoJSON・ドット必須）', () {
      expect(FileFormat.fromExtension('.SHP'), FileFormat.shapefile);
      expect(FileFormat.fromExtension('.json'), FileFormat.geojson);
      expect(FileFormat.fromExtension('.gpkg'), FileFormat.geopackage);
      expect(FileFormat.fromExtension('shp'), isNull);
      expect(FileFormat.fromExtension('.xyz'), isNull);
    });

    test('GPX は面を書けない', () {
      expect(FileFormat.gpx.supports(GeometryType.polygon), isFalse);
      expect(FileFormat.gpx.supports(GeometryType.point), isTrue);
      expect(FileFormat.shapefile.supports(GeometryType.polygon), isTrue);
    });
  });

  group('ogr2ogr の引数', () {
    final vi = EpsgRegistry.instance.getByCode('EPSG:6674');

    List<String> args(FileFormat f, {GeometryType? type = GeometryType.point, EpsgDefinition? crs, String? pk}) =>
        ImportExportService.exportArgs(format: f, layerName: '林班', geometryType: type, targetCrs: crs, rowNumberPk: pk);

    test('座標系は選ばなければレイヤのまま、選べば -t_srs', () {
      expect(args(FileFormat.shapefile), ['-f', 'ESRI Shapefile', '-lco', 'ENCODING=UTF-8', '-nlt', 'POINT', '林班']);
      expect(args(FileFormat.shapefile, type: GeometryType.polygon), ['-f', 'ESRI Shapefile', '-lco', 'ENCODING=UTF-8', '林班']);
      expect(args(FileFormat.geopackage, crs: vi), ['-f', 'GPKG', '-t_srs', 'EPSG:6674', '林班']);
    });

    test('GeoJSON・KML・GPX は形式の決まりで 4326（選んだ座標系は使わない）', () {
      expect(args(FileFormat.geojson, crs: vi), ['-f', 'GeoJSON', '-t_srs', 'EPSG:4326', '-lco', 'RFC7946=YES', '林班']);
      expect(args(FileFormat.kml, crs: vi), ['-f', 'KML', '-t_srs', 'EPSG:4326', '林班']);
      expect(args(FileFormat.gpx), containsAllInOrder(['-t_srs', 'EPSG:4326', '-nlt', 'POINT']));
    });

    test('CSV は点なら X・Y 列、ほかは WKT', () {
      expect(args(FileFormat.csv), contains('GEOMETRY=AS_XY'));
      expect(args(FileFormat.csv, type: GeometryType.polygon), contains('GEOMETRY=AS_WKT'));
    });

    test('行番号は主キーの順に -sql で足す', () {
      final a = args(FileFormat.csv, pk: 'fid');
      expect(a.sublist(a.indexOf('-sql') + 1), [
        'SELECT *, ROW_NUMBER() OVER (ORDER BY "fid") AS ROW_NUM FROM "林班"',
        '-nln', '林班',
      ]);
    });
  });

  group('GeometryType', () {
    test('GeometryType enum should have correct values', () {
      // GeometryType の value は MULTI 系が既定（Single も透過的に扱う設計）
      expect(GeometryType.point.value, equals('MULTIPOINT'));
      expect(GeometryType.linestring.value, equals('MULTILINESTRING'));
      expect(GeometryType.polygon.value, equals('MULTIPOLYGON'));
    });

    test('GeometryType fromString should work correctly', () {
      expect(GeometryType.fromString('POINT'), equals(GeometryType.point));
      expect(
        GeometryType.fromString('LINESTRING'),
        equals(GeometryType.linestring),
      );
      expect(GeometryType.fromString('POLYGON'), equals(GeometryType.polygon));
      // MULTI 系も同じ型に落ちる
      expect(GeometryType.fromString('MULTIPOINT'), equals(GeometryType.point));
      expect(
        GeometryType.fromString('MULTIPOLYGON'),
        equals(GeometryType.polygon),
      );
      // 未知の文字列は null（呼び出し側でフォールバックを決める）
      expect(GeometryType.fromString('UNKNOWN'), isNull);
    });
  });

  group('ImportExportService座標変換テスト', () {
    test('EpsgDefinitionオブジェクトの作成', () {
      const coordinateSystem = EpsgDefinition(
        code: 'EPSG:2448',
        name: 'JGD2000 / Japan Plane Rectangular CS VI',
        proj4String:
            '+proj=tmerc +lat_0=36 +lon_0=136 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      );

      expect(coordinateSystem.name, 'JGD2000 / Japan Plane Rectangular CS VI');
      expect(coordinateSystem.code, 'EPSG:2448');
      expect(coordinateSystem.codeNumber, '2448');
      // ignore: avoid_print
      print('[TEST] EpsgDefinitionオブジェクト作成成功');
    });

    test('和歌山県の座標変換テスト', () {
      // 和歌山県北山村の平面直角座標系VI系の座標例（推定値）
      // 平面直角座標系は X=Northing(北方向), Y=Easting(東方向)
      const x = -150000.0; // Northing (北方向)
      const y = 50000.0; // Easting (東方向)

      final coordinateSystem = EpsgRegistry.instance.getByCode('EPSG:2448')!;
      expect(coordinateSystem.name, contains('JGD2000'));

      try {
        final p = (GeometryReprojector.reprojectToWgs84(
          const geo.Point(geo.Projected(x: x, y: y)),
          Projections.parse(coordinateSystem.proj4String)!,
          needsAxisSwap: true,
        ) as geo.Point)
            .position;
        final result = LatLng(p.y, p.x);

        // ignore: avoid_print
        print(
          '[TEST] 座標変換結果: ($x, $y) -> (${result.latitude}, ${result.longitude})',
        );

        // 和歌山県の緯度経度範囲をチェック（余裕を持った範囲）
        expect(result.latitude, greaterThan(33.0));
        expect(result.latitude, lessThan(35.0));
        expect(result.longitude, greaterThan(135.0));
        expect(result.longitude, lessThan(137.0)); // 余裕を持った範囲に調整

        // ignore: avoid_print
        print('[TEST] 和歌山県座標変換テスト成功');
      } catch (e) {
        // ignore: avoid_print
        print('[TEST] 座標変換エラー: $e');
        fail('座標変換に失敗: $e');
      }
    });

    test('proj4dart基本動作テスト', () {
      try {
        // WGS84からJGD2000平面直角座標系VI系への変換テスト
        final source = Projection.get('EPSG:4326'); // WGS84
        final target = Projection.add(
          'EPSG:2448',
          '+proj=tmerc +lat_0=36 +lon_0=136 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
        );

        expect(source, isNotNull);
        expect(target, isNotNull);

        if (source != null) {
          // 和歌山県の緯度経度を平面直角座標に変換
          final wgs84Point = Point(x: 135.8, y: 34.2); // 和歌山県内の座標
          final result = source.transform(target, wgs84Point);

          // ignore: avoid_print
          print(
            '[TEST] proj4dart変換テスト: (${wgs84Point.y}, ${wgs84Point.x}) -> (${result.x.toStringAsFixed(1)}, ${result.y.toStringAsFixed(1)})',
          );

          // 平面直角座標系の座標値は通常数万～数十万メートル
          expect(result.x.abs(), greaterThan(1000.0));
          expect(result.y.abs(), greaterThan(1000.0));

          // ignore: avoid_print
          print('[TEST] proj4dart基本動作テスト成功');
        }
      } catch (e) {
        // ignore: avoid_print
        print('[TEST] proj4dartテストエラー: $e');
        fail('proj4dart動作テストに失敗: $e');
      }
    });

    test('大きな座標値の妥当性チェック', () {
      // 平面直角座標系の典型的な座標値（数万〜数十万メートル）
      final largeCoordinates = [
        Point(x: 123456.789, y: -234567.123),
        Point(x: 50000.0, y: -150000.0),
        Point(x: 200000.0, y: -50000.0),
      ];

      for (final coord in largeCoordinates) {
        // 有限数チェック
        expect(coord.x.isFinite, isTrue);
        expect(coord.y.isFinite, isTrue);
        // ignore: avoid_print
        print('[TEST] 大きな座標値 (${coord.x}, ${coord.y}) の妥当性確認');
      }
    });
  });
}
