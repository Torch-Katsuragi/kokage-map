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
// こかげマップ: JPEG に撮影位置（EXIF GPS）が無ければ足す
//
// カメラアプリの位置情報が切ってあると、撮った写真に位置が入らない。地物に付ける写真は
// 「どこで撮ったか」が要るので、アプリの GPS の今の位置を入れる。
// 画素は描き直さない（APP1 の EXIF だけ差し替える。向き Orientation などほかの EXIF は残す）。

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

class ExifGpsWriter {
  ExifGpsWriter._();

  /// [jpeg] に GPS の緯度経度が入っているか
  static bool hasGps(Uint8List jpeg) {
    final exif = img.decodeJpgExif(jpeg);
    if (exif == null) return false;
    final gps = exif.gpsIfd;
    return gps.hasGPSLatitude && gps.hasGPSLongitude;
  }

  /// GPS が無ければ [fix] を書き込んだ JPEG を返す。既にあるか、JPEG でなければ null（元のまま使う）
  static Uint8List? addIfMissing(Uint8List jpeg, LatLng fix, {double? altitude, DateTime? time}) {
    if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
    final exif = img.decodeJpgExif(jpeg) ?? img.ExifData();
    final gps = exif.gpsIfd;
    if (gps.hasGPSLatitude && gps.hasGPSLongitude) return null;

    // 規格どおり RATIONAL ×3（度・分・秒）で書く。image の setGpsLocation は DOUBLE 型で書くので
    // 読めない読み手がある（このアプリの ExifParser も RATIONAL しか読まない）
    gps.data[0x0000] = img.IfdByteValue.list(Uint8List.fromList([2, 3, 0, 0])); // GPSVersionID
    gps.data[0x0001] = img.IfdValueAscii(fix.latitude < 0 ? 'S' : 'N');
    gps.data[0x0002] = _dms(fix.latitude.abs());
    gps.data[0x0003] = img.IfdValueAscii(fix.longitude < 0 ? 'W' : 'E');
    gps.data[0x0004] = _dms(fix.longitude.abs());
    if (altitude != null && altitude.isFinite) {
      gps.data[0x0005] = img.IfdByteValue.list(Uint8List.fromList([altitude < 0 ? 1 : 0])); // GPSAltitudeRef
      gps.data[0x0006] = img.IfdValueRational((altitude.abs() * 100).round(), 100);
    }
    if (time != null) {
      final u = time.toUtc();
      gps.data[0x0007] = rationals([(u.hour, 1), (u.minute, 1), (u.second, 1)]); // GPSTimeStamp
      String two(int v) => v.toString().padLeft(2, '0');
      gps.data[0x001D] = img.IfdValueAscii('${u.year}:${two(u.month)}:${two(u.day)}'); // GPSDateStamp
    }
    return img.injectJpgExif(jpeg, exif);
  }

  /// 十進の度 → 度・分・秒（秒は 1/10000 秒まで）
  static img.IfdValueRational _dms(double value) {
    final deg = value.floor();
    final minFull = (value - deg) * 60;
    final min = minFull.floor();
    final sec = ((minFull - min) * 60 * 10000).round();
    return rationals([(deg, 1), (min, 1), (sec, 10000)]);
  }

  /// 複数の RATIONAL（`Rational` は image から公開されていないので 1 つずつ作って束ねる）
  static img.IfdValueRational rationals(List<(int, int)> values) =>
      img.IfdValueRational.list([for (final (n, d) in values) img.IfdValueRational(n, d).value.single]);
}
