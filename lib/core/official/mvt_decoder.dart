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

/// Mapbox Vector Tile (MVT v2.1 / `.pbf`) の純粋 Dart デコーダ。
///
/// 同梱 GDAL は MVT ドライバを持たないため、Protobuf の 3 メッセージ構造
/// (`Tile` → `Layer` → `Feature`) とジグザグ整数コマンドを直接解き、
/// タイル座標 (`z/x/y`) から WGS84 (`geobase` の `Feature<Geometry>`) へ変換する。
/// Web (JS 数値表現) でも上位ビットが欠けないよう 64bit varint は算術積で読む。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoder;
import 'package:geobase/geobase.dart' as geo;

/// MVT デコード結果（1 タイル分）
class MvtTile {
  const MvtTile(this.layers);

  final Map<String, List<geo.Feature<geo.Geometry>>> layers;

  bool get isEmpty => layers.values.every((fs) => fs.isEmpty);

  List<geo.Feature<geo.Geometry>> allFeatures([String? sourceLayer]) {
    if (sourceLayer != null) return layers[sourceLayer] ?? const [];
    if (layers.length == 1) return layers.values.first;
    return [for (final list in layers.values) ...list];
  }
}

/// MVT v2.1 デコーダ
class MvtDecoder {
  MvtDecoder._();

  static const GZipDecoder _gzip = GZipDecoder();

