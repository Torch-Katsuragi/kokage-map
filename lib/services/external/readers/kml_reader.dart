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
// KML / KMZ の読み手（設計は docs/technical/external-formats.md）

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../../core/fs/k_file_system.dart';
import '../../../models/geometry_type.dart';
import '../external_dataset.dart';
import 'attribute_columns.dart';

/// KML / KMZ を読む。
///
/// レイヤは（フォルダの道筋 × ジオメトリ型）ごとに 1 枚。全体で 1 枚にしかならなければファイル名、
/// 複数なら各フォルダの名前（フォルダの外の Placemark はファイル名）で、1 つのフォルダに型が混ざるときだけ
/// `_point` / `_line` / `_polygon` を足す。
/// 属性は `name`・`description` と ExtendedData（Data/value・SchemaData/SimpleData）。
/// MultiGeometry は部分ごとに 1 フィーチャ（属性は同じものを持つ）。スタイル・NetworkLink は読まない
class KmlReader extends ExternalReader {
  @override
  Set<String> get extensions => const {'.kml', '.kmz'};

  @override
  Future<List<ExternalDataset>> read(String path) async {
    final bytes = await fs.readAsBytes(path);
    final text = p.extension(path).toLowerCase() == '.kmz' ? kmlFromKmz(bytes) : _decode(bytes);
    return parse(text, p.basenameWithoutExtension(path));
  }

  /// KMZ（zip）の中の KML。直下の `doc.kml`、無ければ最初の `.kml`
  @visibleForTesting
  static String kmlFromKmz(Uint8List bytes) {
    final files = ZipDecoder().decodeBytes(bytes).files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.kml'));
    final file = files.where((f) => f.name.toLowerCase() == 'doc.kml').firstOrNull ?? files.firstOrNull;
    if (file == null) throw const FormatException('KMZ の中に .kml がありません');
    return _decode(file.content);
  }

  static String _decode(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('﻿') ? text.substring(1) : text;
  }

  /// KML の文字列を読む。[fileName] は 1 枚だけのとき・フォルダの外の Placemark のレイヤ名
  @visibleForTesting
  static List<ExternalDataset> parse(String kml, String fileName) {
    final groups = <String, _Group>{};
    void walk(XmlElement e, List<String> folders) {
      for (final child in e.childElements) {
        switch (child.localName) {
          case 'Folder':
            walk(child, [...folders, _childText(child, 'name') ?? 'Folder']);
          case 'Document':
            walk(child, folders);
          case 'Placemark':
            _addPlacemark(child, folders, groups);
        }
      }
    }

    walk(XmlDocument.parse(kml).rootElement, const []);
    final names = _layerNames(groups.values.toList(), fileName);
    return [for (final (i, g) in groups.values.indexed) _toDataset(g, names[i])];
  }

  static void _addPlacemark(XmlElement pm, List<String> folders, Map<String, _Group> groups) {
    final attrs = <String, String?>{'name': _childText(pm, 'name'), 'description': _childText(pm, 'description')};
    for (final ext in pm.childElements.where((e) => e.localName == 'ExtendedData')) {
      for (final d in ext.descendantElements) {
        final (key, value) = switch (d.localName) {
          'Data' => (d.getAttribute('name'), _childText(d, 'value')),
          'SimpleData' => (d.getAttribute('name'), d.innerText.trim()),
          _ => (null, null),
        };
        if (key == null) continue;
        var column = attributeColumnName(key);
        if (column == 'name' || column == 'description') column = '${column}_1';
        attrs[column] = value;
      }
    }

    final parts = <(GeometryType, Object)>[];
    for (final child in pm.childElements) {
      _collectGeometries(child, parts);
    }
    for (final (type, geometry) in parts) {
      final key = '${folders.join('\u0000')}\u0001${type.name}';
      final group = groups.putIfAbsent(key, () => _Group(folders, type));
      group.features.add((geometry, attrs));
      for (final k in attrs.keys) {
        if (!group.order.contains(k)) group.order.add(k);
      }
    }
  }

