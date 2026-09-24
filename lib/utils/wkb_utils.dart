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
import 'dart:typed_data';

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

// ============================================================
// GPBinary ヘッダー処理（GeoPackage仕様、geobase スコープ外）
// ============================================================

/// GeoPackage GPBinaryヘッダーを生成
Uint8List _createGpbHeader({
  double? minX,
  double? maxX,
  double? minY,
  double? maxY,
  int srsId = 4326,
}) {
  final header = BytesBuilder();
  header.addByte(0x47); // G
  header.addByte(0x50); // P
  header.addByte(0x00); // Version (0)

  int flags = 0x01; // little endian
  if (minX != null && maxX != null && minY != null && maxY != null) {
    flags |= 1 << 1; // XY envelope (type 1)
  }
  header.addByte(flags);

  final srsBytes = ByteData(4)..setUint32(0, srsId, Endian.little);
  header.add(srsBytes.buffer.asUint8List());

  if (minX != null && maxX != null && minY != null && maxY != null) {
    final env = ByteData(32);
    env.setFloat64(0, minX, Endian.little);
    env.setFloat64(8, maxX, Endian.little);
    env.setFloat64(16, minY, Endian.little);
    env.setFloat64(24, maxY, Endian.little);
    header.add(env.buffer.asUint8List());
  }

  return header.toBytes();
}

/// GPBinaryヘッダーをスキップして純粋WKBバイト列を返す
Uint8List _skipGpbHeader(Uint8List data) {
  if (data.length > 8 && data[0] == 0x47 && data[1] == 0x50) {
    final flags = data[3];
    final envelopeType = (flags >> 1) & 0x07;

    int headerSize = 8;
    switch (envelopeType) {
      case 1:
        headerSize += 32;
      case 2:
      case 3:
        headerSize += 48;
      case 4:
        headerSize += 64;
    }

    if (data.length > headerSize) return data.sublist(headerSize);
  }
  return data;
}

/// GPBinaryヘッダーからsrsIdを抽出する
/// GPBinaryヘッダーがない場合はnullを返す
int? extractSrsIdFromGpkgBlob(Uint8List gpkgBlob) {
  if (gpkgBlob.length >= 8 && gpkgBlob[0] == 0x47 && gpkgBlob[1] == 0x50) {
    return ByteData.sublistView(gpkgBlob, 4, 8).getUint32(0, Endian.little);
  }
  return null;
}


// ============================================================
// 公開 API: GeoPackage blob ↔ geobase Geometry
// ============================================================

/// GeoPackage blob (GPBヘッダー + WKB) → geobase Geometry
/// 型自動判別 (Point/MultiPoint/LineString/MultiLineString/Polygon/MultiPolygon)
geo.Geometry? parseGpkgGeometry(Uint8List gpkgBlob) {
  try {
    final wkb = _skipGpbHeader(gpkgBlob);
    if (wkb.length < 5) return null;
    return geo.GeometryBuilder.decode<geo.Geometry>(wkb);
  } catch (e) {
    AppLogger.debug('[WKB] geobase decode error: $e');
    return null;
  }
}

/// geobase Geometry → GeoPackage blob (GPBヘッダー + WKB)
Uint8List createGpkgWkb(geo.Geometry geom, {int srsId = 4326}) {
  final wkb = geom.toBytes(endian: Endian.little);

  // エンベロープ計算
  double? minX, maxX, minY, maxY;
  void expand(double lon, double lat) {
    minX = (minX == null || lon < minX!) ? lon : minX;
    maxX = (maxX == null || lon > maxX!) ? lon : maxX;
    minY = (minY == null || lat < minY!) ? lat : minY;
    maxY = (maxY == null || lat > maxY!) ? lat : maxY;
  }

  for (final pos in _allPositions(geom)) {
    expand(pos.x, pos.y);
  }

  final gpb = _createGpbHeader(
    minX: minX,
    maxX: maxX,
    minY: minY,
    maxY: maxY,
    srsId: srsId,
  );

  final result = BytesBuilder();
  result.add(gpb);
  result.add(wkb);
  return result.toBytes();
}

/// geobase Geometry → LatLng 中間構造体
///
/// - Point         → `List<LatLng>` (1要素)
/// - MultiPoint    → `List<LatLng>`
/// - LineString    → `List<LatLng>`
/// - MultiLineString → `List<List<LatLng>>`
/// - Polygon       → `List<List<LatLng>>` (rings)
/// - MultiPolygon  → `List<List<List<LatLng>>>` (polygons of rings)
dynamic geobaseGeometryToLatLngs(geo.Geometry geom) {
  if (geom is geo.Point) {
    return [LatLng(geom.position.y, geom.position.x)];
  }
  if (geom is geo.MultiPoint) {
    return geom.positions
        .map((p) => LatLng(p.y, p.x))
        .toList();
  }
  if (geom is geo.LineString) {
    return geom.chain.positions
        .map((p) => LatLng(p.y, p.x))
        .toList();
  }
  if (geom is geo.MultiLineString) {
    return geom.chains
        .map((c) => c.positions.map((p) => LatLng(p.y, p.x)).toList())
        .toList();
  }
  if (geom is geo.Polygon) {
    return geom.rings
        .map((r) => r.positions.map((p) => LatLng(p.y, p.x)).toList())
        .toList();
  }
  if (geom is geo.MultiPolygon) {
    return geom.polygons
        .map(
          (poly) => poly.rings
              .map((r) => r.positions.map((p) => LatLng(p.y, p.x)).toList())
              .toList(),
        )
        .toList();
  }
  return null;
}

