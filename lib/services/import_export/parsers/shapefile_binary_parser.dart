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
import 'package:root_maps/utils/app_logger.dart';
import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';
import '../../coordinate/epsg_registry.dart';
import '../../../utils/binary_utils.dart';
import '../coordinate_system_manager.dart';

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

/// シェープファイルのヘッダー情報
class ShapefileHeader {
  final int fileCode;
  final int fileLength;
  final int version;
  final int shapeType;
  final BoundingBox bounds;

  ShapefileHeader({
    required this.fileCode,
    required this.fileLength,
    required this.version,
    required this.shapeType,
    required this.bounds,
  });
}

/// シェープファイルのレコード
class ShapefileRecord {
  final int recordNumber;
  final int shapeType;
  final dynamic geometry; // LatLng, List<LatLng>, List<List<LatLng>> depending on type

  ShapefileRecord({
    required this.recordNumber,
    required this.shapeType,
    required this.geometry,
  });
}

/// シェープファイルのバイナリ解析クラス
class ShapefileBinaryParser {
  static final SmartCoordinateSystemManager _crsManager =
      SmartCoordinateSystemManager();

  // デバッグ出力制御用フラグ
  static bool _hasLoggedFirstPointConversion = false;
  static bool _hasLoggedFirstPolylineConversion = false;
  static bool _hasLoggedFirstPolygonConversion = false;

  /// デバッグフラグをリセット（新規インポート時に呼び出す）
  static void resetDebugFlags() {
    _hasLoggedFirstPointConversion = false;
    _hasLoggedFirstPolylineConversion = false;
    _hasLoggedFirstPolygonConversion = false;
  }

  /// シェープファイルの基本情報を読み込み
  static Future<Map<String, dynamic>?> readInfo(String shpFilePath) async {
    try {
      AppLogger.debug('[ShpParser] シェープファイル基本情報読み込み: $shpFilePath');

      final shpFile = File(shpFilePath);
      if (!shpFile.existsSync()) return null;

      final fileSize = shpFile.lengthSync();
      final bytes = await shpFile.readAsBytes();
      
      if (bytes.length < 100) {
        AppLogger.debug('[ShpParser] SHPファイルが小さすぎます: ${bytes.length}bytes');
        return null;
      }

      // ヘッダーからシェープタイプを読み取り
      final shapeType = BinaryUtils.readInt32LittleEndian(bytes, 32);
      final geometryType = _shapeTypeToGeometryString(shapeType);
      final estimatedCount = _estimateFeatureCount(shapeType, fileSize);

      AppLogger.debug('[ShpParser] ジオメトリタイプ: $geometryType');
      AppLogger.debug('[ShpParser] 推定フィーチャ数: $estimatedCount');

      return {
        'geometryType': geometryType,
        'shapeType': shapeType,
        'featureCount': estimatedCount,
        'fileSize': fileSize,
        'bounds': {
          'minX': BinaryUtils.readFloat64LittleEndian(bytes, 36),
          'minY': BinaryUtils.readFloat64LittleEndian(bytes, 44),
          'maxX': BinaryUtils.readFloat64LittleEndian(bytes, 52),
          'maxY': BinaryUtils.readFloat64LittleEndian(bytes, 60),
        },
      };
    } catch (e) {
      AppLogger.debug('[ShpParser] 基本情報読み込みエラー: $e');
      return null;
    }
  }

  /// シェープタイプからジオメトリタイプ文字列に変換
  static String _shapeTypeToGeometryString(int shapeType) {
    switch (shapeType) {
      case ShapeType.point:
      case ShapeType.pointZ:
      case ShapeType.pointM:
      case ShapeType.multiPoint:
      case ShapeType.multiPointZ:
      case ShapeType.multiPointM:
        return 'Point';
      case ShapeType.polyLine:
      case ShapeType.polyLineZ:
      case ShapeType.polyLineM:
        return 'LineString';
      case ShapeType.polygon:
      case ShapeType.polygonZ:
      case ShapeType.polygonM:
        return 'Polygon';
      default:
        return 'Point';
    }
  }

  /// ファイルサイズからフィーチャ数を推定
  static int _estimateFeatureCount(int shapeType, int fileSize) {
    switch (shapeType) {
      case ShapeType.point:
      case ShapeType.pointM:
        return (fileSize / 50).round().clamp(1, 100000);
      case ShapeType.pointZ:
        return (fileSize / 60).round().clamp(1, 80000);
      case ShapeType.polyLine:
      case ShapeType.polyLineM:
        return (fileSize / 200).round().clamp(1, 10000);
      case ShapeType.polyLineZ:
        return (fileSize / 250).round().clamp(1, 8000);
      case ShapeType.polygon:
      case ShapeType.polygonM:
        return (fileSize / 500).round().clamp(1, 5000);
      case ShapeType.polygonZ:
        return (fileSize / 600).round().clamp(1, 4000);
      default:
        return (fileSize / 100).round().clamp(1, 10000);
    }
  }

