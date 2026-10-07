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
// Root Maps: Shapefile Binary Parser
// SHPファイルのバイナリ解析クラス
import 'dart:io';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../../coordinate/epsg_registry.dart';
import '../../coordinate/projections.dart';

/// シェープファイルのタイプ定数
class ShapeType {
  static const int nullShape = 0;
  static const int point = 1;
  static const int polyLine = 3;
  static const int polygon = 5;
  static const int multiPoint = 8;
  static const int pointZ = 11;
  static const int polyLineZ = 13;
  static const int polygonZ = 15;
  static const int multiPointZ = 18;
  static const int pointM = 21;
  static const int polyLineM = 23;
  static const int polygonM = 25;
  static const int multiPointM = 28;
}

/// SHP のレコード 1 件（形を読めたもの）
class ShpRecord {
  const ShpRecord(this.index, this.shapeType, this.geometry);

  /// ファイル内の 0 始まりの順番（形が無い・読めないレコードも数える。DBF の行と同じ順番）
  final int index;

  /// [ShapeType] の値
  final int shapeType;

  /// 点は [LatLng]、線は `List<LatLng>`、面はリングの `List<List<LatLng>>`（WGS84）
  final Object geometry;
}

/// シェープファイルのバイナリ解析クラス
class ShapefileBinaryParser {
  /// SHP ファイルの中身。無い・読めなければ null
  static Future<Uint8List?> readBytes(String shpFilePath) async {
    try {
      AppLogger.debug('[ShpParser] シェープファイル読み込み: $shpFilePath');
      final shpFile = File(shpFilePath);
      if (!shpFile.existsSync()) return null;
      return await shpFile.readAsBytes();
    } catch (e) {
      AppLogger.debug('[ShpParser] 読み込みエラー: $e');
      return null;
    }
  }

  /// [bytes]（SHP ファイルの中身）のヘッダから基本情報を読む。短すぎれば null
  static Map<String, dynamic>? infoFromBytes(Uint8List bytes) {
    if (bytes.length < 100) {
      AppLogger.debug('[ShpParser] SHPファイルが小さすぎます: ${bytes.length}bytes');
      return null;
    }
    final data = ByteData.sublistView(bytes);

    // ヘッダーからシェープタイプを読み取り
    final shapeType = data.getInt32(32, Endian.little);
    final geometryType = _shapeTypeToGeometryString(shapeType);
    final estimatedCount = _estimateFeatureCount(shapeType, bytes.length);

    AppLogger.debug('[ShpParser] ジオメトリタイプ: $geometryType');
    AppLogger.debug('[ShpParser] 推定フィーチャ数: $estimatedCount');

    return {
      'geometryType': geometryType,
      'shapeType': shapeType,
      'featureCount': estimatedCount,
      'fileSize': bytes.length,
      'bounds': {
        'minX': data.getFloat64(36, Endian.little),
        'minY': data.getFloat64(44, Endian.little),
        'maxX': data.getFloat64(52, Endian.little),
        'maxY': data.getFloat64(60, Endian.little),
      },
    };
  }

  /// シェープタイプからジオメトリタイプ文字列に変換（点の仲間と未知のものは Point）
  static String _shapeTypeToGeometryString(int shapeType) => switch (shapeType) {
    ShapeType.polyLine || ShapeType.polyLineZ || ShapeType.polyLineM => 'LineString',
    ShapeType.polygon || ShapeType.polygonZ || ShapeType.polygonM => 'Polygon',
    _ => 'Point',
  };

