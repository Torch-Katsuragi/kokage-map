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
// GeoJSON（.geojson / 中身が GeoJSON の .json）の読み手

import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../../../core/fs/k_file_system.dart';
import '../../../models/geometry_type.dart';
import '../external_dataset.dart';
import '../external_dataset_writer.dart';

class GeoJsonReader extends ExternalReader {
  @override
  Set<String> get extensions => const {'.geojson', '.json'};

  /// `.geojson` は常に。`.json` は最上位が FeatureCollection か Feature のときだけ
  /// （設定ファイルなどの `.json` をレイヤにしない）
  @override
  Future<bool> accepts(String path) async {
    if (p.extension(path).toLowerCase() == '.geojson') return true;
    try {
      final decoded = _decode(await fs.readAsBytes(path));
      return decoded is Map && (decoded['type'] == 'FeatureCollection' || decoded['type'] == 'Feature');
    } catch (_) {
      return false;
    }
  }

  static Object? _decode(List<int> bytes) {
    // BOM 付きの UTF-8 もある
    final body = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? bytes.sublist(3) : bytes;
    return utf8.decoder.fuse(json.decoder).convert(body);
  }

  /// ジオメトリ型が混ざっているときのレイヤ名の後ろ（`<名前>_point` など）
  static String suffixOf(GeometryType type) => '_${type.defaultLayerName}';

  @override
  Future<List<ExternalDataset>> read(String path) async {
    final decoded = _decode(await fs.readAsBytes(path));
    if (decoded is! Map) throw FormatException('GeoJSON ではありません: $path');
    final List<Object?> rawFeatures = switch (decoded['type']) {
      'FeatureCollection' => (decoded['features'] as List?) ?? const [],
      'Feature' => [decoded],
      _ => throw FormatException('FeatureCollection / Feature ではありません: $path'),
    };

    // ジオメトリ型ごとに分ける（出てきた順）
    final grouped = <GeometryType, List<Map<String, dynamic>>>{};
    final columns = <GeometryType, Map<String, String>>{};
    for (final raw in rawFeatures) {
      if (raw is! Map) continue;
      final geometry = raw['geometry'];
      if (geometry is! Map) continue;
      final parsed = _geometry(geometry);
      if (parsed == null) continue;
      final (type, key, value) = parsed;

      final props = raw['properties'];
      final attributes = <String, dynamic>{};
      final cols = columns.putIfAbsent(type, () => {});
      if (props is Map) {
        for (final MapEntry(:key, :value) in props.entries) {
          final name = key.toString();
          final v = _attributeValue(value);
          attributes[name] = v;
          // 列の型は最初に値が入っていた行で決める（null だけなら TEXT）
          if (v == null) {
            cols.putIfAbsent(name, () => '');
          } else if ((cols[name] ?? '').isEmpty) {
            cols[name] = sqliteTypeOf(v);
          }
        }
      }
      grouped.putIfAbsent(type, () => []).add({...attributes, key: value});
    }

    final base = p.basenameWithoutExtension(path);
    final split = grouped.length > 1;
    if (grouped.isEmpty) {
      // 地物が無くても 1 枚にする（空のレイヤとして見える。点の型）
      return [ExternalDataset(layerName: base, geometryType: GeometryType.point, columns: const {}, features: const [])];
    }
    return [
      for (final MapEntry(key: type, value: features) in grouped.entries)
        ExternalDataset(
          layerName: split ? '$base${suffixOf(type)}' : base,
          geometryType: type,
          columns: {for (final e in (columns[type] ?? const {}).entries) e.key: e.value.isEmpty ? 'TEXT' : e.value},
          features: features,
        ),
    ];
  }

  /// 属性の値。入れ子（オブジェクト・配列）は JSON の文字列にする
  static Object? _attributeValue(Object? value) => switch (value) {
    Map() || List() => jsonEncode(value),
    _ => value,
  };

  static LatLng? _position(Object? raw) {
    if (raw is! List || raw.length < 2) return null;
    final x = raw[0], y = raw[1];
    if (x is! num || y is! num) return null;
    return LatLng(y.toDouble(), x.toDouble());
  }

  static List<LatLng>? _positions(Object? raw) {
    if (raw is! List) return null;
    final out = <LatLng>[];
    for (final pos in raw) {
      final ll = _position(pos);
      if (ll != null) out.add(ll);
    }
    return out;
  }

  static List<List<LatLng>>? _rings(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final rings = <List<LatLng>>[];
    for (final ring in raw) {
      final r = _positions(ring);
      if (r != null && r.length >= 3) {
        rings.add(r);
      } else if (rings.isEmpty) {
        return null; // 外周が読めなければ面ごと捨てる（穴を外周にしない）
      }
    }
    return rings;
  }

  /// 形 → (型, 地物の中のキー, 値)。多重の形は最初の 1 つだけ（取り込みと同じ扱い）。
  /// 読めない・点が足りない形は null
  static (GeometryType, String, Object)? _geometry(Map<dynamic, dynamic> geometry) {
    final coords = geometry['coordinates'];
    switch (geometry['type']) {
      case 'Point':
        final pt = _position(coords);
        return pt == null ? null : (GeometryType.point, 'point', pt);
      case 'MultiPoint':
        final pts = _positions(coords);
        return pts == null || pts.isEmpty ? null : (GeometryType.point, 'point', pts.first);
      case 'LineString':
        final line = _positions(coords);
        return line == null || line.length < 2 ? null : (GeometryType.linestring, 'line', line);
      case 'MultiLineString':
        if (coords is! List || coords.isEmpty) return null;
        final line = _positions(coords.first);
        return line == null || line.length < 2 ? null : (GeometryType.linestring, 'line', line);
      case 'Polygon':
        final rings = _rings(coords);
        return rings == null ? null : (GeometryType.polygon, 'rings', rings);
      case 'MultiPolygon':
        if (coords is! List || coords.isEmpty) return null;
        final rings = _rings(coords.first);
        return rings == null ? null : (GeometryType.polygon, 'rings', rings);
      default:
        return null;
    }
  }
}