  /// `.pbf` バイト列（gzip 圧縮または非圧縮）を WGS84 の地物群へ変換する。
  /// [sourceLayer] を指定するとそのレイヤだけ展開し、他レイヤは読み飛ばす。
  static MvtTile decode(
    Uint8List rawBytes, {
    required int z,
    required int x,
    required int y,
    String? sourceLayer,
  }) {
    if (rawBytes.isEmpty) return const MvtTile({});
    final bytes = _gunzipIfNeeded(rawBytes);
    if (bytes.isEmpty) return const MvtTile({});

    final reader = _ProtoReader(bytes, 0, bytes.length);
    final layers = <String, List<geo.Feature<geo.Geometry>>>{};

    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final fieldNo = tag ~/ 8;
      final wireType = tag & 7;
      if (fieldNo == 3 && wireType == 2) {
        final len = reader.readVarint();
        final end = reader.offset + len;
        final parsed = _parseLayer(
          _ProtoReader(bytes, reader.offset, end),
          z: z,
          tileX: x,
          tileY: y,
          onlyLayer: sourceLayer,
        );
        reader.offset = end;
        if (parsed != null) {
          (layers[parsed.$1] ??= []).addAll(parsed.$2);
        }
      } else {
        reader.skipField(wireType);
      }
    }
    return MvtTile(layers);
  }

  static Uint8List _gunzipIfNeeded(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      return _gzip.decodeBytes(bytes);
    }
    return bytes;
  }

  static (String, List<geo.Feature<geo.Geometry>>)? _parseLayer(
    _ProtoReader reader, {
    required int z,
    required int tileX,
    required int tileY,
    String? onlyLayer,
  }) {
    String name = '';
    var extent = 4096;
    final featureSlices = <(int, int)>[];
    final keys = <String>[];
    final values = <Object?>[];

    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final fieldNo = tag ~/ 8;
      final wireType = tag & 7;
      switch ((fieldNo, wireType)) {
        case (1, 2): // name
          name = reader.readString();
          if (onlyLayer != null && name != onlyLayer) return null;
        case (2, 2): // features
          final len = reader.readVarint();
          featureSlices.add((reader.offset, reader.offset + len));
          reader.offset += len;
        case (3, 2): // keys
          keys.add(reader.readString());
        case (4, 2): // values
          final len = reader.readVarint();
          final end = reader.offset + len;
          values.add(_parseValue(_ProtoReader(reader.bytes, reader.offset, end)));
          reader.offset = end;
        case (5, 0): // extent
          extent = reader.readVarint();
        default:
          reader.skipField(wireType);
      }
    }

    if (onlyLayer != null && name != onlyLayer) return null;
    if (extent <= 0) extent = 4096;

    final out = <geo.Feature<geo.Geometry>>[];
    final proj = _TileProjector(z: z, tileX: tileX, tileY: tileY, extent: extent);

    for (final (start, end) in featureSlices) {
      final f = _parseFeature(
        _ProtoReader(reader.bytes, start, end),
        keys: keys,
        values: values,
        proj: proj,
      );
      if (f != null) out.add(f);
    }
    return (name, out);
  }

  static Object? _parseValue(_ProtoReader reader) {
    Object? result;
    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final fieldNo = tag ~/ 8;
      final wireType = tag & 7;
      switch ((fieldNo, wireType)) {
        case (1, 2): // string_value
          result = reader.readString();
        case (2, 5): // float_value
          result = reader.readFloat32();
        case (3, 1): // double_value
          result = reader.readFloat64();
        case (4, 0): // int_value (int64)
          result = reader.readSignedInt64Varint();
        case (5, 0): // uint_value (uint64)
          result = reader.readVarint();
        case (6, 0): // sint_value (zigzag sint64)
          result = _zigzagDecode(reader.readVarint());
        case (7, 0): // bool_value
          result = reader.readVarint() != 0;
        default:
          reader.skipField(wireType);
      }
    }
    return result;
  }

  static geo.Feature<geo.Geometry>? _parseFeature(
    _ProtoReader reader, {
    required List<String> keys,
    required List<Object?> values,
    required _TileProjector proj,
  }) {
    Object? id;
    var geomType = 0; // 1=POINT, 2=LINESTRING, 3=POLYGON
    List<int>? tags;
    List<int>? geomCmds;

    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final fieldNo = tag ~/ 8;
      final wireType = tag & 7;
      switch ((fieldNo, wireType)) {
        case (1, 0): // id
          id = reader.readVarint();
        case (2, 2): // packed tags
          tags = reader.readPackedUint32();
        case (2, 0):
          (tags ??= []).add(reader.readVarint());
        case (3, 0): // type
          geomType = reader.readVarint();
        case (4, 2): // packed geometry
          geomCmds = reader.readPackedUint32();
        case (4, 0):
          (geomCmds ??= []).add(reader.readVarint());
        default:
          reader.skipField(wireType);
      }
    }

    if (geomCmds == null || geomCmds.isEmpty || geomType < 1 || geomType > 3) {
      return null;
    }

    final geom = _decodeGeometry(geomType, geomCmds, proj);
    if (geom == null) return null;

    final props = <String, Object?>{};
    if (tags != null) {
      for (var i = 0; i + 1 < tags.length; i += 2) {
        final kIdx = tags[i];
        final vIdx = tags[i + 1];
        if (kIdx >= 0 && kIdx < keys.length && vIdx >= 0 && vIdx < values.length) {
          props[keys[kIdx]] = values[vIdx];
        }
      }
    }

    return geo.Feature<geo.Geometry>(
      id: id,
      geometry: geom,
      properties: props,
    );
  }

  static geo.Geometry? _decodeGeometry(
    int geomType,
    List<int> cmds,
    _TileProjector proj,
  ) {
    if (geomType == 1) {
      // POINT / MULTIPOINT
      final pts = <geo.Geographic>[];
      var cx = 0, cy = 0;
      var i = 0;
      while (i < cmds.length) {
        final cmdInt = cmds[i++];
        final cmd = cmdInt & 0x7;
        final count = cmdInt ~/ 8;
        if (cmd == 1) {
          for (var j = 0; j < count && i + 1 < cmds.length; j++) {
            cx += _zigzagDecode32(cmds[i++]);
            cy += _zigzagDecode32(cmds[i++]);
            pts.add(geo.Geographic(lon: proj.lon(cx), lat: proj.lat(cy)));
          }
        } else {
          break;
        }
      }
      if (pts.isEmpty) return null;
      return pts.length == 1 ? geo.Point(pts.first) : geo.MultiPoint(pts);
    }

    // LINESTRING (2) または POLYGON (3)
    final rawParts = <List<int>>[];
    List<int>? current;
    var cx = 0, cy = 0;
    var i = 0;
    while (i < cmds.length) {
      final cmdInt = cmds[i++];
      final cmd = cmdInt & 0x7;
      final count = cmdInt ~/ 8;
      if (cmd == 1) {
        // MoveTo
        for (var j = 0; j < count && i + 1 < cmds.length; j++) {
          cx += _zigzagDecode32(cmds[i++]);
          cy += _zigzagDecode32(cmds[i++]);
          current = <int>[cx, cy];
          rawParts.add(current);
        }
      } else if (cmd == 2) {
        // LineTo
        current ??= (rawParts..add(<int>[])).last;
        for (var j = 0; j < count && i + 1 < cmds.length; j++) {
          cx += _zigzagDecode32(cmds[i++]);
          cy += _zigzagDecode32(cmds[i++]);
          current
            ..add(cx)
            ..add(cy);
        }
      } else if (cmd == 7) {
        // ClosePath
        if (current != null && current.length >= 4) {
          final x0 = current[0], y0 = current[1];
          final xn = current[current.length - 2], yn = current[current.length - 1];
          if (x0 != xn || y0 != yn) {
            current
              ..add(x0)
              ..add(y0);
          }
        }
      }
    }

    if (geomType == 2) {
      final chains = <geo.PositionSeries>[
        for (final part in rawParts)
          if (part.length >= 4) proj.toSeries(part),
      ];
      if (chains.isEmpty) return null;
      return chains.length == 1 ? geo.LineString(chains.first) : geo.MultiLineString(chains);
    }

    // POLYGON / MULTIPOLYGON: MVT v2.1 では Y 下向き空間で時計回り（signedArea2 > 0）が外環、反時計回りが穴
    final polygons = <List<geo.PositionSeries>>[];
    for (final ring in rawParts) {
      if (ring.length < 6) continue;
      // 閉じていなければ閉じる
      if (ring[0] != ring[ring.length - 2] || ring[1] != ring[ring.length - 1]) {
        ring
          ..add(ring[0])
          ..add(ring[1]);
      }
      if (ring.length < 8) continue;
      final area2 = _signedArea2TileSpace(ring);
      if (area2 == 0) continue;
      final series = proj.toSeries(ring);
      if (area2 > 0 || polygons.isEmpty) {
        polygons.add([series]);
      } else {
        polygons.last.add(series);
      }
    }
    if (polygons.isEmpty) return null;
    return polygons.length == 1 ? geo.Polygon(polygons.first) : geo.MultiPolygon(polygons);
  }

  /// Y 下向きタイル座標での倍面積（時計回り外環が正、反時計回り内環が負）
  static double _signedArea2TileSpace(List<int> xy) {
    var sum = 0.0;
    final n = xy.length - 2;
    for (var i = 0; i < n; i += 2) {
      sum += xy[i].toDouble() * xy[i + 3].toDouble() - xy[i + 2].toDouble() * xy[i + 1].toDouble();
    }
    return sum;
  }

  static int _zigzagDecode32(int n) => n.isOdd ? -((n + 1) ~/ 2) : (n ~/ 2);
  static int _zigzagDecode(int n) => n.isOdd ? -((n + 1) ~/ 2) : (n ~/ 2);
}

