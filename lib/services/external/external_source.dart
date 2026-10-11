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

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/gdal/gdal_provider.dart';
import '../../core/path_resolver.dart';
import '../../models/geometry_type.dart';
import '../../utils/app_logger.dart';
import 'kmz_layout.dart';

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
    this.dim = 'XY',
    this.dataset,
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

  /// 座標の次元（`ogr2ogr -dim` の値: `XY` `XYZ` `XYM` `XYZM`）。`-nlt` で型を決めると `-dim layer_dim` は効かず
  /// 高さが落ちる（2026-10-11 Pixel 9）ので、元のレイヤの型から決めて渡す
  final String dim;

  /// KMZ の中で読んだ KML（doc.kml の NetworkLink が指す `files/a.kml` など）。null なら元のファイルそのもの
  /// （KMZ なら [ExternalSource.datasetName] の KML）
  final String? dataset;

  /// QGIS の `|layername=` に書く名前。NetworkLink の先の KML は、QGIS（LIBKML）が `<リンク先の名前（拡張子なし）>` の
  /// 1 レイヤにするので、それに合わせる
  String get qgisLayerName => dataset == null ? sourceLayer : p.url.basenameWithoutExtension(dataset!);

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
    'dim': dim,
    if (dataset != null) 'dataset': dataset,
  };

  static ExternalSourceLayer fromJson(Map<String, Object?> json) => ExternalSourceLayer(
    name: json['name']! as String,
    sourceLayer: json['sourceLayer']! as String,
    geometryType: GeometryType.values.byName(json['geometryType']! as String),
    featureCount: (json['featureCount'] as num?)?.toInt() ?? 0,
    split: json['split'] == true,
    dim: json['dim'] as String? ?? 'XY',
    dataset: json['dataset'] as String?,
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

  /// GDAL に渡すデータセット名（KMZ は `/vsizip/<パス>/<中の KML>`。同梱の GDAL は LIBKML を持たず、KML ドライバは zip を開けない）。
  ///
  /// `/vsizip/<パス>` だけで開けるのは zip の中身が 1 ファイルのときだけで、画像や `layers/` を同梱した KMZ は
  /// 「Support only 1 file in archive」で開けない（2026-10-11 web で見つけた。Android も同じ）。中の KML を名指しする
  static Future<String> datasetName(String path) async {
    if (p.extension(path).toLowerCase() != '.kmz') return path;
    return kmzDatasetName(path, (await _kmzLayout(path))?.main);
  }

  /// KMZ の中の [entry] を GDAL に渡す名前（null なら KMZ そのもの）
  static String kmzDatasetName(String kmzPath, String? entry) => entry == null ? '/vsizip/$kmzPath' : '/vsizip/$kmzPath/$entry';

  /// KMZ の中身（読む KML と、その NetworkLink の先）。KMZ でなければ null。zip が読めなければ中身の無い結果
  static Future<KmzLayout?> _kmzLayout(String path) async {
    if (p.extension(path).toLowerCase() != '.kmz') return null;
    try {
      return KmzLayout.fromArchive(ZipDecoder().decodeBytes(await fs.readAsBytes(path)));
    } catch (e) {
      AppLogger.debug('[ExternalSource] KMZ の中身を引けない: $path - $e');
      return const KmzLayout(main: null);
    }
  }

  /// KMZ の中で読む KML（Google Earth と同じく、根の `doc.kml`、無ければ根の最初の `.kml`、無ければどこかの最初の `.kml`）。
  /// KML が無ければ null
  static String? kmzMainEntry(Iterable<String> names) => KmzLayout.mainEntryOf(names);

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
    // GDAL の JSON は `PointZ` `MultiPolygonZM` `3D Point` などと書く。次元と multi を落として種類だけ見る
    final flat = raw
        .replaceAll(RegExp(r'3d|measured|25d|multi|\s|\(.*\)'), '')
        .replaceAll(RegExp(r'(zm|z|m)$'), '');
    return switch (flat) {
      'point' => GeometryType.point,
      'linestring' || 'circularstring' || 'compoundcurve' || 'curve' => GeometryType.linestring,
      'polygon' || 'curvepolygon' || 'surface' || 'triangle' || 'tin' || 'polyhedralsurface' => GeometryType.polygon,
      'none' || '' => null,
      _ => _mixed, // Geometry（Unknown）・GeometryCollection
    };
  }

  static const _mixed = 'mixed';

  /// `ogrinfo -json` の形の型（`3D Point` `Measured Point` `3D Measured Polygon` など）→ `ogr2ogr -dim` の値
  static String _dimOf(Map<String, dynamic> layer) {
    final fields = (layer['geometryFields'] as List?) ?? const [];
    if (fields.isEmpty) return 'XY';
    final raw = ((fields.first as Map)['type'] as String? ?? '').toLowerCase();
    final compact = raw.replaceAll(RegExp(r'\s|\(.*\)'), '');
    final z = raw.contains('3d') || raw.contains('25d') || RegExp(r'zm?$').hasMatch(compact);
    final m = raw.contains('measured') || compact.endsWith('m');
    return 'XY${z ? 'Z' : ''}${m ? 'M' : ''}';
  }

  /// [path] を GDAL で読み、キャッシュに書くレイヤを決める。開けなければ投げる
  static Future<ExternalSourcePlan> plan(String path) async {
    final oo = await openArgs(path);
    final kmz = await _kmzLayout(path);
    List<ExternalSourceLayer> out;
    int sourceLayerCount;
    if (kmz == null || kmz.links.isEmpty) {
      final skipped = kmz != null && kmz.skippedLinks.isNotEmpty;
      if (skipped) _logSkipped(path, kmz);
      try {
        final (layers, count) = await _planDataset(kmz == null ? path : kmzDatasetName(path, kmz.main), oo);
        out = layers;
        sourceLayerCount = count;
      } on GdalException {
        // 外の URL へのリンクだけの doc.kml は、GDAL が開けなくても下で読めない理由（読まなかった href）を出す
        if (!skipped) rethrow;
        out = [];
        sourceLayerCount = 0;
      }
    } else {
      // doc.kml が NetworkLink で zip の中の KML を指している（LIBKML・Google Earth 製）。同梱の GDAL は LIBKML を
      // 持たず、KML ドライバはリンクをたどらないので、リンク先の KML を 1 本ずつ開く。
      // レイヤ名は QGIS（LIBKML）と同じ `<リンク先の名前（拡張子なし）>`。リンク先に GDAL のレイヤが複数あれば
      // GDAL のレイヤ名（フォルダ名）のまま
      if (kmz.skippedLinks.isNotEmpty) _logSkipped(path, kmz);
      out = [];
      // doc.kml 自体に地物があれば、それも出す（NetworkLink だけなら GDAL は開けないか空）
      try {
        out.addAll((await _planDataset(kmzDatasetName(path, kmz.main), oo)).$1.where((l) => l.featureCount > 0));
      } on GdalException catch (e) {
        AppLogger.debug('[ExternalSource] doc.kml に地物が無い: $path - ${e.message}');
      }
      for (final entry in kmz.links) {
        final stem = p.url.basenameWithoutExtension(entry);
        try {
          final (layers, count) = await _planDataset(
            kmzDatasetName(path, entry),
            oo,
            dataset: entry,
            singleLayerName: stem,
          );
          out.addAll(layers);
          AppLogger.debug('[ExternalSource] NetworkLink の先を読んだ: $entry（GDAL のレイヤ $count 枚）');
        } on GdalException catch (e) {
          AppLogger.debug('[ExternalSource] NetworkLink の先が読めない: $path/$entry - ${e.message}');
        }
      }
      _dedupeNames(out);
      sourceLayerCount = kmz.links.length;
    }
    if (out.isEmpty && kmz != null && kmz.skippedLinks.isNotEmpty) {
      throw StateError('KMZ の NetworkLink は KMZ の中の KML だけを読みます（読まなかったもの: ${kmz.skippedLinks.join(', ')}）');
    }
    // 空のレイヤは、ほかに中身のあるレイヤがあれば出さない（GPX は waypoints だけでも routes・tracks・
    // route_points・track_points の空の 4 枚が並ぶ。2026-10-11 Pixel 9）。全部空なら残す（空の shp も 1 枚のレイヤ）
    final filled = out.where((l) => l.featureCount > 0).toList();
    return ExternalSourcePlan(layers: filled.isEmpty ? out : filled, sourceLayerCount: sourceLayerCount);
  }

  static void _logSkipped(String path, KmzLayout kmz) =>
      AppLogger.debug('[ExternalSource] KMZ の NetworkLink を読まなかった（外の URL・中に無い）: $path - ${kmz.skippedLinks}');

  /// 名前がぶつかったら後ろに `_2` `_3` … を付ける（gpkg のレイヤ名は 1 つずつ）
  static void _dedupeNames(List<ExternalSourceLayer> layers) {
    final used = <String>{};
    for (var i = 0; i < layers.length; i++) {
      final l = layers[i];
      var name = l.name;
      for (var n = 2; used.contains(name.toLowerCase()); n++) {
        name = '${l.name}_$n';
      }
      used.add(name.toLowerCase());
      if (name != l.name) {
        layers[i] = ExternalSourceLayer(
          name: name,
          sourceLayer: l.sourceLayer,
          geometryType: l.geometryType,
          featureCount: l.featureCount,
          split: l.split,
          dim: l.dim,
          dataset: l.dataset,
        );
      }
    }
  }

  /// GDAL のデータセット [ds] 1 つを読み、キャッシュに書くレイヤと GDAL のレイヤの数を返す（空のレイヤも返す）。
  /// GDAL のレイヤが 1 枚なら、名前は [singleLayerName]（null なら GDAL のレイヤ名）。[dataset] は KMZ の中の KML
  static Future<(List<ExternalSourceLayer>, int)> _planDataset(
    String ds,
    List<String> oo, {
    String? dataset,
    String? singleLayerName,
  }) async {
    final gdal = ExternalGdal.instance;
    final info = await gdal.vectorInfo(ds, args: ['-so', ...oo]);
    final layers = ((info['layers'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final alias = layers.length == 1 ? singleLayerName : null;
    final out = <ExternalSourceLayer>[];
    for (final layer in layers) {
      final sourceName = layer['name'] as String;
      final name = alias ?? sourceName;
      final count = (layer['featureCount'] as num?)?.toInt() ?? 0;
      final family = _familyOf(layer);
      if (family == null) continue;
      if (family is GeometryType) {
        out.add(ExternalSourceLayer(
          name: name,
          sourceLayer: sourceName,
          geometryType: family,
          featureCount: count,
          dim: _dimOf(layer),
          dataset: dataset,
        ));
        continue;
      }
      // 型が混ざっている（GeoJSON・KML・DXF など）: 点・線・面ごとに数え、2 種以上なら分ける
      final counts = <GeometryType, int>{};
      for (final type in GeometryType.values) {
        final probe = ExternalSourceLayer(name: name, sourceLayer: sourceName, geometryType: type, featureCount: 0, split: true);
        final sub = await gdal.vectorInfo(ds, args: ['-so', ...oo, '-where', probe.where!, sourceName]);
        // 名前で引く（レイヤ名の引数を受け付けない版でも、-where は全レイヤに掛かる）
        final subLayer = ((sub['layers'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .where((l) => l['name'] == sourceName)
            .firstOrNull;
        final n = (subLayer?['featureCount'] as num?)?.toInt() ?? 0;
        if (n > 0) counts[type] = n;
      }
      if (counts.length == 1) {
        // 1 種だけなら分けない（名前もそのまま）。件数は形の無い地物も含めた元の数
        out.add(ExternalSourceLayer(
          name: name,
          sourceLayer: sourceName,
          geometryType: counts.keys.single,
          featureCount: count,
          dataset: dataset,
        ));
      } else {
        for (final MapEntry(key: type, value: n) in counts.entries) {
          out.add(ExternalSourceLayer(
            name: '$name${externalSplitSuffix(type)}',
            sourceLayer: sourceName,
            geometryType: type,
            featureCount: n,
            split: true,
            dataset: dataset,
          ));
        }
      }
    }
    return (out, layers.length);
  }

  /// [plan] どおりに [path] を [dst]（GPKG）へ書く。座標系は元のまま（`-t_srs` を付けない）
  static Future<void> translate(String path, String dst, ExternalSourcePlan plan) async {
    final gdal = ExternalGdal.instance;
    final ds = await datasetName(path);
    final oo = await openArgs(path);
    var first = true;
    for (final layer in plan.layers) {
      final src = layer.dataset == null ? ds : kmzDatasetName(path, layer.dataset);
      await gdal.vectorTranslate(src, dst, args: [
        '-f', 'GPKG',
        if (!first) '-update',
        ...oo,
        // 形の型はアプリの 3 種（MULTI 系）に揃え、Z・M は型名に付けて元のまま残す（MULTIPOINTZ など）。
        // ⚠ `-nlt MULTIPOINT -dim XYZ` だと宣言だけ 3 次元になり、値は 2 次元で書かれる（2026-10-11 Pixel 9 で発見）
        '-nlt', '${layer.geometryType.value}${layer.dim.substring(2)}',
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
