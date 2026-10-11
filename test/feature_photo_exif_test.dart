// 地物の写真: EXIF に GPS が無ければ今の位置を足す（ExifGpsWriter）
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/services/feature_photos/exif_gps_writer.dart';

double _dms(IfdTag tag) {
  final r = (tag.values as IfdRatios).ratios;
  return r[0].toDouble() + r[1].toDouble() / 60 + r[2].toDouble() / 3600;
}

Uint8List _jpeg({int? orientation, LatLng? gps}) {
  final image = img.Image(width: 16, height: 8);
  img.fill(image, color: img.ColorRgb8(30, 120, 60));
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  if (gps != null) {
    image.exif.gpsIfd.data[0x0001] = img.IfdValueAscii('N');
    image.exif.gpsIfd.data[0x0002] = ExifGpsWriter.rationals([(gps.latitude.floor(), 1), (0, 1), (0, 1)]);
    image.exif.gpsIfd.data[0x0003] = img.IfdValueAscii('E');
    image.exif.gpsIfd.data[0x0004] = ExifGpsWriter.rationals([(gps.longitude.floor(), 1), (0, 1), (0, 1)]);
  }
  return img.encodeJpg(image);
}

void main() {
  const fix = LatLng(33.912345, 135.987654);

  test('GPS の無い JPEG に位置を書き込む（度分秒の RATIONAL・向きは残る・画素はそのまま）', () async {
    final src = _jpeg(orientation: 6);
    expect(ExifGpsWriter.hasGps(src), isFalse);

    final out = ExifGpsWriter.addIfMissing(src, fix, altitude: 412.5, time: DateTime.utc(2026, 10, 11, 1, 2, 3));
    expect(out, isNotNull);
    expect(ExifGpsWriter.hasGps(out!), isTrue);

    final tags = await readExifFromBytes(out);
    expect(tags['GPS GPSLatitudeRef']?.printable, 'N');
    expect(tags['GPS GPSLongitudeRef']?.printable, 'E');
    expect(_dms(tags['GPS GPSLatitude']!), closeTo(fix.latitude, 1e-6));
    expect(_dms(tags['GPS GPSLongitude']!), closeTo(fix.longitude, 1e-6));
    expect(tags['GPS GPSDate']?.printable ?? tags['GPS GPSDateStamp']?.printable, '2026:10:11');
    expect(tags['Image Orientation']?.values.firstAsInt(), 6);

    // 画素は描き直していない（EXIF の外は同じ）
    final a = img.decodeJpg(src)!;
    final b = img.decodeJpg(out)!;
    expect(b.width, a.width);
    expect(b.getPixel(3, 3).g, a.getPixel(3, 3).g);
  });

  test('南緯・西経は Ref で表す', () async {
    final out = ExifGpsWriter.addIfMissing(_jpeg(), const LatLng(-12.5, -45.25))!;
    final tags = await readExifFromBytes(out);
    expect(tags['GPS GPSLatitudeRef']?.printable, 'S');
    expect(tags['GPS GPSLongitudeRef']?.printable, 'W');
    expect(_dms(tags['GPS GPSLongitude']!), closeTo(45.25, 1e-6));
  });

  test('カメラアプリが位置を書いていれば触らない', () {
    final src = _jpeg(gps: const LatLng(34, 136));
    expect(ExifGpsWriter.hasGps(src), isTrue);
    expect(ExifGpsWriter.addIfMissing(src, fix), isNull);
  });

  test('JPEG でなければ何もしない', () {
    final png = img.encodePng(img.Image(width: 2, height: 2));
    expect(ExifGpsWriter.addIfMissing(png, fix), isNull);
  });
}
