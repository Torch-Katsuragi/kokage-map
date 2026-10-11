// アプリが書く GeoTIFF（オーバーレイに変換・位置合わせ）を GDAL で書く（lib/services/geotiff_service.dart）。
//
// QGIS（GDAL）で開いて警告が出ない形か、位置（回転を含む）と座標系が往復するか、旧版の形が読めて書き直せるかを見る。
// 使う GDAL は gdal_test.dart と同じ（Windows は QGIS 同梱の gdal*.dll、CI は apt の libgdal）。見つからなければ skip。
// 警告の有無は同じ場所の `gdalinfo` コマンドの stderr で見る（無ければその検査だけ skip）。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal_ffi.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/services/geotiff_service.dart';

import 'support/gdal_host.dart';
import 'support/legacy_geotiff.dart';

/// 300×200（256 で割り切れない。端の切れ目を見る）。左半分は透明度の段々、右下は完全に透明
img.Image _source() {
  final im = img.Image(width: 300, height: 200, numChannels: 4);
  for (final px in im) {
    px
      ..r = px.x % 256
      ..g = px.y
      ..b = (px.x * 7 + px.y * 3) % 256
      ..a = px.x < 150 ? (px.y * 255 ~/ 199) : (px.x > 250 && px.y > 150 ? 0 : 255);
  }
  return im;
}

void _expectSamePixels(img.Image actual, img.Image expected) {
  expect([actual.width, actual.height], [expected.width, expected.height]);
  final a = actual.convert(numChannels: 4);
  // 全画素（完全に透明な画素の色も含めて）。PNG キャッシュ・web の 3D は package:image で解くので、そこで崩れないこと
  for (final pe in expected) {
    final pa = a.getPixel(pe.x, pe.y);
    if (pa.r != pe.r || pa.g != pe.g || pa.b != pe.b || pa.a != pe.a) {
      fail('(${pe.x}, ${pe.y}): ${[pa.r, pa.g, pa.b, pa.a]} ≠ ${[pe.r, pe.g, pe.b, pe.a]}');
    }
  }
}

void _expectParams(KMetaImageOverlay? actual, KMetaImageOverlay expected) {
  expect(actual, isNotNull);
  expect(actual!.centerLng, closeTo(expected.centerLng, 1e-9));
  expect(actual.centerLat, closeTo(expected.centerLat, 1e-9));
  expect(actual.scale, closeTo(expected.scale, 1e-6));
  expect(actual.rotation, closeTo(expected.rotation, 1e-6));
  expect([actual.imageWidth, actual.imageHeight], [expected.imageWidth, expected.imageHeight]);
}

/// ホストの GDAL と同じ場所の gdalinfo コマンド（無ければ null）
String? _gdalinfoExe(GdalFfiConfig c) {
  final dir = c.dllSearchDir;
  if (dir != null) {
    final exe = p.join(dir, Platform.isWindows ? 'gdalinfo.exe' : 'gdalinfo');
    if (File(exe).existsSync()) return exe;
  }
  for (final d in const ['/usr/bin', '/usr/local/bin']) {
    if (File(p.join(d, 'gdalinfo')).existsSync()) return p.join(d, 'gdalinfo');
  }
  return null;
}