  /// ファイルサイズからフィーチャ数を推定
  static int _estimateFeatureCount(int shapeType, int fileSize) => switch (shapeType) {
    ShapeType.point || ShapeType.pointM => (fileSize / 50).round().clamp(1, 100000),
    ShapeType.pointZ => (fileSize / 60).round().clamp(1, 80000),
    ShapeType.polyLine || ShapeType.polyLineM => (fileSize / 200).round().clamp(1, 10000),
    ShapeType.polyLineZ => (fileSize / 250).round().clamp(1, 8000),
    ShapeType.polygon || ShapeType.polygonM => (fileSize / 500).round().clamp(1, 5000),
    ShapeType.polygonZ => (fileSize / 600).round().clamp(1, 4000),
    _ => (fileSize / 100).round().clamp(1, 10000),
  };

  /// シェープファイルの全レコードを解析
  /// [shpFilePath] SHPファイルパス
  /// [sourceCoordinateSystem] 元の座標系（座標変換用）
  /// [onRecord] レコードごとのコールバック。recordIndex は [ShpRecord.index]
  static Future<int> parseRecords(
    String shpFilePath, {
    EpsgDefinition? sourceCoordinateSystem,
    required Future<void> Function(int recordIndex, int shapeType, dynamic geometry) onRecord,
  }) async {
    AppLogger.debug('[ShpParser] レコード解析開始: $shpFilePath');
    final bytes = await File(shpFilePath).readAsBytes();
    var count = 0;
    for (final r in records(bytes, sourceCoordinateSystem: sourceCoordinateSystem)) {
      await onRecord(r.index, r.shapeType, r.geometry);
      count++;
    }
    return count;
  }

  /// [bytes]（SHP ファイルの中身）のレコードを先頭から順に読む。形を読めたものだけを返す。
  ///
  /// 座標は [sourceCoordinateSystem] から WGS84 に直す（null なら WGS84 とみなし、範囲外は捨てる）。
  /// レコードごとに待たずに読めるよう同期で返す（大きなファイルで効く）
  static Iterable<ShpRecord> records(
    Uint8List bytes, {
    EpsgDefinition? sourceCoordinateSystem,
  }) sync* {
    if (bytes.length < 100) {
      throw Exception('SHPファイルが小さすぎます');
    }
    final reader = _RecordReader(bytes, _ToWgs84(sourceCoordinateSystem));

    int offset = 100; // ヘッダー後
    int recordCount = 0;
    int recordIndex = -1;

    while (offset < bytes.length - 8) {
      ShpRecord? record;
      try {
        // レコードヘッダー
        final contentLength = reader.data.getInt32(offset + 4, Endian.big);
        offset += 8;

        if (contentLength <= 0 || offset + (contentLength * 2) > bytes.length) {
          break;
        }
        recordIndex++;

        // レコードシェープタイプ
        final recordShapeType = reader.data.getInt32(offset, Endian.little);
        offset += 4;

        // ジオメトリを解析
        final (Object? geometry, int geometryBytes) = switch (recordShapeType) {
          ShapeType.point => (reader.point(offset), 16),
          ShapeType.polyLine => reader.polyLine(offset),
          ShapeType.polygon => reader.polygon(offset),
          _ => (null, (contentLength * 2) - 4),
        };
        if (geometry != null) {
          record = ShpRecord(recordIndex, recordShapeType, geometry);
          recordCount++;
        }
        offset += geometryBytes;

        // 進捗ログ
        if (recordCount < 10 ||
            (recordCount < 1000 && recordCount % 100 == 0) ||
            (recordCount >= 1000 && recordCount % 500 == 0)) {
          AppLogger.debug('[ShpParser] 解析中: $recordCount件');
        }
      } catch (e) {
        AppLogger.debug('[ShpParser] レコード解析エラー (offset: $offset): $e');
        break;
      }
      if (record != null) yield record;
    }

    AppLogger.debug('[ShpParser] 解析完了: $recordCount件');
  }
}

/// 元の座標系 → WGS84。投影は最初に 1 回だけ用意する
class _ToWgs84 {
  _ToWgs84(EpsgDefinition? source)
    : _hasSource = source != null,
      _projection = source == null ? null : Projections.parse(source.proj4String);

