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
// Root Maps: EXIF解析ユーティリティ
// 画像ファイルからGPS座標やメタデータを抽出する共通処理
// ImageNodeとGlobalImageNodeで使用

import 'dart:typed_data';
import 'package:exif/exif.dart';
import 'package:latlong2/latlong.dart';
import '../core/fs/k_file_system.dart';
import 'app_logger.dart';

/// 画像のEXIFデータから抽出した情報
class ExifImageData {
  final LatLng location;
  final DateTime? takenAt;
  final ImageMetadata metadata;

  /// 撮影方向（真北基準、0-360度）。EXIFのGPSImgDirectionから取得
  final double? direction;

  ExifImageData({required this.location, this.takenAt, required this.metadata, this.direction});
}

/// 画像ファイルのメタデータ
class ImageMetadata {
  final int fileSize;
  final int? width;
  final int? height;
  final String? camera;

  ImageMetadata({required this.fileSize, this.width, this.height, this.camera});
}

/// EXIF解析ユーティリティクラス
///
/// exifパッケージを使用してGPS座標やメタデータを抽出する静的メソッドを提供
/// 高速化のため、ファイル先頭部分（1MB）のみを読み込む
class ExifParser {
  ExifParser._();

  /// 画像ファイルからEXIFデータを抽出
  /// GPS座標が含まれていない場合はnullを返す
  static Future<ExifImageData?> extractFromFile(String filePath) async {
    try {
      final fileSize = await fs.length(filePath);
      if (fileSize == null) return null;

      // 電子小黒板等のメタデータが大きい画像にも対応するため1MBまで読む
      final bytes = await _readFileHeader(filePath, 1024 * 1024);
      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return null;

      final location = _extractGpsLocation(tags);
      if (location == null) return null;

      return ExifImageData(
        location: location,
        takenAt: _extractDateTime(tags),
        metadata: ImageMetadata(
          fileSize: fileSize,
          width: _extractInt(tags, 'EXIF ExifImageWidth') ??
              _extractInt(tags, 'Image ImageWidth'),
          height: _extractInt(tags, 'EXIF ExifImageLength') ??
              _extractInt(tags, 'Image ImageLength'),
          camera: _extractCamera(tags),
        ),
        direction: _extractGpsDirection(tags),
      );
    } catch (e) {
      AppLogger.debug('[ERROR] ExifParser.extractFromFile: $e');
      return null;
    }
  }

  /// 先頭 [maxBytes] だけ読む。
  ///
  /// ⚠ 以前は `RandomAccessFile` で部分読みしていたが、ファイルシステム抽象には
  /// 部分読みが無い（File System Access API 側も Blob.slice 経由になり、
  /// 抽象に載せると面倒が増える）。EXIFを見るのは高々1MBなので全部読んで切る。
  static Future<Uint8List> _readFileHeader(String filePath, int maxBytes) async {
    final bytes = await fs.readAsBytes(filePath);
    if (bytes.length <= maxBytes) return bytes;
    return Uint8List.sublistView(bytes, 0, maxBytes);
  }

  static LatLng? _extractGpsLocation(Map<String, IfdTag> tags) {
    final latTag = tags['GPS GPSLatitude'];
    final latRefTag = tags['GPS GPSLatitudeRef'];
    final lngTag = tags['GPS GPSLongitude'];
    final lngRefTag = tags['GPS GPSLongitudeRef'];
    if (latTag == null || latRefTag == null || lngTag == null || lngRefTag == null) return null;

    final latValues = latTag.values;
    final lngValues = lngTag.values;
    if (latValues is! IfdRatios || lngValues is! IfdRatios) return null;
    if (latValues.ratios.length < 3 || lngValues.ratios.length < 3) return null;

    final lat = _ratiosDmsToDecimal(latValues.ratios) * (latRefTag.printable == 'S' ? -1 : 1);
    final lng = _ratiosDmsToDecimal(lngValues.ratios) * (lngRefTag.printable == 'W' ? -1 : 1);
    // NaN/Infinityチェック（Ratio 0/0 等で発生しうる）
    if (lat.isNaN || lat.isInfinite || lng.isNaN || lng.isInfinite) return null;
    return LatLng(lat, lng);
  }

  static double _ratiosDmsToDecimal(List<Ratio> dms) {
    return dms[0].toDouble() + (dms[1].toDouble() / 60.0) + (dms[2].toDouble() / 3600.0);
  }

  static double? _extractGpsDirection(Map<String, IfdTag> tags) {
    final tag = tags['GPS GPSImgDirection'];
    if (tag == null) return null;
    final values = tag.values;
    if (values is IfdRatios && values.ratios.isNotEmpty) {
      final dir = values.ratios[0].toDouble();
      if (dir.isNaN || dir.isInfinite) return null;
      return dir;
    }
    return null;
  }

  static DateTime? _extractDateTime(Map<String, IfdTag> tags) {
    final tag = tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'];
    if (tag == null) return null;
    try {
      final parts = tag.printable.split(RegExp(r'[\s:]'));
      if (parts.length >= 6) {
        return DateTime(
          int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]),
          int.parse(parts[3]), int.parse(parts[4]), int.parse(parts[5]),
        );
      }
    } catch (_) {}
    return null;
  }

  static int? _extractInt(Map<String, IfdTag> tags, String key) {
    final tag = tags[key];
    if (tag == null) return null;
    try {
      return tag.values.firstAsInt();
    } catch (_) {
      return null;
    }
  }

  static String? _extractCamera(Map<String, IfdTag> tags) {
    final make = tags['Image Make']?.printable;
    final model = tags['Image Model']?.printable;
    if (make == null && model == null) return null;
    if (make != null && model != null) {
      return model.startsWith(make) ? model : '$make $model';
    }
    return make ?? model;
  }
}
