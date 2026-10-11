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
// gpkg 以外のベクタ形式を GDAL で読む（読み取り専用レイヤの元）
// 設計は docs/technical/external-formats.md
//
// どのファイルがレイヤになるか（拡張子・中身）、GDAL に渡す名前とオープンオプション、
// 1 ファイルの中のレイヤ（GDAL のレイヤ。型の混ざったレイヤは点・線・面に分ける）をここで決める。

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/gdal/gdal_provider.dart';
import '../../core/path_resolver.dart';
import '../../models/geometry_type.dart';
import '../../utils/app_logger.dart';

/// 外部形式の読み書きに使う GDAL（差し替えはテスト用）
class ExternalGdal {
  ExternalGdal._();
  static Gdal? _instance;
  static Gdal get instance => _instance ??= createGdal();
  static set instance(Gdal gdal) => _instance = gdal;
}

/// 読み取り専用レイヤにする拡張子（小文字・点つき）。同梱の GDAL のベクタドライバが読めるもの。
/// `.json` と `.csv` は中身で判定する（[ExternalSource.probe]）
const externalVectorExtensions = {
  '.shp',
  '.geojson',
  '.json',
  '.kml',
  '.kmz',
  '.csv',
  '.gpx',
  '.fgb',
  '.gml',
  '.dxf',
  '.tab',
  '.mif',
};

/// 中身を見ないとレイヤになるか分からない拡張子
const _probedExtensions = {'.json', '.csv'};

/// CSV の座標列の候補（GDAL の CSV ドライバの X/Y_POSSIBLE_NAMES。大文字小文字は問わない）
const csvOpenOptions = [
  'X_POSSIBLE_NAMES=lon,lon*,lng,lng*,long,longitude,経度,x',
  'Y_POSSIBLE_NAMES=lat,lat*,latitude,緯度,y',
  'KEEP_GEOM_COLUMNS=NO',
  'AUTODETECT_TYPE=YES',
];

/// shp で `.cpg` も DBF の LDID も無いときの文字コード（[[gdal#Android の実装で決めたこと（2026-10-09）]]）。
/// FFI 版の GDAL も同じ判定をするが、web でも同じに読むため呼ぶ側でも渡す
const shapefileFallbackEncoding = 'CP932';

/// 型の混ざったレイヤを分けるときの、OGR_GEOMETRY の値（平らにした型名）
const _familyGeometryNames = {
  GeometryType.point: ['POINT', 'MULTIPOINT'],
  GeometryType.linestring: ['LINESTRING', 'MULTILINESTRING', 'CIRCULARSTRING', 'COMPOUNDCURVE', 'MULTICURVE'],
  GeometryType.polygon: ['POLYGON', 'MULTIPOLYGON', 'CURVEPOLYGON', 'MULTISURFACE', 'TRIANGLE', 'TIN', 'POLYHEDRALSURFACE'],
};

/// QGIS の `|geometrytype=` に書く名前
const _qgisGeometryTypeNames = {
  GeometryType.point: 'Point',
  GeometryType.linestring: 'LineString',
  GeometryType.polygon: 'Polygon',
};

/// 型の混ざったレイヤを分けたときの名前の後ろ（`<名前>_point` など）
String externalSplitSuffix(GeometryType type) => '_${type.defaultLayerName}';

/// QGIS の `geometrytype=` の値（`Point` `MultiPolygon25D` など）→ 型。分からなければ null
GeometryType? geometryTypeFromQgis(String? value) =>
    switch (value?.toLowerCase().replaceAll(RegExp(r'^multi|25d$|zm$|z$|m$'), '')) {
      'point' => GeometryType.point,
      'linestring' || 'curve' || 'compoundcurve' => GeometryType.linestring,
      'polygon' || 'surface' || 'curvepolygon' => GeometryType.polygon,
      _ => null,
    };

/// キャッシュ gpkg の 1 レイヤ（= 元の 1 レイヤ、または型の混ざったレイヤの点・線・面のどれか）
class ExternalSourceLayer {
  const ExternalSourceLayer({
    required this.name,
    required this.sourceLayer,
    required this.geometryType,
    required this.featureCount,
    this.split = false,
  });

  /// キャッシュ・変換後の gpkg でのレイヤ名（GDAL のレイヤ名。分けたら `<名前>_point` など）
  final String name;

  /// 元のファイルの中の GDAL のレイヤ名
  final String sourceLayer;

  final GeometryType geometryType;

  /// 元のレイヤの地物の数（分けたらその型の数）
  final int featureCount;

  /// 型の混ざったレイヤから分けたもの（QGIS では `|geometrytype=`）
  final bool split;

  /// `ogr2ogr -where`（分けたときだけ）
  String? get where => split
      ? "OGR_GEOMETRY IN (${_familyGeometryNames[geometryType]!.map((n) => "'$n'").join(',')})"
      : null;

  /// QGIS の `|geometrytype=`（分けたときだけ）
  String? get qgisGeometryType => split ? _qgisGeometryTypeNames[geometryType] : null;

