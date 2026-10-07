// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// Root Maps: EpsgRegistry / CoordinateService の挙動固定テスト
// 座標系モジュール統合前の挙動をピン留めする
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/services/coordinate/index.dart';

void main() {
  final registry = EpsgRegistry.instance;

  group('EpsgRegistry コード解決', () {
    // 旧 SmartCoordinateSystemManager.commonEpsgDefinitions に含まれていたコード
    const legacyCommonCodes = [
      'EPSG:4326',
      'EPSG:3857',
      'EPSG:2443',
      'EPSG:2444',
      'EPSG:2445',
      'EPSG:2446',
      'EPSG:2447',
      'EPSG:2448',
      'EPSG:2449',
      'EPSG:2450',
      'EPSG:2451',
      'EPSG:2452',
      'EPSG:32654',
      'EPSG:32655',
      'EPSG:32656',
    ];

    test('旧 commonEpsgDefinitions の全コードを解決できる', () {
      for (final code in legacyCommonCodes) {
        final def = registry.getByCode(code);
        expect(def, isNotNull, reason: '$code が未登録');
        expect(def!.code, code);
        expect(def.proj4String, startsWith('+proj='));
      }
    });

    test('JGD2011 平面直角 I〜XIX系が全て登録されている', () {
      for (var n = 6669; n <= 6687; n++) {
        expect(registry.getByCode('EPSG:$n'), isNotNull, reason: 'EPSG:$n');
      }
    });

    test('プレフィックスなしでも解決できる', () {
      expect(registry.getByCode('6674')?.code, 'EPSG:6674');
    });
  });

  group('EpsgRegistry 軸入れ替え判定', () {
    test('日本の平面直角座標系は入れ替えあり', () {
      expect(registry.needsAxisSwap('EPSG:6674'), isTrue);
      expect(registry.needsAxisSwap('EPSG:2448'), isTrue);
      expect(registry.needsAxisSwap('6669'), isTrue);
    });

    test('UTM・地理座標系は入れ替えなし', () {
      expect(registry.needsAxisSwap('EPSG:32653'), isFalse);
      expect(registry.needsAxisSwap('EPSG:4326'), isFalse);
      expect(registry.needsAxisSwap('EPSG:3857'), isFalse);
    });
  });

  group('CoordinateService 座標変換', () {
    final service = CoordinateService.instance;

    test('WGS84 → JGD2011 VI系 は X=Northing, Y=Easting で返す', () {
      final vi = registry.getByCode('EPSG:6674')!;
      // 和歌山県北山村付近
      final xy = service.transformToXY(const LatLng(33.93, 135.96), vi);
      expect(xy, isNotNull);
      // 原点 (36N, 136E) より南 → X(Northing) は負、東経がほぼ同じ → Y(Easting) は小さい
      expect(xy!['x'], lessThan(0));
      expect(xy['y']!.abs(), lessThan(10000));
    });

    test('往復変換で元の緯度経度に戻る（GPKG 読み込みの入れ替えと向きが合う）', () {
      final vi = registry.getByCode('EPSG:6674')!;
      const original = LatLng(33.93, 135.96);
      final xy = service.transformToXY(original, vi)!;
      final back = GeometryReprojector.reprojectToWgs84(
        geo.Point(geo.Projected(x: xy['x']!, y: xy['y']!)),
        Projections.parse(vi.proj4String)!,
        needsAxisSwap: true,
      ) as geo.Point;
      expect(back.position.y, closeTo(original.latitude, 1e-6));
      expect(back.position.x, closeTo(original.longitude, 1e-6));
    });

    test('WGS84 は無変換', () {
      final wgs84 = registry.getByCode('EPSG:4326')!;
      final xy = service.transformToXY(const LatLng(33.93, 135.96), wgs84);
      expect(xy, {'x': 135.96, 'y': 33.93});
      final jgd = registry.getByCode('EPSG:6668')!;
      expect(service.transformToXY(const LatLng(33.93, 135.96), jgd), {'x': 135.96, 'y': 33.93});
      expect(service.transformToXYFormatted(const LatLng(33.93, 135.96), jgd), {'x': '135.960000', 'y': '33.930000'});
    });

    test('UTM は入れ替えない（x=Easting）', () {
      final utm = registry.getByCode('EPSG:32653')!;
      final xy = service.transformToXY(const LatLng(33.93, 135.96), utm)!;
      expect(xy['x'], closeTo(588700, 2000));
      expect(xy['y'], closeTo(3755000, 5000));
    });

    test('同じ定義は 1 回だけ読む', () {
      final def = registry.getByCode('EPSG:6674')!.proj4String;
      expect(identical(Projections.parse(def), Projections.parse(def)), isTrue);
    });
  });
}