void main() {
  final config = findHostGdal();
  final skip = config == null ? 'GDAL が見つからない（QGIS か libgdal-dev を入れる）' : null;
  late GdalFfi gdal;
  late Directory tmp;

  setUp(() async {
    if (config == null) return;
    gdal = GdalFfi(config);
    tmp = await Directory.systemTemp.createTemp('geotiff_write_');
    GeoTiffService.configureForTest(gdal: gdal, tempDir: p.join(tmp.path, 'work'));
  });

  tearDown(() async {
    if (config == null) return;
    GeoTiffService.configureForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String at(String name) => p.join(tmp.path, name);

  Future<String> sourcePng() async {
    final path = at('photo.png');
    File(path).writeAsBytesSync(img.encodePng(_source()));
    return path;
  }

  const flat = KMetaImageOverlay(centerLng: 135.97, centerLat: 33.94, scale: 0.5, imageWidth: 300, imageHeight: 200);

  test('オーバーレイに変換: ストリップ・DEFLATE・RGBA（アルファ）・EPSG:4326・目印、位置が往復する', () async {
    final out = at('photo.tif');
    await GeoTiffService.createGeoTiff(await sourcePng(), out, flat);

    final info = await gdal.rasterInfo(out);
    expect(info['size'], [300, 200]);
    final bands = (info['bands'] as List).cast<Map<String, dynamic>>();
    expect(bands.map((b) => b['colorInterpretation']), ['Red', 'Green', 'Blue', 'Alpha']);
    expect(bands.map((b) => b['type']).toSet(), {'Byte'});
    expect((bands.first['block'] as List).first, 300, reason: 'ストリップ（package:image がタイルの右端を崩すため）');
    final metadata = info['metadata'] as Map<String, dynamic>;
    expect((metadata['IMAGE_STRUCTURE'] as Map)['COMPRESSION'], 'DEFLATE');
    expect((metadata[''] as Map)['TIFFTAG_SOFTWARE'], GeoTiffService.kSoftware);
    expect((info['coordinateSystem'] as Map)['wkt'], contains('ID["EPSG",4326]'));
    final gt = (info['geoTransform'] as List).cast<num>();
    final want = GeoTiffService.geoTransform(flat);
    for (var i = 0; i < 6; i++) {
      expect(gt[i], closeTo(want[i], 1e-12), reason: 'gt[$i]');
    }

    final bytes = File(out).readAsBytesSync();
    expect(GeoTiffService.isGdalWritten(bytes), isTrue);
    _expectParams(GeoTiffService.readGeoTiffParams(bytes), flat);
    // PNG キャッシュ・web の 3D は package:image で解く
    _expectSamePixels(img.decodeImage(bytes)!, _source());
    expect(Directory(at('work')).listSync(), isEmpty, reason: '作業用の PNG は残さない');
  }, skip: skip);

  test('回転あり: ModelTransformationTag で書かれ、回転・中心・縮尺が往復する', () async {
    const rotated = KMetaImageOverlay(
      centerLng: 135.97,
      centerLat: 33.94,
      scale: 0.5,
      rotation: 30,
      imageWidth: 300,
      imageHeight: 200,
    );
    final out = at('rot.tif');
    await GeoTiffService.createGeoTiff(await sourcePng(), out, rotated);
    final gt = ((await gdal.rasterInfo(out))['geoTransform'] as List).cast<num>();
    expect(gt[2], isNot(0));
    expect(gt[4], isNot(0));
    _expectParams(GeoTiffService.readGeoTiffParams(File(out).readAsBytesSync()), rotated);
  }, skip: skip);

  test('位置合わせ: 移動・回転・拡大を書き直しても画素と目印はそのまま', () async {
    final out = at('photo.tif');
    await GeoTiffService.createGeoTiff(await sourcePng(), out, flat);
    const moved = KMetaImageOverlay(
      centerLng: 135.98,
      centerLat: 33.95,
      scale: 1.25,
      rotation: -42.5,
      imageWidth: 300,
      imageHeight: 200,
    );
    await GeoTiffService.updateGeoTiffTags(out, moved);
    var bytes = File(out).readAsBytesSync();
    expect(GeoTiffService.isGdalWritten(bytes), isTrue);
    _expectParams(GeoTiffService.readGeoTiffParams(bytes), moved);
    _expectSamePixels(img.decodeImage(bytes)!, _source());

    // 回転を戻す（ModelTransformationTag → Tiepoint + PixelScale）
    await GeoTiffService.updateGeoTiffTags(out, flat);
    bytes = File(out).readAsBytesSync();
    _expectParams(GeoTiffService.readGeoTiffParams(bytes), flat);
    expect(File('$out.kokage-tmp').existsSync(), isFalse);
    expect(Directory(tmp.path).listSync().map((e) => p.basename(e.path)).toSet(), {'photo.png', 'photo.tif', 'work'});
  }, skip: skip);

  test('旧版の形（package:image）: アプリの GeoTIFF として読め、位置合わせで GDAL の形に書き直す', () async {
    final legacy = at('old.tif');
    final params = flat.copyWith(rotation: 15);
    writeLegacyGeoTiff(legacy, _source(), params);
    var bytes = File(legacy).readAsBytesSync();
    expect(GeoTiffService.isGdalWritten(bytes), isFalse);
    _expectParams(GeoTiffService.readGeoTiffParams(bytes), params);

    final moved = params.copyWith(centerLng: 135.971, rotation: 0);
    await GeoTiffService.updateGeoTiffTags(legacy, moved);
    bytes = File(legacy).readAsBytesSync();
    expect(GeoTiffService.isGdalWritten(bytes), isTrue);
    _expectParams(GeoTiffService.readGeoTiffParams(bytes), moved);
    _expectSamePixels(img.decodeImage(bytes)!, _source());
    final bands = ((await gdal.rasterInfo(legacy))['bands'] as List).cast<Map<String, dynamic>>();
    expect(bands.last['colorInterpretation'], 'Alpha');
  }, skip: skip);

  test('外のラスタ（目印なし・回転なし）はアプリの GeoTIFF とみなさない', () async {
    // QGIS / GDAL で作った EPSG:4326 の GeoTIFF（ModelTiepoint + ModelPixelScale）
    final bytes = File('test/fixtures/gdal/ext_gray_4326.tif').readAsBytesSync();
    expect(GeoTiffService.isGdalWritten(bytes), isFalse);
    expect(GeoTiffService.readGeoTiffParams(bytes), isNull);
    // EPSG:4326 でない回転つきの GeoTIFF（ModelTransformationTag）も
    final out = at('rot6674.tif');
    await gdal.translate('test/fixtures/gdal/ext_rgb_6674.tif', out, args: const [
      '-of', 'GTiff', '-a_gt', '-30000', '1', '0.5', '-190000', '0.5', '-1', //
    ]);
    expect(GeoTiffService.readGeoTiffParams(File(out).readAsBytesSync()), isNull);
  }, skip: skip);

  test('gdalinfo（QGIS と同じ GDAL）が警告を出さない。旧版の形は出す', () async {
    final exe = _gdalinfoExe(config!);
    if (exe == null) {
      markTestSkipped('gdalinfo コマンドが無い');
      return;
    }
    Future<String> warnings(String path) async {
      final r = await Process.run(exe, [path], environment: {
        if (config.projDataDir != null) 'PROJ_DATA': config.projDataDir!,
        if (config.gdalDataDir != null) 'GDAL_DATA': config.gdalDataDir!,
      });
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return '${r.stderr}';
    }

    final out = at('photo.tif');
    await GeoTiffService.createGeoTiff(await sourcePng(), out, flat);
    expect(await warnings(out), isEmpty);
    await GeoTiffService.updateGeoTiffTags(out, flat.copyWith(rotation: 20));
    expect(await warnings(out), isEmpty);

    final legacy = at('old.tif');
    writeLegacyGeoTiff(legacy, _source(), flat);
    expect(await warnings(legacy), contains('Warning'), reason: 'この検査が警告を拾えること');
  }, skip: skip);

  test('geoTransform は 4x4 行列と同じ変換', () {
    final params = flat.copyWith(rotation: 33);
    final gt = GeoTiffService.geoTransform(params);
    final m = GeoTiffService.buildModelTransformationMatrix(params);
    for (final (i, j) in [(0.0, 0.0), (150.0, 100.0), (300.0, 200.0)]) {
      expect(gt[0] + i * gt[1] + j * gt[2], closeTo(m[0] * i + m[1] * j + m[3], 1e-12));
      expect(gt[3] + i * gt[4] + j * gt[5], closeTo(m[4] * i + m[5] * j + m[7], 1e-12));
    }
    // 中心は画像の真ん中
    expect(gt[0] + 150 * gt[1] + 100 * gt[2], closeTo(params.centerLng, 1e-12));
    expect(gt[3] + 150 * gt[4] + 100 * gt[5], closeTo(params.centerLat, 1e-12));
    expect(math.atan2(gt[4], gt[1]) * 180 / math.pi, closeTo(33, 1e-9));
  });
}