  final bool _hasSource;
  final Projection? _projection;

  /// 変換できない・WGS84 の範囲外なら null
  LatLng? call(double x, double y) {
    if (!_hasSource) {
      // 座標変換なし、WGS84範囲チェック
      if (x >= -180 && x <= 180 && y >= -90 && y <= 90) return LatLng(y, x);
      return null;
    }
    final projection = _projection;
    if (projection == null) return null;
    try {
      final transformed = projection.transform(Projections.wgs84, Point(x: x, y: y));
      final latLng = LatLng(transformed.y, transformed.x);
      // 変換後の座標がWGS84の妥当な範囲内かチェック
      if (latLng.latitude >= -90 &&
          latLng.latitude <= 90 &&
          latLng.longitude >= -180 &&
          latLng.longitude <= 180) {
        return latLng;
      }
    } catch (e) {
      // 変換失敗
    }
    return null;
  }
}

/// レコードの中身を読む。返すバイト数はシェープタイプの後ろから読んだぶん
class _RecordReader {
  _RecordReader(this.bytes, this.toWgs84) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  final _ToWgs84 toWgs84;

  double _f64(int offset) => data.getFloat64(offset, Endian.little);
  int _i32(int offset) => data.getInt32(offset, Endian.little);

  LatLng? point(int offset) {
    if (offset + 16 > bytes.length) return null;
    final x = _f64(offset);
    final y = _f64(offset + 8);
    if (!x.isFinite || !y.isFinite) return null;
    return toWgs84(x, y);
  }

  /// 部分の区切りは見ず、全部の点を 1 本の線にする。変換できない点は飛ばす
  (List<LatLng>?, int) polyLine(int start) {
    var offset = start + 32; // Bounding Box スキップ
    final numParts = _i32(offset);
    final numPoints = _i32(offset + 4);
    offset += 8 + numParts * 4; // Partsをスキップ

    final coordinates = <LatLng>[];
    for (int i = 0; i < numPoints && offset + 16 <= bytes.length; i++) {
      final x = _f64(offset);
      final y = _f64(offset + 8);
      offset += 16;
      if (x.isFinite && y.isFinite) {
        final point = toWgs84(x, y);
        if (point != null) coordinates.add(point);
      }
    }
    return (coordinates.isNotEmpty ? coordinates : null, offset - start);
  }

  /// 3 点未満のリングは捨てる。変換できない点があれば面ごと捨てる
  (List<List<LatLng>>?, int) polygon(int start) {
    var offset = start + 32; // Bounding Box スキップ
    final numParts = _i32(offset);
    final numPoints = _i32(offset + 4);
    offset += 8;

    final parts = <int>[];
    for (int i = 0; i < numParts; i++) {
      parts.add(_i32(offset));
      offset += 4;
    }

    final allPoints = <LatLng>[];
    var failed = false;
    for (int i = 0; i < numPoints && offset + 16 <= bytes.length; i++) {
      final x = _f64(offset);
      final y = _f64(offset + 8);
      offset += 16;
      if (failed || !x.isFinite || !y.isFinite) continue;
      final point = toWgs84(x, y);
      if (point == null) {
        failed = true;
      } else {
        allPoints.add(point);
      }
    }
    // 座標変換に失敗した場合、このポリゴンは無効（点は最後まで読み進めて、次のレコードの頭に合わせる）
    if (failed) return (null, offset - start);

    // リングに分割
    final rings = <List<LatLng>>[];
    for (int i = 0; i < parts.length; i++) {
      final startIndex = parts[i];
      final endIndex = i + 1 < parts.length ? parts[i + 1] : allPoints.length;
      if (startIndex < allPoints.length && endIndex <= allPoints.length) {
        final ring = allPoints.sublist(startIndex, endIndex);
        if (ring.length >= 3) rings.add(ring);
      }
    }
    return (rings.isNotEmpty ? rings : null, offset - start);
  }
}