/// geobase Geometry の全 Position を列挙する内部ヘルパー
Iterable<geo.Position> _allPositions(geo.Geometry geom) sync* {
  if (geom is geo.Point) {
    yield geom.position;
  } else if (geom is geo.MultiPoint) {
    yield* geom.positions;
  } else if (geom is geo.LineString) {
    yield* geom.chain.positions;
  } else if (geom is geo.MultiLineString) {
    for (final c in geom.chains) {
      yield* c.positions;
    }
  } else if (geom is geo.Polygon) {
    for (final r in geom.rings) {
      yield* r.positions;
    }
  } else if (geom is geo.MultiPolygon) {
    for (final poly in geom.polygons) {
      for (final r in poly.rings) {
        yield* r.positions;
      }
    }
  }
}

/// GeoPackage blob の範囲（rtree に入れる値）。空ジオメトリ・壊れた blob は null。
///
/// ヘッダーに範囲があればそれを読み、無ければ WKB を解いて座標から出す。
({double minX, double maxX, double minY, double maxY})? gpkgEnvelope(Uint8List blob) {
  if (blob.length >= 8 && blob[0] == 0x47 && blob[1] == 0x50) {
    final flags = blob[3];
    if ((flags >> 4) & 0x01 == 1) return null; // 空ジオメトリ
    final envelopeType = (flags >> 1) & 0x07;
    if (envelopeType >= 1 && envelopeType <= 4 && blob.length >= 8 + 32) {
      final endian = (flags & 0x01) == 1 ? Endian.little : Endian.big;
      final bd = ByteData.sublistView(blob, 8, 8 + 32);
      final minX = bd.getFloat64(0, endian);
      final maxX = bd.getFloat64(8, endian);
      final minY = bd.getFloat64(16, endian);
      final maxY = bd.getFloat64(24, endian);
      if (!minX.isNaN && !maxX.isNaN && !minY.isNaN && !maxY.isNaN) {
        return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
      }
    }
  }
  final geom = parseGpkgGeometry(blob);
  if (geom == null) return null;
  double? minX, maxX, minY, maxY;
  for (final pos in _allPositions(geom)) {
    final x = pos.x;
    final y = pos.y;
    if (x.isNaN || y.isNaN) continue;
    minX = minX == null || x < minX ? x : minX;
    maxX = maxX == null || x > maxX ? x : maxX;
    minY = minY == null || y < minY ? y : minY;
    maxY = maxY == null || y > maxY ? y : maxY;
  }
  if (minX == null || maxX == null || minY == null || maxY == null) return null;
  return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

// ============================================================
// レガシーAPI互換（既存呼び出し元の移行が完了するまで維持）
// ============================================================

/// WKB(Point)生成 - GeoPackage対応 (レガシー)
Uint8List createWkbPoint(double lon, double lat) =>
    createGpkgWkb(geo.Point(geo.Geographic(lon: lon, lat: lat)));

/// WKB(LineString)生成 - GeoPackage対応 (レガシー)
Uint8List createWkbLineString(List<LatLng> line) {
  if (line.isEmpty) return Uint8List(0);
  return createGpkgWkb(
    geo.LineString.from(
      line.map((p) => geo.Geographic(lon: p.longitude, lat: p.latitude)),
    ),
  );
}

/// WKB(Polygon)生成 - GeoPackage対応 (レガシー)
Uint8List createWkbPolygon(List<List<LatLng>> rings) {
  if (rings.isEmpty || rings.first.isEmpty) return Uint8List(0);
  return createGpkgWkb(
    geo.Polygon.from(
      rings.map(
        (ring) =>
            ring.map((p) => geo.Geographic(lon: p.longitude, lat: p.latitude)),
      ),
    ),
  );
}

// ============================================================
// 診断ユーティリティ（デバッグ用）
// ============================================================

/// WKBデータの妥当性を検証
bool validateWkbData(Uint8List wkb) {
  try {
    if (wkb.length < 8) return false;
    if (wkb[0] == 0x47 && wkb[1] == 0x50) {
      return wkb.length >= 29; // GPB(8) + WKB最小(21)
    }
    return wkb.length >= 21;
  } catch (e) {
    AppLogger.debug('[WKB検証] エラー: $e');
    return false;
  }
}

/// WKBデータの詳細情報を出力（デバッグ用）
void debugWkbData(Uint8List wkb, String context) {
  AppLogger.debug('=== WKBデバッグ情報 [$context] ===');
  AppLogger.debug('データサイズ: ${wkb.length}バイト');
  AppLogger.debug(
    '先頭16バイト: ${wkb.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
  );

  if (wkb.length >= 8 && wkb[0] == 0x47 && wkb[1] == 0x50) {
    final srsId = ByteData.sublistView(wkb, 4, 8).getUint32(0, Endian.little);
    AppLogger.debug('GPBinaryヘッダー: あり（SRS ID: $srsId）');
  } else {
    AppLogger.debug('GPBinaryヘッダー: なし');
  }

  final geom = parseGpkgGeometry(wkb);
  AppLogger.debug('geobase decode: ${geom?.runtimeType ?? "FAILED"}');
  AppLogger.debug('妥当性: ${validateWkbData(wkb) ? "OK" : "NG"}');
  AppLogger.debug('==============================');
}

