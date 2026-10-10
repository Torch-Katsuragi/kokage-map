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
// QGIS / GDAL で作ったラスタ（GeoTIFF・JPEG2000・ワールドファイル付きの PNG/JPEG・VRT）をオーバーレイとして開く。
//
// 設計: [[docs/technical/external-formats#ラスタ（GeoTIFF など）]] ／ [[docs/technical/gdal]]
//
// - 判定: `gdalinfo -json`。位置（geoTransform）と座標系があり、`wgs84Extent` が出ればオーバーレイ
// - 表示: `gdalwarp -t_srs EPSG:4326 -ts W H -r bilinear -dstalpha` → `gdal_translate -of PNG`。
//   W:H は地上の縦横比（メートル）に合わせる。アプリのオーバーレイの形（中心・m/px・回転 0）がそのまま使えるように
// - 16bit・浮動小数（DEM など）は、ワープ後の最小〜最大（`gdalinfo -mm`）で 0〜255 の灰色に伸ばす（`-scale_n` `-ot Byte`）
// - nodata は gdalwarp の `-dstalpha` で透明に
// - ファイルが正なので書き換えない（位置合わせの道具は効かない）。キャッシュは付属ファイル一式の大きさ・更新時刻で作り直す
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/fs/k_file_system.dart';
import '../core/gdal/gdal_provider.dart';
import '../core/path_resolver.dart';
import '../models/kmeta.dart';
import '../utils/app_logger.dart';
import '../utils/stable_hash.dart';
import 'global_folder_locator.dart';

/// `gdalinfo -json` から読んだ、オーバーレイにするのに要るもの
class GdalRasterProbe {
  const GdalRasterProbe({
    required this.width,
    required this.height,
    required this.bandTypes,
    required this.colorInterpretations,
    required this.crsWkt,
    required this.west,
    required this.south,
    required this.east,
    required this.north,
    this.epsg,
    this.proj4,
  });

  final int width;
  final int height;

  /// バンドごとの型（`Byte` `UInt16` `Float32` …）
  final List<String> bandTypes;

  /// バンドごとの色の解釈（`Red` `Gray` `Alpha` `Palette` …）
  final List<String> colorInterpretations;

  /// 元の座標系（WKT2）
  final String crsWkt;

  /// WKT の末尾の `ID["EPSG",n]`。無ければ null
  final int? epsg;
  final String? proj4;

  /// `wgs84Extent` の外接矩形（度）
  final double west;
  final double south;
  final double east;
  final double north;

  /// 灰色に伸ばす要があるか（色のバンドに Byte 以外がある）
  bool get needsStretch => [
        for (var i = 0; i < bandTypes.length; i++)
          if (colorInterpretations.elementAtOrNull(i) != 'Alpha') bandTypes[i],
      ].any((t) => t != 'Byte') &&
      !isPalette;

  /// 色表のラスタ（1 バンドの Palette）。番号を補間できないので最近傍でワープし、PNG にするとき `-expand rgba` で色に開く
  bool get isPalette => colorInterpretations.firstOrNull == 'Palette';

  bool get isGeographic => RegExp(r'^\s*GEOG(CRS|CS)\[').hasMatch(crsWkt);

  /// WKT の先頭の名前（`PROJCRS["JGD2011 / Japan Plane Rectangular CS VI", …` の中身）
  String? get crsName => RegExp(r'^\s*\w+\["([^"]*)"').firstMatch(crsWkt)?.group(1);
}

/// PNG キャッシュを作った結果
class GdalRasterRender {
  const GdalRasterRender({required this.pngPath, required this.params});
  final String pngPath;

  /// ワープ後の範囲から作った、回転なしのオーバーレイの形
  final KMetaImageOverlay params;
}

abstract final class GdalRasterOverlay {
  /// PNG の長辺の上限
  static const maxLongSide = 4096;

  /// GDAL で開いてみる拡張子（PNG/JPEG はワールドファイルか .aux.xml があるときだけ）
  static const rasterExtensions = {'.tif', '.tiff', '.jp2', '.vrt', '.png', '.jpg', '.jpeg'};

  static const _worldFileExtensions = {
    '.png': ['.pgw', '.pngw', '.wld'],
    '.jpg': ['.jgw', '.jpgw', '.wld'],
    '.jpeg': ['.jgw', '.jpegw', '.wld'],
  };

  static Gdal? _gdal;
  static Gdal get _g => _gdal ??= createGdal();