  Map<String, Object?> toJson() => {
    'name': name,
    'sourceLayer': sourceLayer,
    'geometryType': geometryType.name,
    'featureCount': featureCount,
    'split': split,
  };

  static ExternalSourceLayer fromJson(Map<String, Object?> json) => ExternalSourceLayer(
    name: json['name']! as String,
    sourceLayer: json['sourceLayer']! as String,
    geometryType: GeometryType.values.byName(json['geometryType']! as String),
    featureCount: (json['featureCount'] as num?)?.toInt() ?? 0,
    split: json['split'] == true,
  );
}

/// 元のファイル 1 本を GDAL で読んだ結果（どのレイヤをどう書くか）
class ExternalSourcePlan {
  const ExternalSourcePlan({required this.layers, required this.sourceLayerCount});

  /// キャッシュに書くレイヤ（空ならレイヤにならない）
  final List<ExternalSourceLayer> layers;

  /// 元のファイルの GDAL のレイヤの数（形の無いレイヤも含む）。2 以上なら QGIS では `|layername=`
  final int sourceLayerCount;

  String encodeLayers() => jsonEncode({
    'sourceLayerCount': sourceLayerCount,
    'layers': [for (final l in layers) l.toJson()],
  });

  static ExternalSourcePlan? decodeLayers(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      return ExternalSourcePlan(
        sourceLayerCount: (json['sourceLayerCount'] as num?)?.toInt() ?? 1,
        layers: [
          for (final l in json['layers']! as List) ExternalSourceLayer.fromJson((l as Map).cast<String, Object?>()),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

class ExternalSource {
  ExternalSource._();

  /// 拡張子だけで見て、読み取り専用レイヤの候補か（隠しファイル・隠しフォルダの中は外す）
  static bool isCandidate(String path) {
    final ext = p.extension(path).toLowerCase();
    if (!externalVectorExtensions.contains(ext)) return false;
    if (p.basename(path).startsWith('.')) return false;
    final root = ProjectPathResolver.instance.rootPath;
    final rel = root != null && p.isWithin(root, path) ? p.relative(p.dirname(path), from: root) : p.basename(p.dirname(path));
    return !rel.replaceAll(r'\', '/').split('/').any((s) => s.startsWith('.') && s != '.' && s != '..');
  }

  /// GDAL に渡すデータセット名（KMZ は `/vsizip/`。同梱の GDAL は LIBKML を持たず、KML ドライバは zip を開けない）
  static String datasetName(String path) => p.extension(path).toLowerCase() == '.kmz' ? '/vsizip/$path' : path;

  /// [path] を開くときのオープンオプション（`-oo` を付けた引数）
  static Future<List<String>> openArgs(String path) async {
    final ext = p.extension(path).toLowerCase();
    final oo = <String>[
      if (ext == '.csv') ...csvOpenOptions,
      if (ext == '.shp' && await needsFallbackEncoding(path)) 'ENCODING=$shapefileFallbackEncoding',
    ];
    return [for (final o in oo) ...['-oo', o]];
  }

  /// shp で `.cpg` も DBF の LDID も無いか（fs 経由。web でも動く）
  static Future<bool> needsFallbackEncoding(String shpPath) async {
    if (p.extension(shpPath).toLowerCase() != '.shp') return false;
    if (await findSibling(shpPath, '.cpg') != null) return false;
    final dbf = await findSibling(shpPath, '.dbf');
    if (dbf == null) return false;
    try {
      final head = await fs.readAsBytes(dbf);
      return head.length > 29 && head[29] == 0;
    } catch (_) {
      return false;
    }
  }

  /// 同じフォルダの「拡張子を除いた名前 + [ext]」（大文字小文字を問わない）。無ければ null
  static Future<String?> findSibling(String path, String ext) async {
    final want = '${p.basenameWithoutExtension(path)}$ext'.toLowerCase();
    for (final entry in await fs.list(p.dirname(path))) {
      if (!entry.isDirectory && entry.name.toLowerCase() == want) return entry.path;
    }
    return null;
  }

  /// 元のファイル一式（自分が先頭。shp なら .dbf .shx .prj …）。GDAL の `GDALGetFileList`
  static Future<List<String>> files(String path) async {
    if (p.extension(path).toLowerCase() == '.kmz') return [path];
    try {
      final list = await ExternalGdal.instance.fileList(path);
      final self = p.normalize(path);
      final rest = list.map(p.normalize).where((f) => f != self && !p.equals(f, self)).toSet().toList()..sort();
      return [path, ...rest];
    } catch (e) {
      AppLogger.debug('[ExternalSource] 付属ファイルを引けない: $path - $e');
      return [path];
    }
  }

  /// `ogrinfo -json -so` の 1 レイヤの形の型 → 型。形が無ければ null、混ざっていれば [_mixed]
  static Object? _familyOf(Map<String, dynamic> layer) {
    final fields = (layer['geometryFields'] as List?) ?? const [];
    if (fields.isEmpty) return null;
    final raw = ((fields.first as Map)['type'] as String? ?? '').toLowerCase();
    final flat = raw.replaceAll(RegExp(r'3d|measured|25d|multi|\s|\(.*\)'), '');
    return switch (flat) {
      'point' => GeometryType.point,
      'linestring' || 'circularstring' || 'compoundcurve' || 'curve' => GeometryType.linestring,
      'polygon' || 'curvepolygon' || 'surface' || 'triangle' || 'tin' || 'polyhedralsurface' => GeometryType.polygon,
      'none' || '' => null,
      _ => _mixed, // Geometry（Unknown）・GeometryCollection
    };
  }

  static const _mixed = 'mixed';

  /// [path] を GDAL で読み、キャッシュに書くレイヤを決める。開けなければ投げる
  static Future<ExternalSourcePlan> plan(String path) async {
    final gdal = ExternalGdal.instance;
    final ds = datasetName(path);
    final oo = await openArgs(path);
    final info = await gdal.vectorInfo(ds, args: ['-so', ...oo]);
    final layers = ((info['layers'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final out = <ExternalSourceLayer>[];
    for (final layer in layers) {
      final name = layer['name'] as String;
      final count = (layer['featureCount'] as num?)?.toInt() ?? 0;
      final family = _familyOf(layer);
      if (family == null) continue;
      if (family is GeometryType) {
        out.add(ExternalSourceLayer(name: name, sourceLayer: name, geometryType: family, featureCount: count));
        continue;
      }
      // 型が混ざっている（GeoJSON・KML・DXF など）: 点・線・面ごとに数え、2 種以上なら分ける
      final counts = <GeometryType, int>{};
      for (final type in GeometryType.values) {
        final probe = ExternalSourceLayer(name: name, sourceLayer: name, geometryType: type, featureCount: 0, split: true);
        final sub = await gdal.vectorInfo(ds, args: ['-so', ...oo, '-where', probe.where!, name]);
        // 名前で引く（レイヤ名の引数を受け付けない版でも、-where は全レイヤに掛かる）
        final subLayer = ((sub['layers'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .where((l) => l['name'] == name)
            .firstOrNull;
        final n = (subLayer?['featureCount'] as num?)?.toInt() ?? 0;
        if (n > 0) counts[type] = n;
      }
      if (counts.length == 1) {
        // 1 種だけなら分けない（名前もそのまま）。件数は形の無い地物も含めた元の数
        out.add(ExternalSourceLayer(name: name, sourceLayer: name, geometryType: counts.keys.single, featureCount: count));
      } else {
        for (final MapEntry(key: type, value: n) in counts.entries) {
          out.add(ExternalSourceLayer(
            name: '$name${externalSplitSuffix(type)}',
            sourceLayer: name,
            geometryType: type,
            featureCount: n,
            split: true,
          ));
        }
      }
    }
    return ExternalSourcePlan(layers: out, sourceLayerCount: layers.length);
  }

  /// [plan] どおりに [path] を [dst]（GPKG）へ書く。座標系は元のまま（`-t_srs` を付けない）
  static Future<void> translate(String path, String dst, ExternalSourcePlan plan) async {
    final gdal = ExternalGdal.instance;
    final ds = datasetName(path);
    final oo = await openArgs(path);
    var first = true;
    for (final layer in plan.layers) {
      await gdal.vectorTranslate(ds, dst, args: [
        '-f', 'GPKG',
        if (!first) '-update',
        ...oo,
        // 形の型はアプリの 3 種（MULTI 系）に揃える。Z・M は元のまま（変換した gpkg で高さを失わないため。
        // 表示とヒットテストは XY だけ見る）
        '-nlt', layer.geometryType.value,
        '-dim', 'layer_dim',
        // CSV は座標系を持たない（GDAL は未定義の srs 99999 で書く）。経度・緯度の列だけ受けるので WGS84 と決める
        // （2026-10-11 Pixel 9 で見つけた）
        if (p.extension(path).toLowerCase() == '.csv') ...['-a_srs', 'EPSG:4326'],
        '-nln', layer.name,
        if (layer.where != null) ...['-where', layer.where!],
        layer.sourceLayer,
      ]);
      first = false;
    }
  }

  /// 中身で判定した結果の控え（パス → 更新時刻と大きさ・結果）。フォルダを開くたびに GDAL で開き直さないため
  static final Map<String, ({DateTime? modified, int? size, bool accepted})> _acceptCache = {};

  /// [path] が読み取り専用レイヤとして開けるか。`.json` `.csv` 以外は拡張子だけで決める
  /// （読めなければノードに理由が出る）
  static Future<bool> accepts(String path) async {
    if (!isCandidate(path)) return false;
    if (!_probedExtensions.contains(p.extension(path).toLowerCase())) return true;
    try {
      final modified = await fs.lastModified(path);
      final size = await fs.length(path);
      final cached = _acceptCache[path];
      if (cached != null && cached.modified == modified && cached.size == size) return cached.accepted;
      bool accepted;
      try {
        accepted = (await plan(path)).layers.isNotEmpty;
      } on GdalException {
        accepted = false;
      }
      _acceptCache[path] = (modified: modified, size: size, accepted: accepted);
      return accepted;
    } catch (e) {
      AppLogger.debug('[ExternalSource] 判定できない: $path - $e');
      return false;
    }
  }
}