  static void _collectGeometries(XmlElement e, List<(GeometryType, Object)> out) {
    switch (e.localName) {
      case 'Point':
        final c = _coordinates(e);
        if (c.isNotEmpty) out.add((GeometryType.point, c.first));
      case 'LineString' || 'LinearRing':
        final c = _coordinates(e);
        if (c.length >= 2) out.add((GeometryType.linestring, c));
      case 'Polygon':
        List<LatLng>? ring(XmlElement boundary) {
          final lr = boundary.descendantElements.where((x) => x.localName == 'LinearRing').firstOrNull;
          return lr == null ? null : _coordinates(lr);
        }
        final outer = e.childElements.where((x) => x.localName == 'outerBoundaryIs').map(ring).firstOrNull;
        if (outer == null || outer.length < 3) return;
        out.add((
          GeometryType.polygon,
          [
            outer,
            for (final inner in e.childElements.where((x) => x.localName == 'innerBoundaryIs'))
              if (ring(inner) case final r? when r.length >= 3) r, // 穴は 3 点以上のものだけ
          ],
        ));
      case 'Track':
        final c = [
          for (final coord in e.childElements.where((x) => x.localName == 'coord'))
            ?_lonLat(coord.innerText.trim().split(RegExp(r'\s+'))),
        ];
        if (c.length >= 2) out.add((GeometryType.linestring, c));
      case 'MultiGeometry' || 'MultiTrack':
        for (final child in e.childElements) {
          _collectGeometries(child, out);
        }
    }
  }

  /// `<coordinates>`（`lon,lat[,alt]` を空白区切り）
  static List<LatLng> _coordinates(XmlElement e) {
    final text = e.childElements.where((x) => x.localName == 'coordinates').firstOrNull?.innerText;
    if (text == null) return const [];
    return [
      for (final tuple in text.trim().replaceAll(RegExp(r'\s*,\s*'), ',').split(RegExp(r'\s+')))
        ?_lonLat(tuple.split(',')),
    ];
  }

  static LatLng? _lonLat(List<String> parts) {
    if (parts.length < 2) return null;
    final lon = double.tryParse(parts[0]);
    final lat = double.tryParse(parts[1]);
    if (lon == null || lat == null || lat.abs() > 90 || lon.abs() > 180) return null;
    return LatLng(lat, lon);
  }

  static String? _childText(XmlElement e, String localName) =>
      e.childElements.where((x) => x.localName == localName).firstOrNull?.innerText.trim();

  /// [groups] と同じ並びのレイヤ名
  static List<String> _layerNames(List<_Group> groups, String fileName) {
    if (groups.length == 1) return [fileName];
    String folderKey(_Group g) => g.folders.join('\u0000');
    // 同じ名前のフォルダが別の場所にあれば道筋をつなげる
    final lastNames = <String, Set<String>>{};
    for (final g in groups) {
      lastNames.putIfAbsent(g.folders.lastOrNull ?? fileName, () => {}).add(folderKey(g));
    }
    final typesPerFolder = <String, int>{};
    for (final g in groups) {
      typesPerFolder.update(folderKey(g), (n) => n + 1, ifAbsent: () => 1);
    }
    final used = <String>{};
    return [
      for (final g in groups)
        () {
          final last = g.folders.lastOrNull ?? fileName;
          var name = lastNames[last]!.length > 1 && g.folders.isNotEmpty ? g.folders.join('_') : last;
          if (typesPerFolder[folderKey(g)]! > 1) name = '${name}_${_suffix(g.type)}';
          var unique = name;
          for (var i = 2; !used.add(unique); i++) {
            unique = '${name}_$i';
          }
          return unique;
        }(),
    ];
  }

  static String _suffix(GeometryType t) => switch (t) {
    GeometryType.point => 'point',
    GeometryType.linestring => 'line',
    GeometryType.polygon => 'polygon',
  };

  static ExternalDataset _toDataset(_Group g, String name) {
    final typed = typeAttributeColumns(g.order, [for (final f in g.features) f.$2]);
    final geometryKey = switch (g.type) {
      GeometryType.point => 'point',
      GeometryType.linestring => 'line',
      GeometryType.polygon => 'rings',
    };
    return ExternalDataset(
      layerName: name,
      geometryType: g.type,
      columns: typed.columns,
      features: [
        for (final (i, f) in g.features.indexed) {geometryKey: f.$1, ...typed.rows[i]},
      ],
    );
  }
}

/// 1 レイヤ分（フォルダの道筋 × ジオメトリ型）の集まり
class _Group {
  _Group(this.folders, this.type);

  final List<String> folders;
  final GeometryType type;

  /// 列名の出てきた順
  final List<String> order = [];
  final List<(Object, Map<String, String?>)> features = [];
}