  /// テストで GDAL（ホストの GdalFfi）とキャッシュの置き場を差し込む
  @visibleForTesting
  static void configureForTest({Gdal? gdal, String? cacheDir}) {
    _gdal = gdal;
    _cacheDirOverride = cacheDir;
    _probeCache.clear();
  }

  static String? _cacheDirOverride;

  /// GDAL に聞く値打ちがあるか。[siblingNames] は同じフォルダのファイル名（小文字）。
  ///
  /// 写真（EXIF だけの JPEG）のたびに GDAL を呼ばないよう、PNG/JPEG はワールドファイルか `.aux.xml` があるときだけ。
  /// `.tif` はアプリの GeoTIFF でないと分かってから呼ぶ（呼ぶ側で）
  static bool worthProbing(String path, Set<String> siblingNames) {
    final ext = p.extension(path).toLowerCase();
    if (!rasterExtensions.contains(ext)) return false;
    final worlds = _worldFileExtensions[ext];
    if (worlds == null) return true;
    final name = p.basename(path).toLowerCase();
    final stem = p.basenameWithoutExtension(path).toLowerCase();
    return siblingNames.contains('$name.aux.xml') || worlds.any((w) => siblingNames.contains('$stem$w'));
  }

  /// path → (大きさ・更新時刻, 結果)。フォルダを読み直すたびに GDAL を呼ばない
  static final _probeCache = <String, (String, GdalRasterProbe?)>{};

  /// 位置と座標系を持つラスタなら [GdalRasterProbe]、そうでなければ（GDAL が無い・開けない場合も）null
  static Future<GdalRasterProbe?> probe(String path) async {
    final stamp = '${await fs.length(path)}:${(await fs.lastModified(path))?.millisecondsSinceEpoch}';
    final hit = _probeCache[path];
    if (hit != null && hit.$1 == stamp) return hit.$2;
    GdalRasterProbe? result;
    try {
      final info = await _g.rasterInfo(path, args: const ['-proj4']);
      // GCP だけで位置を持つラスタ（`wgs84Extent` が出ない）は、小さくワープして範囲を取る（gdalwarp は GCP を使う）
      final gcps = info['gcps'];
      final bounds = info['geoTransform'] == null && gcps is Map && (gcps['gcpList'] as List?)?.isNotEmpty == true
          ? await _warpedBounds(path)
          : null;
      result = parseInfo(info, bounds: bounds);
    } catch (e) {
      AppLogger.debug('[GdalRasterOverlay] ${p.basename(path)} を GDAL で開けない: $e');
    }
    _probeCache[path] = (stamp, result);
    return result;
  }

  /// `gdalinfo -json` の結果を読む。座標系と範囲（`wgs84Extent`、GCP のラスタは [bounds]）が無ければ null。
  /// [bounds] は (西, 南, 東, 北)
  static GdalRasterProbe? parseInfo(Map<String, dynamic> info, {(double, double, double, double)? bounds}) {
    final gcps = info['gcps'] is Map ? info['gcps'] as Map : const {};
    final cs = info['coordinateSystem'] is Map
        ? info['coordinateSystem'] as Map
        : (gcps['coordinateSystem'] is Map ? gcps['coordinateSystem'] as Map : const {});
    final wkt = cs['wkt'] as String?;
    final size = info['size'];
    if (wkt == null || wkt.trim().isEmpty || size is! List) return null;
    var lons = <double>[], lats = <double>[];
    final extent = info['wgs84Extent'];
    if (info['geoTransform'] is List && extent is Map) {
      final ring = (extent['coordinates'] as List?)?.firstOrNull as List?;
      if (ring == null || ring.isEmpty) return null;
      lons = [for (final c in ring) ((c as List)[0] as num).toDouble()];
      lats = [for (final c in ring) ((c as List)[1] as num).toDouble()];
    } else if (bounds != null) {
      lons = [bounds.$1, bounds.$3];
      lats = [bounds.$2, bounds.$4];
    } else {
      return null;
    }
    final bands = (info['bands'] as List? ?? const []).cast<Map>();
    final epsg = RegExp(r'ID\["EPSG",(\d+)\]\]\s*$').firstMatch(wkt)?.group(1);
    final proj4 = cs['proj4'] as String?;
    return GdalRasterProbe(
      width: (size[0] as num).toInt(),
      height: (size[1] as num).toInt(),
      bandTypes: [for (final b in bands) b['type'] as String? ?? 'Byte'],
      colorInterpretations: [for (final b in bands) b['colorInterpretation'] as String? ?? 'Undefined'],
      crsWkt: wkt,
      epsg: epsg == null ? null : int.parse(epsg),
      proj4: proj4?.trim(),
      west: lons.reduce(math.min),
      east: lons.reduce(math.max),
      south: lats.reduce(math.min),
      north: lats.reduce(math.max),
    );
  }

