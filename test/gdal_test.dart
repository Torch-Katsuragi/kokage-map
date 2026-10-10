// GdalFfi（lib/core/gdal/gdal_ffi.dart）のホスト VM テスト。
//
// 使う GDAL: Windows は QGIS 同梱の gdal*.dll、CI（Linux）は apt の libgdal（test/support/gdal_host.dart）。
// 見つからなければ全部 skip。入力は test/fixtures/gdal/（作り方は make_fixtures.sh）。
// 実機（libgdal.so）の同じ筋は integration_test/device/gdal_smoke_test.dart。
//
// ⚠ GDAL を使うテストはこのファイルに集める。QGIS の DLL 群は sqlite3.dll などを名前で読み込むので、
//    同じプロセスで別の sqlite3.dll（sqflite_common_ffi）が先に読まれていると食い違いうる
//    （flutter test はテストファイルごとに別プロセス）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal.dart';
import 'package:root_maps/core/gdal/gdal_ffi.dart';

import 'support/gdal_host.dart';
import 'support/gdal_scenarios.dart';

const _fx = 'test/fixtures/gdal';

void main() {
  final config = findHostGdal();
  final skip = config == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null;
  late GdalFfi gdal;
  late Directory tmp;

  setUpAll(() async {
    if (config == null) return;
    gdal = GdalFfi(config);
    tmp = await Directory.systemTemp.createTemp('gdal_test_');
  });
  tearDownAll(() async {
    if (config == null) return;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// ogrinfo -json -features の 1 枚目のレイヤの name 列
  List<Object?> names(Map<String, dynamic> info) => featureValues(info, 'name');

  const expectedNames = gdalScenarioNames;

  test('version', () async {
    final v = await gdal.version();
    // ignore: avoid_print
    print('[gdal] ${config!.libraryPath} → $v');
    expect(v, matches(RegExp(r'^3\.\d+\.\d+')));
  }, skip: skip);

  group('vectorInfo', () {
    test('Shift_JIS の shp（.cpg あり）: 名前が読めて、CRS は EPSG:6674', () async {
      final info = await gdal.vectorInfo('$_fx/sjis_cpg.shp', args: ['-features']);
      expect(names(info), expectedNames);
      expect(firstLayer(info)['featureCount'], 3);
      expect(layerEpsg(info), 6674);
    }, skip: skip);

    test('Shift_JIS の shp（.cpg も LDID も無い）: CP932 とみなして読める（QGIS 日本語版と同じ見え方）', () async {
      expect(needsShapefileFallbackEncoding('$_fx/sjis_nocpg.shp'), isTrue);
      expect(needsShapefileFallbackEncoding('$_fx/sjis_cpg.shp'), isFalse);
      final info = await gdal.vectorInfo('$_fx/sjis_nocpg.shp', args: ['-features']);
      expect(names(info), expectedNames);
    }, skip: skip);

    test('呼ぶ側の -oo ENCODING が優先する', () async {
      final info = await gdal.vectorInfo('$_fx/sjis_nocpg.shp', args: ['-features', '-oo', 'ENCODING=']);
      // 文字コードを決めない = Shift_JIS のバイトがそのまま（壊れた UTF-8 は U+FFFD に）
      expect(names(info).first, isNot('スギ1'));
    }, skip: skip);

    test('GeoJSON', () async {
      final info = await gdal.vectorInfo('$_fx/points.geojson', args: ['-features']);
      expect(names(info), expectedNames);
    }, skip: skip);

    test('KML', () async {
      final info = await gdal.vectorInfo('$_fx/points.kml', args: ['-features']);
      expect(featureValues(info, 'Name'), expectedNames);
    }, skip: skip);

    test('CSV（lon/lat 列を点に）', () async {
      final info = await gdal.vectorInfo('$_fx/points.csv',
          args: ['-features', '-oo', 'X_POSSIBLE_NAMES=lon', '-oo', 'Y_POSSIBLE_NAMES=lat']);
      expect(names(info), expectedNames);
      expect(dig(firstLayer(info), ['features', 0, 'geometry', 'type']), 'Point');
      expect(dig(firstLayer(info), ['features', 0, 'geometry', 'coordinates', 0]), closeTo(135.96, 1e-9));
    }, skip: skip);

    test('開けないファイルは GdalException', () async {
      await expectLater(gdal.vectorInfo('$_fx/nope.shp'), throwsA(isA<GdalException>()));
    }, skip: skip);
  });

  test('vectorTranslate: shp → gpkg で CRS（EPSG:6674）と属性が保たれる', () async {
    final dst = p.join(tmp.path, 'sjis_nocpg.gpkg');
    await gdal.vectorTranslate('$_fx/sjis_nocpg.shp', dst, args: ['-f', 'GPKG', '-nln', '林班']);
    final info = await gdal.vectorInfo(dst, args: ['-features']);
    expect(firstLayer(info)['name'], '林班');
    expect(names(info), expectedNames);
    expect(layerEpsg(info), 6674);
  }, skip: skip);

  test('rasterInfo + warp: EPSG:6674 の LZW GeoTIFF を EPSG:4326 の PNG に', () async {
    final info = await gdal.rasterInfo('$_fx/dem_6674.tif');
    expect(info['size'], [8, 8]);
    expect(dig(info, ['metadata', 'IMAGE_STRUCTURE', 'COMPRESSION']), 'LZW');
    expect(info['wgs84Extent'], isNotNull);

    final warped = p.join(tmp.path, 'dem_4326.tif');
    await gdal.warp('$_fx/dem_6674.tif', warped, args: ['-t_srs', 'EPSG:4326', '-ts', '16', '0', '-of', 'GTiff']);
    final png = p.join(tmp.path, 'dem_4326.png');
    await gdal.translate(warped, png, args: ['-of', 'PNG']);
    final pngInfo = await gdal.rasterInfo(png);
    expect(pngInfo['driverShortName'], 'PNG');
    expect((pngInfo['size'] as List).first, 16);
    // 四隅（wgs84Extent）は北山村あたり
    final ring = ((info['wgs84Extent'] as Map)['coordinates'] as List).first as List;
    for (final c in ring) {
      expect((c as List)[0], closeTo(135.96, 0.01));
      expect(c[1], closeTo(33.93, 0.01));
    }
  }, skip: skip);

  // 実機の gdal_smoke_test.dart と同じ筋書き（入力をその場で書く）
  group('実機と共有の筋書き', () {
    test('各形式へ ogr2ogr して読み戻せる', () async {
      final dir = await Directory(p.join(tmp.path, 'rt')).create();
      final counts = await gdalVectorRoundTrip(gdal, dir.path);
      // ignore: avoid_print
      print('[gdal] round trip: $counts');
      expect(counts.values, everyElement(3));
    }, skip: skip);

    test('Shift_JIS の shp（.cpg も LDID も無い）→ gpkg で CRS が保たれる', () async {
      final dir = await Directory(p.join(tmp.path, 'sjis')).create();
      expect(await gdalShiftJisShapefile(gdal, dir.path), gdalScenarioNames);
      expect(await gdalShpToGpkgCrs(gdal, dir.path), 6674);
    }, skip: skip);

    test('ラスタ: VRT → LZW GeoTIFF → EPSG:4326 → PNG / JPEG', () async {
      final dir = await Directory(p.join(tmp.path, 'raster')).create();
      final info = await gdalRasterPipeline(gdal, dir.path);
      expect(info['driverShortName'], 'PNG');
      expect((info['size'] as List).first, 16);
    }, skip: skip);
  });

  test('fileList: shp は付属ファイル一式', () async {
    final files = await gdal.fileList('$_fx/sjis_cpg.shp');
    final exts = files.map((f) => p.extension(f).toLowerCase()).toSet();
    expect(p.basename(files.first), 'sjis_cpg.shp');
    expect(exts, containsAll(['.shp', '.shx', '.dbf', '.prj', '.cpg']));
  }, skip: skip);
}