class _TileProjector {
  _TileProjector({
    required int z,
    required this.tileX,
    required this.tileY,
    required this.extent,
  }) : _totalUnits = (1 << z).toDouble() * extent;

  final int tileX;
  final int tileY;
  final int extent;
  final double _totalUnits;

  double lon(int tx) => (tileX * extent + tx) / _totalUnits * 360.0 - 180.0;

  double lat(int ty) {
    final gy = tileY * extent + ty;
    final t = math.pi * (1.0 - 2.0 * gy / _totalUnits);
    // sinh(t) = (e^t - e^-t) / 2
    final expT = math.exp(t);
    final sinhT = 0.5 * (expT - 1.0 / expT);
    return math.atan(sinhT) * (180.0 / math.pi);
  }

  geo.PositionSeries toSeries(List<int> xy) {
    final count = xy.length ~/ 2;
    final buf = Float64List(count * 2);
    for (var i = 0; i < count; i++) {
      buf[i * 2] = lon(xy[i * 2]);
      buf[i * 2 + 1] = lat(xy[i * 2 + 1]);
    }
    return geo.PositionSeries.view(buf, type: geo.Coords.xy);
  }
}

class _ProtoReader {
  _ProtoReader(this.bytes, this.offset, this.limit);

  final Uint8List bytes;
  int offset;
  final int limit;

  bool get isAtEnd => offset >= limit;

  /// JS (Web) でも 32bit 切り詰めを起こさない算術 varint 読み取り
  int readVarint() {
    var result = 0;
    var factor = 1;
    while (offset < limit) {
      final b = bytes[offset++];
      result += (b & 0x7f) * factor;
      if ((b & 0x80) == 0) return result;
      factor *= 128;
    }
    return result;
  }

  int readSignedInt64Varint() {
    // 負の int64 varint は 10 バイトになるため下位ビット列から復元する
    var lo = 0;
    var hi = 0;
    var i = 0;
    while (offset < limit && i < 10) {
      final b = bytes[offset++];
      if (i < 4) {
        lo |= (b & 0x7f) << (i * 7);
      } else if (i == 4) {
        lo |= (b & 0x0f) << 28;
        hi |= (b & 0x70) >> 4;
      } else {
        hi |= (b & 0x7f) << ((i - 5) * 7 + 3);
      }
      i++;
      if ((b & 0x80) == 0) break;
    }
    final uLo = lo.toUnsigned(32);
    final uHi = hi.toUnsigned(32);
    if ((uHi & 0x80000000) != 0) {
      // 2 の補数負数（53bit 範囲内）
      final invLo = (~uLo) & 0xffffffff;
      final invHi = (~uHi) & 0x7fffffff;
      return -(invHi * 4294967296 + invLo + 1);
    }
    return uHi * 4294967296 + uLo;
  }

  List<int> readPackedUint32() {
    final len = readVarint();
    final end = math.min(limit, offset + len);
    final out = <int>[];
    while (offset < end) {
      out.add(readVarint());
    }
    return out;
  }

  String readString() {
    final len = readVarint();
    final end = math.min(limit, offset + len);
    final s = utf8.decode(Uint8List.sublistView(bytes, offset, end), allowMalformed: true);
    offset = end;
    return s;
  }

  double readFloat32() {
    if (offset + 4 > limit) {
      offset = limit;
      return 0.0;
    }
    final bd = ByteData.sublistView(bytes, offset, offset + 4);
    offset += 4;
    return bd.getFloat32(0, Endian.little);
  }

  double readFloat64() {
    if (offset + 8 > limit) {
      offset = limit;
      return 0.0;
    }
    final bd = ByteData.sublistView(bytes, offset, offset + 8);
    offset += 8;
    return bd.getFloat64(0, Endian.little);
  }

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        offset = math.min(limit, offset + 8);
      case 2:
        final len = readVarint();
        offset = math.min(limit, offset + len);
      case 5:
        offset = math.min(limit, offset + 4);
      default:
        offset = limit;
    }
  }
}