  /// PNG の画素数。長辺は元の画素数（上限 [maxLongSide]）、縦横比は地上の長さ（メートル）に合わせる
  static (int, int) outputSize(GdalRasterProbe probe) {
    final longSide = math.min(maxLongSide, math.max(probe.width, probe.height));
    final midLat = (probe.south + probe.north) / 2 * math.pi / 180;
    final wm = (probe.east - probe.west) * math.cos(midLat);
    final hm = probe.north - probe.south;
    if (wm <= 0 || hm <= 0) return (math.max(1, probe.width), math.max(1, probe.height));
    final aspect = wm / hm;
    return aspect >= 1
        ? (longSide, math.max(1, (longSide / aspect).round()))
        : (math.max(1, (longSide * aspect).round()), longSide);
  }

  /// 経緯度の範囲と PNG の画素数 → 回転なしのオーバーレイの形（縦方向で m/px を決める）
  static KMetaImageOverlay paramsFor({
    required double west,
    required double south,
    required double east,
    required double north,
    required int width,
    required int height,
  }) =>
      KMetaImageOverlay(
        centerLng: (west + east) / 2,
        centerLat: (south + north) / 2,
        scale: (north - south) * 111320.0 / height,
        rotation: 0,
        imageWidth: width,
        imageHeight: height,
      );

  /// 判定時の仮の形（`wgs84Extent` から）。PNG を作ったらワープ後の範囲で置き換える
  static KMetaImageOverlay initialParams(GdalRasterProbe probe) {
    final (w, h) = outputSize(probe);
    return paramsFor(west: probe.west, south: probe.south, east: probe.east, north: probe.north, width: w, height: h);
  }

  /// キャッシュの置き場。Android は GeoTiffService と同じアプリのキャッシュ領域、
  /// web はアプリのキャッシュ領域が無いので読み取り専用レイヤのキャッシュと同じくプロジェクトの `.kokage/cache/overlay`
  /// （同期は点で始まるものを運ばない。`ExternalLayerCache.cacheDirFor` と同じ考え）
  static Future<String> _cacheDir(String src) async {
    final dir = _cacheDirOverride ??
        (kIsWeb
            ? p.join(ProjectPathResolver.instance.rootPath ?? p.dirname(src), GlobalFolderLocator.systemDirName, 'cache',
                'overlay')
            : p.join((await getApplicationCacheDirectory()).path, 'overlay_png_cache'));
    if (!await fs.isDirectory(dir)) await fs.createDirectory(dir);
    return dir;
  }

  /// 小さく（長辺 16 画素）ワープした範囲 (西, 南, 東, 北)。GCP のラスタの判定用
  static Future<(double, double, double, double)> _warpedBounds(String src) async {
    final tmp = p.join(await _cacheDir(src), 'probe_${stableHashHex(src, length: 16)}.tif');
    await _deleteQuietly(tmp);
    try {
      await _g.warp(src, tmp, args: const ['-t_srs', 'EPSG:4326', '-ts', '16', '0', '-of', 'GTiff', '-overwrite']);
      final info = await _g.rasterInfo(tmp);
      final gt = (info['geoTransform'] as List).map((v) => (v as num).toDouble()).toList();
      final size = (info['size'] as List).map((v) => (v as num).toInt()).toList();
      return (gt[0], gt[3] + gt[5] * size[1], gt[0] + gt[1] * size[0], gt[3]);
    } finally {
      await _deleteQuietly(tmp);
    }
  }

  static String _key(String src) => 'ext_${stableHashHex(src, length: 16)}';

  /// 元のファイル一式（`GDALGetFileList`。.pgw・.aux.xml・.ovr・.tfw …、自分自身を含む）。GDAL で開けなければ自分だけ
  static Future<List<String>> sourceFiles(String src) async {
    try {
      final files = await _g.fileList(src);
      if (files.isNotEmpty) return files;
    } catch (e) {
      AppLogger.debug('[GdalRasterOverlay] ${p.basename(src)} の付属ファイルを数えられない: $e');
    }
    return [src];
  }

