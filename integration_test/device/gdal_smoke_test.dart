// libgdal.so の実機スモーク: 読めるか・proj.db / GDAL_DATA の書き出し・各ドライバ・Shift_JIS（iconv）・CRS・ラスタ
//
// 実行: flutter test integration_test/device/gdal_smoke_test.dart -d <device>
// 同じ筋書きのホスト VM 版は test/gdal_test.dart（QGIS の gdal*.dll ／ apt の libgdal）。筋書きは test/support/gdal_scenarios.dart。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:root_maps/core/gdal/gdal_provider.dart';

import '../../test/support/gdal_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Gdal g;
  late Directory tmp;

  setUpAll(() async {
    g = createGdal();
    tmp = await Directory.systemTemp.createTemp('gdal_');
  });
  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('libgdal.so が読めて version が返り、proj.db と GDAL_DATA が書き出される', () async {
    final sw = Stopwatch()..start();
    final v = await g.version();
    // ignore: avoid_print
    print('[gdal] version=$v 初回 ${sw.elapsedMilliseconds}ms（proj.db・GDAL_DATA の書き出し込み）');
    expect(v, matches(RegExp(r'^3\.\d+\.\d+')));
    final support = await getApplicationSupportDirectory();
    final db = File(p.join(support.path, 'gdal', 'proj', 'proj.db'));
    expect(await db.exists(), isTrue);
    expect(await File(p.join(support.path, 'gdal', 'data', 'header.dxf')).exists(), isTrue);
    sw.reset();
    await g.version();
    // ignore: avoid_print
    print('[gdal] 2 回目 ${sw.elapsedMilliseconds}ms（アイソレートの起動と dlopen だけ）');
  });

  test('入れたベクタのドライバ全部へ ogr2ogr して読み戻せる', () async {
    final dir = await Directory(p.join(tmp.path, 'rt')).create();
    final counts = await gdalVectorRoundTrip(g, dir.path);
    // ignore: avoid_print
    print('[gdal] round trip: $counts');
    expect(counts.keys, containsAll(gdalScenarioVectorFormats.keys));
    expect(counts.values, everyElement(3));
  });

  test('Shift_JIS の shp（.cpg も LDID も無い）が CP932 で読め、gpkg にしても EPSG:6674 のまま', () async {
    final dir = await Directory(p.join(tmp.path, 'sjis')).create();
    expect(await gdalShiftJisShapefile(g, dir.path), gdalScenarioNames);
    expect(await gdalShpToGpkgCrs(g, dir.path), 6674);
    final files = await g.fileList(p.join(dir.path, 'sjis.shp'));
    expect(files.map(p.extension).toSet(), containsAll(['.shp', '.shx', '.dbf', '.prj']));
  });

  test('ラスタ: VRT → LZW GeoTIFF → EPSG:4326 へ warp → PNG / JPEG', () async {
    final dir = await Directory(p.join(tmp.path, 'raster')).create();
    final info = await gdalRasterPipeline(g, dir.path);
    expect(info['driverShortName'], 'PNG');
    expect((info['size'] as List).first, 16);
    expect(dig(info, ['wgs84Extent', 'coordinates', 0, 0, 0]), closeTo(135.96, 0.01));
  });

  test('開けないファイルは GdalException（落ちない）', () async {
    await expectLater(g.vectorInfo(p.join(tmp.path, 'nope.shp')), throwsA(isA<GdalException>()));
  });
}