  /// シェープファイルの全レコードを解析
  /// [shpFilePath] SHPファイルパス
  /// [sourceCoordinateSystem] 元の座標系（座標変換用）
  /// [onRecord] レコードごとのコールバック
  static Future<int> parseRecords(
    String shpFilePath, {
    EpsgDefinition? sourceCoordinateSystem,
    required Future<void> Function(int recordIndex, int shapeType, dynamic geometry) onRecord,
  }) async {
    try {
      AppLogger.debug('[ShpParser] レコード解析開始: $shpFilePath');
      resetDebugFlags();

      final shpFile = File(shpFilePath);
      final bytes = await shpFile.readAsBytes();

      if (bytes.length < 100) {
        throw Exception('SHPファイルが小さすぎます');
      }

      // ファイル全体のシェープタイプ（参考情報）
      // final shapeType = BinaryUtils.readInt32LittleEndian(bytes, 32);
      int offset = 100; // ヘッダー後
      int recordCount = 0;

      while (offset < bytes.length - 8) {
        try {
          // レコードヘッダー
          final recordNumber = BinaryUtils.readInt32BigEndian(bytes, offset);
          final contentLength = BinaryUtils.readInt32BigEndian(bytes, offset + 4);
          offset += 8;

          if (contentLength <= 0 || offset + (contentLength * 2) > bytes.length) {
            break;
          }

          // レコードシェープタイプ
          final recordShapeType = BinaryUtils.readInt32LittleEndian(bytes, offset);
          offset += 4;

          // ジオメトリを解析
          dynamic geometry;
          int geometryBytes = 0;

          switch (recordShapeType) {
            case ShapeType.point:
              geometry = await _parsePoint(bytes, offset, sourceCoordinateSystem);
              geometryBytes = 16;
              break;
            case ShapeType.polyLine:
              final result = await _parsePolyLine(bytes, offset, contentLength, sourceCoordinateSystem);
              geometry = result['geometry'];
              geometryBytes = result['bytesRead'] as int;
              break;
            case ShapeType.polygon:
              final result = await _parsePolygon(bytes, offset, contentLength, sourceCoordinateSystem);
              geometry = result['geometry'];
              geometryBytes = result['bytesRead'] as int;
              break;
            default:
              geometryBytes = (contentLength * 2) - 4;
          }

          if (geometry != null) {
            await onRecord(recordNumber, recordShapeType, geometry);
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
      }

      AppLogger.debug('[ShpParser] 解析完了: $recordCount件');
      return recordCount;
    } catch (e) {
      AppLogger.debug('[ShpParser] レコード解析エラー: $e');
      rethrow;
    }
  }

  /// Pointジオメトリを解析
  static Future<LatLng?> _parsePoint(
    Uint8List bytes,
    int offset,
    EpsgDefinition? sourceCoordinateSystem,
  ) async {
    if (offset + 16 > bytes.length) return null;

    final x = BinaryUtils.readFloat64LittleEndian(bytes, offset);
    final y = BinaryUtils.readFloat64LittleEndian(bytes, offset + 8);

    if (!x.isFinite || !y.isFinite) return null;

    return _transformCoordinate(x, y, sourceCoordinateSystem, 'Point');
  }

  /// PolyLineジオメトリを解析
  static Future<Map<String, dynamic>> _parsePolyLine(
    Uint8List bytes,
    int offset,
    int contentLength,
    EpsgDefinition? sourceCoordinateSystem,
  ) async {
    final startOffset = offset;
    
    // Bounding Box スキップ
    offset += 32;

    final numParts = BinaryUtils.readInt32LittleEndian(bytes, offset);
    final numPoints = BinaryUtils.readInt32LittleEndian(bytes, offset + 4);
    offset += 8;

    if (!_hasLoggedFirstPolylineConversion) {
      AppLogger.debug('[ShpParser] PolyLine: $numParts parts, $numPoints points');
    }

    // Partsをスキップ
    offset += numParts * 4;

    // Pointsを読み込み
    final coordinates = <LatLng>[];
    for (int i = 0; i < numPoints && offset + 16 <= bytes.length; i++) {
      final x = BinaryUtils.readFloat64LittleEndian(bytes, offset);
      final y = BinaryUtils.readFloat64LittleEndian(bytes, offset + 8);
      offset += 16;

      if (x.isFinite && y.isFinite) {
        final point = await _transformCoordinate(x, y, sourceCoordinateSystem, 'PolyLine');
        if (point != null) {
          coordinates.add(point);
        }
      }
    }

    _hasLoggedFirstPolylineConversion = true;

    return {
      'geometry': coordinates.isNotEmpty ? coordinates : null,
      'bytesRead': offset - startOffset,
    };
  }

  /// Polygonジオメトリを解析
  static Future<Map<String, dynamic>> _parsePolygon(
    Uint8List bytes,
    int offset,
    int contentLength,
    EpsgDefinition? sourceCoordinateSystem,
  ) async {
    final startOffset = offset;
    
    // Bounding Box スキップ
    offset += 32;

    final numParts = BinaryUtils.readInt32LittleEndian(bytes, offset);
    final numPoints = BinaryUtils.readInt32LittleEndian(bytes, offset + 4);
    offset += 8;

    if (!_hasLoggedFirstPolygonConversion) {
      AppLogger.debug('[ShpParser] Polygon: $numParts rings, $numPoints points');
    }

    // Parts配列を読み込み
    final parts = <int>[];
    for (int i = 0; i < numParts; i++) {
      parts.add(BinaryUtils.readInt32LittleEndian(bytes, offset));
      offset += 4;
    }

    // 全ポイントを読み込み
    final allPoints = <LatLng>[];
    for (int i = 0; i < numPoints && offset + 16 <= bytes.length; i++) {
      final x = BinaryUtils.readFloat64LittleEndian(bytes, offset);
      final y = BinaryUtils.readFloat64LittleEndian(bytes, offset + 8);
      offset += 16;

      if (x.isFinite && y.isFinite) {
        final point = await _transformCoordinate(x, y, sourceCoordinateSystem, 'Polygon');
        if (point != null) {
          allPoints.add(point);
        } else {
          // 座標変換に失敗した場合、このポリゴンは無効
          _hasLoggedFirstPolygonConversion = true;
          return {'geometry': null, 'bytesRead': offset - startOffset};
        }
      }
    }

    // リングに分割
    final rings = <List<LatLng>>[];
    for (int i = 0; i < parts.length; i++) {
      final startIndex = parts[i];
      final endIndex = i + 1 < parts.length ? parts[i + 1] : allPoints.length;

      if (startIndex < allPoints.length && endIndex <= allPoints.length) {
        final ring = allPoints.sublist(startIndex, endIndex);
        if (ring.length >= 3) {
          rings.add(ring);
        }
      }
    }

    _hasLoggedFirstPolygonConversion = true;

    return {
      'geometry': rings.isNotEmpty ? rings : null,
      'bytesRead': offset - startOffset,
    };
  }

  /// 座標変換（元座標系→WGS84）
  static Future<LatLng?> _transformCoordinate(
    double x,
    double y,
    EpsgDefinition? sourceCoordinateSystem,
    String geometryType,
  ) async {
    if (sourceCoordinateSystem != null) {
      try {
        final sourceProjection = _crsManager.getProjection(
          sourceCoordinateSystem.proj4String,
        );
        final wgs84Projection = _crsManager.getProjection('EPSG:4326');

        if (sourceProjection != null && wgs84Projection != null) {
          final point = Point(x: x, y: y);
          final transformedPoint = sourceProjection.transform(wgs84Projection, point);
          final latLng = LatLng(transformedPoint.y, transformedPoint.x);

          // 変換後の座標がWGS84の妥当な範囲内かチェック
          if (latLng.latitude >= -90 && latLng.latitude <= 90 &&
              latLng.longitude >= -180 && latLng.longitude <= 180) {
            // 最初の1回だけ詳細ログ
            if ((geometryType == 'Point' && !_hasLoggedFirstPointConversion) ||
                (geometryType == 'PolyLine' && !_hasLoggedFirstPolylineConversion) ||
                (geometryType == 'Polygon' && !_hasLoggedFirstPolygonConversion)) {
              AppLogger.debug('[ShpParser] 座標変換: ($x, $y) -> (${latLng.latitude}, ${latLng.longitude})');
              if (geometryType == 'Point') _hasLoggedFirstPointConversion = true;
            }
            return latLng;
          }
        }
      } catch (e) {
        // 変換失敗
      }
      return null;
    } else {
      // 座標変換なし、WGS84範囲チェック
      if (x >= -180 && x <= 180 && y >= -90 && y <= 90) {
        return LatLng(y, x);
      }
      return null;
    }
  }
}