  /// [src] の PNG キャッシュと形の控えを消す
  static Future<void> discardCache(String src) async {
    final dir = await _cacheDir(src);
    await _deleteQuietly(p.join(dir, '${_key(src)}.png'));
    await _deleteQuietly(p.join(dir, '${_key(src)}.json'));
    _probeCache.remove(src);
  }

  /// PNG キャッシュを作る（あれば使う）。付属ファイル一式（`GDALGetFileList`）の大きさ・更新時刻が変われば作り直す
  static Future<GdalRasterRender> render(String src, GdalRasterProbe probe) async {
    final dir = await _cacheDir(src);
    final key = _key(src);
    final png = p.join(dir, '$key.png');
    final meta = p.join(dir, '$key.json');

    final files = await _g.fileList(src);
    final stamp = [
      for (final f in files) '${p.basename(f)}:${await fs.length(f)}:${(await fs.lastModified(f))?.millisecondsSinceEpoch}',
    ].join('|');

    if (await fs.exists(png) && await fs.exists(meta)) {
      try {
        final j = jsonDecode(await fs.readAsString(meta)) as Map<String, dynamic>;
        if (j['stamp'] == stamp) {
          return GdalRasterRender(pngPath: png, params: KMetaImageOverlay.fromJson((j['params'] as Map).cast()));
        }
      } catch (_) {} // 壊れていれば作り直す
    }

    final sw = Stopwatch()..start();
    final tmp = p.join(dir, '$key.warp.tif');
    await _deleteQuietly(tmp);
    final (w, h) = outputSize(probe);
    final stretch = probe.needsStretch;
    await _g.warp(src, tmp, args: [
      '-t_srs', 'EPSG:4326', '-ts', '$w', '$h', '-r', probe.isPalette ? 'near' : 'bilinear', '-dstalpha', '-of', 'GTiff',
      '-overwrite',
      // 伸ばすときは、範囲外と nodata を統計から外すため NaN を nodata にした Float32 で受ける
      // （-dstalpha だけでは範囲外が 0 の値になり、gdalinfo -stats の最小値に入ってしまう）
      if (stretch) ...['-ot', 'Float32', '-dstnodata', 'nan'],
    ]);
    try {
      // -mm（最小・最大を数えるだけ）。-stats は .aux.xml を書こうとする（web の入力は読み取り専用で mount される）
      final info = await _g.rasterInfo(tmp, args: stretch ? const ['-mm'] : const []);
      final gt = (info['geoTransform'] as List).map((v) => (v as num).toDouble()).toList();
      final size = (info['size'] as List).map((v) => (v as num).toInt()).toList();
      final params = paramsFor(
        west: gt[0],
        north: gt[3],
        east: gt[0] + gt[1] * size[0],
        south: gt[3] + gt[5] * size[1],
        width: size[0],
        height: size[1],
      );

      // 色表は RGBA に開く（ワープの -dstalpha のアルファはそのまま 4 バンド目に残る）
      final args = ['-of', 'PNG', if (probe.isPalette) ...['-expand', 'rgba']];
      if (stretch) {
        args.addAll(['-ot', 'Byte']);
        final bands = (info['bands'] as List).cast<Map>();
        for (var i = 0; i < bands.length; i++) {
          final b = bands[i];
          if (b['colorInterpretation'] == 'Alpha') continue; // 0/最大値 → Byte に丸まる
          final min = (b['computedMin'] ?? b['minimum']) as num?;
          final max = (b['computedMax'] ?? b['maximum']) as num?;
          if (min == null || max == null) continue;
          final hi = max > min ? max : min + 1;
          args.addAll(['-scale_${i + 1}', '$min', '$hi', '0', '255']);
        }
      }
      await _deleteQuietly(png);
      await _g.translate(tmp, png, args: args);
      await fs.writeAsString(meta, jsonEncode({'stamp': stamp, 'src': src, 'params': params.toJson()}));
      AppLogger.debug('[GdalRasterOverlay] ${p.basename(src)} → ${size[0]}x${size[1]} PNG (${sw.elapsedMilliseconds}ms)');
      return GdalRasterRender(pngPath: png, params: params);
    } finally {
      await _deleteQuietly(tmp);
      await _deleteQuietly('$tmp.aux.xml');
      await _deleteQuietly('$png.aux.xml');
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      if (await fs.exists(path)) await fs.delete(path);
    } catch (_) {}
  }
}
