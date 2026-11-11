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

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'terrain_worker.dart';
import 'web_mercator.dart';

/// 和歌山県 1.0m グリッド（平面直角座標系第 VI 系 / EPSG:6674）の Potree 2.0 配信から、
/// 地理院互換の数値 PNG タイル（256×256, 0.01m 単位）をオンデマンド生成するアダプタ。
///
/// - 配信元: `https://3d.wakayamaken.geocloud.jp/outside/GridData/Common/3DData/{mesh}_1g_{mesh}_1g/potree/`
/// - 原典の平面直角座標系第 VI 系（EPSG:6674）の 1.0m 正方グリッドに無補間で戻してから、
///   1px 孤立スパイク（植生・電線等の取り残し）だけを 3×3 近傍判定で除去し、砂防堰堤・擁壁・道路法肩の角を保つ。
class WakayamaPotreeDemGenerator {
  WakayamaPotreeDemGenerator({http.Client? client}) : _http = client ?? http.Client();

  static final WakayamaPotreeDemGenerator instance = WakayamaPotreeDemGenerator();

  final http.Client _http;

  static const String _baseUrl = 'https://3d.wakayamaken.geocloud.jp/outside/GridData/Common/3DData';

  /// 図郭ごとのメタデータと階層木（1 図郭あたり約 10〜30KB）。404 だった図郭は null を入れて再試行しない
  final LinkedHashMap<String, _PotreeSheetIndex?> _sheetCache = LinkedHashMap();
  final Map<String, Future<_PotreeSheetIndex?>> _sheetInflight = {};
  static const int _maxCachedSheets = 64;

  /// 図郭の octree.bin の個別ノード単位の LRU キャッシュ（隣接タイル間で上位・境界ノードを 100% 共有する）
  final LinkedHashMap<String, Uint8List> _nodeCache = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _nodeInflight = {};
  int _nodeCacheBytes = 0;
  static const int _maxNodeCacheBytes = 48 << 20; // 48 MB

  /// タイル (z, x, y) の数値 PNG を生成する（データが無ければ null）
  Future<Uint8List?> generateTile(int z, int x, int y) async {
    if (z < 16 || z > 17) return null;
    final west = WebMercator.tileWest(x, z);
    final east = WebMercator.tileWest(x + 1, z);
    final north = WebMercator.tileNorth(y, z);
    final south = WebMercator.tileNorth(y + 1, z);

    // タイル境界の補間・3×3 デスパイク用に 8m の余白を取る
    const margin3857 = 8.0;
    final xMin = west - margin3857;
    final xMax = east + margin3857;
    final yMin = south - margin3857;
    final yMax = north + margin3857;

    final (e00, n00) = epsg3857ToEpsg6674(xMin, yMin);
    final (e10, n10) = epsg3857ToEpsg6674(xMax, yMin);
    final (e01, n01) = epsg3857ToEpsg6674(xMin, yMax);
    final (e11, n11) = epsg3857ToEpsg6674(xMax, yMax);

    final eMin = math.min(math.min(e00, e10), math.min(e01, e11));
    final eMax = math.max(math.max(e00, e10), math.max(e01, e11));
    final nMin = math.min(math.min(n00, n10), math.min(n01, n11));
    final nMax = math.max(math.max(n00, n10), math.max(n01, n11));

    final meshes = epsg6674ToWakayamaMeshes(eMin, nMin, eMax, nMax);
    if (meshes.isEmpty) return null;

    final chunks = <WakayamaPotreeChunk>[];
    for (final mesh in meshes) {
      final sheet = await _loadSheetIndex(mesh);
      if (sheet == null) continue;
      final hitNodes = [
        for (final node in sheet.nodes)
          if (node.byteSize > 0 &&
              node.maxX >= xMin &&
              node.minX <= xMax &&
              node.maxY >= yMin &&
              node.minY <= yMax)
            node,
      ];
      if (hitNodes.isEmpty) continue;

      final nodeBytes = await _loadNodesForSheet(mesh, hitNodes);
      for (final bytes in nodeBytes) {
        if (bytes == null) continue;
        chunks.add(
          WakayamaPotreeChunk(
            bytes: bytes,
            stride: sheet.stride,
            scaleX: sheet.scaleX,
            scaleY: sheet.scaleY,
            scaleZ: sheet.scaleZ,
            offsetX: sheet.offsetX,
            offsetY: sheet.offsetY,
            offsetZ: sheet.offsetZ,
          ),
        );
      }
    }

    if (chunks.isEmpty) return null;

    return TerrainWorker.instance.run(
      rasterizeWakayamaPotreeTilePng,
      WakayamaPotreeRasterArgs(z: z, x: x, y: y, chunks: chunks),
    );
  }

  Future<_PotreeSheetIndex?> _loadSheetIndex(String mesh) {
    if (_sheetCache.containsKey(mesh)) {
      final cached = _sheetCache.remove(mesh);
      _sheetCache[mesh] = cached;
      return Future.value(cached);
    }
    final running = _sheetInflight[mesh];
    if (running != null) return running;
    final future = _sheetInflight[mesh] = _fetchSheetIndex(mesh);
    future.whenComplete(() => _sheetInflight.remove(mesh)).ignore();
    return future;
  }

  Future<_PotreeSheetIndex?> _fetchSheetIndex(String mesh) async {
    final prefix = '$_baseUrl/${mesh}_1g_${mesh}_1g/potree';
    try {
      final metaRes = await _http.get(Uri.parse('$prefix/metadata.json')).timeout(const Duration(seconds: 8));
      if (metaRes.statusCode == 404) {
        _putSheetCache(mesh, null);
        return null;
      }
      if (metaRes.statusCode != 200) return null;

      final hierRes = await _http.get(Uri.parse('$prefix/hierarchy.bin')).timeout(const Duration(seconds: 8));
      if (hierRes.statusCode != 200) return null;

      final meta = jsonDecode(utf8.decode(metaRes.bodyBytes)) as Map<String, dynamic>;
      final hierarchy = meta['hierarchy'] as Map<String, dynamic>;
      final firstChunkSize = (hierarchy['firstChunkSize'] as num).toInt();
      final bbox = meta['boundingBox'] as Map<String, dynamic>;
      final bMin = (bbox['min'] as List).cast<num>().map((e) => e.toDouble()).toList();
      final bMax = (bbox['max'] as List).cast<num>().map((e) => e.toDouble()).toList();
      final scale = (meta['scale'] as List).cast<num>().map((e) => e.toDouble()).toList();
      final offset = (meta['offset'] as List).cast<num>().map((e) => e.toDouble()).toList();
      final attrs = (meta['attributes'] as List).cast<Map<String, dynamic>>();
      var stride = 0;
      for (final a in attrs) {
        stride += (a['size'] as num).toInt();
      }
      if (stride < 12) return null;

      final nodes = parsePotreeHierarchy(hierRes.bodyBytes, firstChunkSize, bMin, bMax);
      final index = _PotreeSheetIndex(
        stride: stride,
        scaleX: scale[0],
        scaleY: scale[1],
        scaleZ: scale[2],
        offsetX: offset[0],
        offsetY: offset[1],
        offsetZ: offset[2],
        nodes: nodes,
      );
      _putSheetCache(mesh, index);
      return index;
    } catch (e) {
      debugPrint('[WakayamaPotree] metadata/hierarchy error ($mesh): $e');
      return null;
    }
  }

  void _putSheetCache(String mesh, _PotreeSheetIndex? index) {
    _sheetCache.remove(mesh);
    _sheetCache[mesh] = index;
    while (_sheetCache.length > _maxCachedSheets) {
      _sheetCache.remove(_sheetCache.keys.first);
    }
  }

  void _putNodeCache(String key, Uint8List bytes) {
    final prev = _nodeCache.remove(key);
    if (prev != null) _nodeCacheBytes -= prev.length;
    _nodeCache[key] = bytes;
    _nodeCacheBytes += bytes.length;
    while (_nodeCacheBytes > _maxNodeCacheBytes && _nodeCache.isNotEmpty) {
      final oldestKey = _nodeCache.keys.first;
      final removed = _nodeCache.remove(oldestKey);
      if (removed != null) _nodeCacheBytes -= removed.length;
    }
  }

  /// ノード単位でメモリキャッシュと in-flight を共有しつつ、未取得ノードだけを近接 Range に束ねて取得する
  Future<List<Uint8List?>> _loadNodesForSheet(String mesh, List<PotreeOctreeNode> hitNodes) async {
    final futures = <Future<Uint8List?>>[];
    final toFetch = <(PotreeOctreeNode node, Completer<Uint8List?> completer, String key)>[];

    for (final n in hitNodes) {
      final key = '$mesh:${n.byteOffset}';
      final cached = _nodeCache.remove(key);
      if (cached != null) {
        _nodeCache[key] = cached;
        futures.add(Future.value(cached));
        continue;
      }
      final inflight = _nodeInflight[key];
      if (inflight != null) {
        futures.add(inflight);
        continue;
      }
      final completer = Completer<Uint8List?>();
      _nodeInflight[key] = completer.future;
      futures.add(completer.future);
      toFetch.add((n, completer, key));
    }

    if (toFetch.isNotEmpty) {
      toFetch.sort((a, b) => a.$1.byteOffset.compareTo(b.$1.byteOffset));
      final groups = <List<(PotreeOctreeNode, Completer<Uint8List?>, String)>>[];
      for (final item in toFetch) {
        final s = item.$1.byteOffset;
        if (groups.isNotEmpty) {
          final lastGroup = groups.last;
          final firstS = lastGroup.first.$1.byteOffset;
          final lastNode = lastGroup.last.$1;
          final lastE = lastNode.byteOffset + lastNode.byteSize;
          final newE = math.max(lastE, s + item.$1.byteSize);
          if (s <= lastE + 65536 && (newE - firstS) <= (1536 * 1024)) {
            lastGroup.add(item);
            continue;
          }
        }
        groups.add([item]);
      }

      final url = '$_baseUrl/${mesh}_1g_${mesh}_1g/potree/octree.bin';
      await Future.wait([
        for (final group in groups)
          () async {
            final start = group.first.$1.byteOffset;
            var end = start;
            for (final item in group) {
              final ne = item.$1.byteOffset + item.$1.byteSize;
              if (ne > end) end = ne;
            }
            Uint8List? buf;
            try {
              final res = await _http.get(
                Uri.parse(url),
                headers: {'Range': 'bytes=$start-${end - 1}'},
              ).timeout(const Duration(seconds: 12));
              if (res.statusCode == 206 || res.statusCode == 200) {
                buf = res.bodyBytes;
              }
            } catch (e) {
              debugPrint('[WakayamaPotree] octree range error ($mesh:$start-$end): $e');
            }
            for (final (node, completer, key) in group) {
              _nodeInflight.remove(key)?.ignore();
              final relStart = node.byteOffset - start;
              final relEnd = relStart + node.byteSize;
              if (buf != null && relStart >= 0 && relEnd <= buf.length) {
                final slice = Uint8List.fromList(Uint8List.sublistView(buf, relStart, relEnd));
                _putNodeCache(key, slice);
                completer.complete(slice);
              } else {
                completer.complete(null);
              }
            }
          }(),
      ]);
    }

    return Future.wait(futures);
  }
}

class _PotreeSheetIndex {
  const _PotreeSheetIndex({
    required this.stride,
    required this.scaleX,
    required this.scaleY,
    required this.scaleZ,
    required this.offsetX,
    required this.offsetY,
    required this.offsetZ,
    required this.nodes,
  });

  final int stride;
  final double scaleX, scaleY, scaleZ;
  final double offsetX, offsetY, offsetZ;
  final List<PotreeOctreeNode> nodes;
}

/// Potree 2.0 の octree ノード情報
class PotreeOctreeNode {
  const PotreeOctreeNode({
    required this.minX,
    required this.minY,
    required this.minZ,
    required this.maxX,
    required this.maxY,
    required this.maxZ,
    required this.byteOffset,
    required this.byteSize,
    required this.numPoints,
  });

  final double minX, minY, minZ;
  final double maxX, maxY, maxZ;
  final int byteOffset;
  final int byteSize;
  final int numPoints;
}

/// Potree 2.0 の `hierarchy.bin` を解析して全ノードの境界とバイト範囲を返す
List<PotreeOctreeNode> parsePotreeHierarchy(
  Uint8List hBuf,
  int firstChunkSize,
  List<double> rootMin,
  List<double> rootMax,
) {
  final nodes = <PotreeOctreeNode>[];
  final bd = ByteData.sublistView(hBuf);

  void loadChunk(int chunkOffset, int chunkSize, List<double> rMin, List<double> rMax) {
    if (chunkOffset < 0 || chunkSize <= 0 || chunkOffset + chunkSize > hBuf.length) return;
    final nRec = chunkSize ~/ 22;
    final boxes = <(List<double>, List<double>)>[(rMin, rMax)];
    for (var i = 0; i < nRec; i++) {
      if (i >= boxes.length) break;
      final pos = chunkOffset + i * 22;
      final ntype = bd.getUint8(pos);
      final cmask = bd.getUint8(pos + 1);
      final npts = bd.getUint32(pos + 2, Endian.little);
      // JS (Web) 環境でも安全に 64bit 整数を読むため 32bit × 2 で合成
      final boffLo = bd.getUint32(pos + 6, Endian.little);
      final boffHi = bd.getUint32(pos + 10, Endian.little);
      final boff = boffHi * 0x100000000 + boffLo;
      final bsizeLo = bd.getUint32(pos + 14, Endian.little);
      final bsizeHi = bd.getUint32(pos + 18, Endian.little);
      final bsize = bsizeHi * 0x100000000 + bsizeLo;

      final (bmin, bmax) = boxes[i];
      if (ntype == 2) {
        loadChunk(boff, bsize, bmin, bmax);
      } else {
        nodes.add(
          PotreeOctreeNode(
            minX: bmin[0],
            minY: bmin[1],
            minZ: bmin[2],
            maxX: bmax[0],
            maxY: bmax[1],
            maxZ: bmax[2],
            byteOffset: boff,
            byteSize: bsize,
            numPoints: npts,
          ),
        );
        final midX = (bmin[0] + bmax[0]) * 0.5;
        final midY = (bmin[1] + bmax[1]) * 0.5;
        final midZ = (bmin[2] + bmax[2]) * 0.5;
        for (var childIdx = 0; childIdx < 8; childIdx++) {
          if ((cmask & (1 << childIdx)) != 0) {
            final xBit = (childIdx & 4) != 0;
            final yBit = (childIdx & 2) != 0;
            final zBit = (childIdx & 1) != 0;
            boxes.add((
              [xBit ? midX : bmin[0], yBit ? midY : bmin[1], zBit ? midZ : bmin[2]],
              [xBit ? bmax[0] : midX, yBit ? bmax[1] : midY, zBit ? bmax[2] : midZ],
            ));
          }
        }
      }
    }
  }

  loadChunk(0, firstChunkSize, rootMin, rootMax);
  return nodes;
}

/// 平面直角座標系第 VI 系（EPSG:6674）の範囲に掛かる 1:2,500 国土基本図の図郭コード一覧を返す
List<String> epsg6674ToWakayamaMeshes(double eMin, double nMin, double eMax, double nMax) {
  final meshes = <String>{};
  final ys = <double>[];
  for (var y = nMin; y < nMax; y += 250.0) {
    ys.add(y);
  }
  ys.add(nMax);
  final xs = <double>[];
  for (var x = eMin; x < eMax; x += 250.0) {
    xs.add(x);
  }
  xs.add(eMax);

  for (final y in ys) {
    final rowIdx = (-y / 30000.0).floor();
    if (rowIdx < 0 || rowIdx > 12) continue;
    final rowLetter = String.fromCharCode(0x4B + rowIdx); // 'K' + rowIdx
    final topY = -rowIdx * 30000.0;
    final dy = topY - y;
    final ydig = (dy ~/ 3000.0).clamp(0, 9);
    final subY = dy - ydig * 3000.0;

    for (final x in xs) {
      final colOffset = (x / 40000.0).floor();
      if (colOffset < -4 || colOffset > 3) continue;
      final colLetter = String.fromCharCode(0x45 + colOffset); // 'E' + colOffset
      final leftX = colOffset * 40000.0;
      final dx = x - leftX;
      final xdig = (dx ~/ 4000.0).clamp(0, 9);
      final subX = dx - xdig * 4000.0;
      final quad = (subY < 1500.0 ? 1 : 3) + (subX < 2000.0 ? 0 : 1);
      meshes.add('06$rowLetter$colLetter$ydig$xdig$quad');
    }
  }
  final sorted = meshes.toList()..sort();
  return sorted;
}

// ── GRS80 平面直角座標系第 VI 系（EPSG:6674: 原点 36°N, 136°E, m0 = 0.9999）河瀬公式 ──

const double _grs80A = 6378137.0;
const double _grs80Rf = 298.257222101;
const double _grs80F = 1.0 / _grs80Rf;
const double _grs80N = _grs80F / (2.0 - _grs80F);
const double _grs80N2 = _grs80N * _grs80N;
const double _grs80N3 = _grs80N2 * _grs80N;
const double _grs80N4 = _grs80N3 * _grs80N;
const double _grs80N5 = _grs80N4 * _grs80N;

const double _cs6Lat0 = 36.0 * math.pi / 180.0;
const double _cs6Lon0 = 136.0 * math.pi / 180.0;
const double _cs6M0 = 0.9999;

const double _a0 = 1.0 + _grs80N2 / 4.0 + _grs80N4 / 64.0;
const double _a1 = -1.5 * (_grs80N - _grs80N3 / 8.0 - _grs80N5 / 64.0);
const double _a2 = 0.9375 * (_grs80N2 - _grs80N4 / 4.0);
const double _a3 = -(35.0 / 48.0) * (_grs80N3 - (5.0 / 16.0) * _grs80N5);
const double _a4 = (315.0 / 512.0) * _grs80N4;
const double _a5 = -(693.0 / 1280.0) * _grs80N5;

const double _alpha1 =
    0.5 * _grs80N - (2.0 / 3.0) * _grs80N2 + (5.0 / 16.0) * _grs80N3 + (41.0 / 180.0) * _grs80N4 - (127.0 / 288.0) * _grs80N5;
const double _alpha2 =
    (13.0 / 48.0) * _grs80N2 - (3.0 / 5.0) * _grs80N3 + (557.0 / 1440.0) * _grs80N4 + (281.0 / 630.0) * _grs80N5;
const double _alpha3 = (61.0 / 240.0) * _grs80N3 - (103.0 / 140.0) * _grs80N4 + (15061.0 / 26880.0) * _grs80N5;
const double _alpha4 = (49561.0 / 161280.0) * _grs80N4 - (179.0 / 168.0) * _grs80N5;
const double _alpha5 = (34729.0 / 80640.0) * _grs80N5;

const double _aBar = (_cs6M0 * _grs80A / (1.0 + _grs80N)) * _a0;
final double _e2Sqrt = 2.0 * math.sqrt(_grs80N) / (1.0 + _grs80N);
final double _sPhi0 = (_cs6M0 * _grs80A / (1.0 + _grs80N)) *
    (_a0 * _cs6Lat0 +
        _a1 * math.sin(2.0 * _cs6Lat0) +
        _a2 * math.sin(4.0 * _cs6Lat0) +
        _a3 * math.sin(6.0 * _cs6Lat0) +
        _a4 * math.sin(8.0 * _cs6Lat0) +
        _a5 * math.sin(10.0 * _cs6Lat0));

double _sinh(double x) => (math.exp(x) - math.exp(-x)) * 0.5;
double _cosh(double x) => (math.exp(x) + math.exp(-x)) * 0.5;
double _atanh(double x) => 0.5 * math.log((1.0 + x) / (1.0 - x));

/// 経度・緯度（度）→ 平面直角座標系第 VI 系（EPSG:6674）の (東向き Y [m], 北向き X [m])
(double easting, double northing) lonLatToEpsg6674(double lonDeg, double latDeg) {
  final phi = latDeg * math.pi / 180.0;
  final lam = lonDeg * math.pi / 180.0 - _cs6Lon0;
  final sinPhi = math.sin(phi);
  final t = _sinh(_atanh(sinPhi) - _e2Sqrt * _atanh(_e2Sqrt * sinPhi));
  final xiP = math.atan(t / math.cos(lam));
  final etaP = _atanh(math.sin(lam) / math.sqrt(1.0 + t * t));

  final xNorth = _aBar *
          (xiP +
              _alpha1 * math.sin(2.0 * xiP) * _cosh(2.0 * etaP) +
              _alpha2 * math.sin(4.0 * xiP) * _cosh(4.0 * etaP) +
              _alpha3 * math.sin(6.0 * xiP) * _cosh(6.0 * etaP) +
              _alpha4 * math.sin(8.0 * xiP) * _cosh(8.0 * etaP) +
              _alpha5 * math.sin(10.0 * xiP) * _cosh(10.0 * etaP)) -
      _sPhi0;

  final yEast = _aBar *
      (etaP +
          _alpha1 * math.cos(2.0 * xiP) * _sinh(2.0 * etaP) +
          _alpha2 * math.cos(4.0 * xiP) * _sinh(4.0 * etaP) +
          _alpha3 * math.cos(6.0 * xiP) * _sinh(6.0 * etaP) +
          _alpha4 * math.cos(8.0 * xiP) * _sinh(8.0 * etaP) +
          _alpha5 * math.cos(10.0 * xiP) * _sinh(10.0 * etaP));

  return (yEast, xNorth);
}

/// Web Mercator（EPSG:3857）の (x, y) → 平面直角座標系第 VI 系（EPSG:6674）の (東向き Y [m], 北向き X [m])
(double easting, double northing) epsg3857ToEpsg6674(double x, double y) =>
    lonLatToEpsg6674(WebMercator.lonFromX(x), WebMercator.latFromY(y));

/// isolate に渡す Potree ノードのバイト列と量子化パラメータ
class WakayamaPotreeChunk {
  const WakayamaPotreeChunk({
    required this.bytes,
    required this.stride,
    required this.scaleX,
    required this.scaleY,
    required this.scaleZ,
    required this.offsetX,
    required this.offsetY,
    required this.offsetZ,
  });

  final Uint8List bytes;
  final int stride;
  final double scaleX, scaleY, scaleZ;
  final double offsetX, offsetY, offsetZ;
}

class WakayamaPotreeRasterArgs {
  const WakayamaPotreeRasterArgs({
    required this.z,
    required this.x,
    required this.y,
    required this.chunks,
  });

  final int z;
  final int x;
  final int y;
  final List<WakayamaPotreeChunk> chunks;
}

/// 3×3 近傍で 1px 孤立スパイク（中央値との差 > 2.5m かつ 1.5m 以内の隣接点が 1 点以下）だけを中央値に置き換える。
/// 砂防堰堤・擁壁・道路法肩などの線状・面状の段差は隣接点が 2 点以上連なるためそのまま残る。
@visibleForTesting
Float32List despikeIsolated1px(Float32List grid, int width, int height) {
  final out = Float32List.fromList(grid);
  final buf = Float32List(9);
  for (var r = 1; r < height - 1; r++) {
    final rowOff = r * width;
    for (var c = 1; c < width - 1; c++) {
      final center = grid[rowOff + c];
      if (center.isNaN) continue;
      var count = 0;
      var closeNeighbors = 0;
      for (var dr = -1; dr <= 1; dr++) {
        final nrOff = (r + dr) * width;
        for (var dc = -1; dc <= 1; dc++) {
          final v = grid[nrOff + c + dc];
          if (v.isNaN) continue;
          buf[count++] = v;
          if ((dr != 0 || dc != 0) && (v - center).abs() <= 1.5) {
            closeNeighbors++;
          }
        }
      }
      if (count < 5 || closeNeighbors > 1) continue;
      // 要素数 5〜9 の挿入ソートで中央値を求める
      for (var i = 1; i < count; i++) {
        final key = buf[i];
        var j = i - 1;
        while (j >= 0 && buf[j] > key) {
          buf[j + 1] = buf[j];
          j--;
        }
        buf[j + 1] = key;
      }
      final median = buf[count >> 1];
      if ((center - median).abs() > 2.5) {
        out[rowOff + c] = median;
      }
    }
  }
  return out;
}

/// Potree チャンク群から原典 1.0m グリッド（EPSG:6674）を復元・デスパイクし、
/// Web Mercator タイル (z, x, y) の地理院数値 PNG（256×256）に書き出す（isolate 用トップレベル関数）
Uint8List? rasterizeWakayamaPotreeTilePng(WakayamaPotreeRasterArgs args) {
  const ts = WebMercator.tileSize;
  final west = WebMercator.tileWest(args.x, args.z);
  final east = WebMercator.tileWest(args.x + 1, args.z);
  final north = WebMercator.tileNorth(args.y, args.z);
  final south = WebMercator.tileNorth(args.y + 1, args.z);

  const margin3857 = 8.0;
  final xMin = west - margin3857;
  final xMax = east + margin3857;
  final yMin = south - margin3857;
  final yMax = north + margin3857;
  final invSpanX = 1.0 / (xMax - xMin);
  final invSpanY = 1.0 / (yMax - yMin);

  final (e00, n00) = epsg3857ToEpsg6674(xMin, yMin);
  final (e10, n10) = epsg3857ToEpsg6674(xMax, yMin);
  final (e01, n01) = epsg3857ToEpsg6674(xMin, yMax);
  final (e11, n11) = epsg3857ToEpsg6674(xMax, yMax);

  final ixMin = math.min(math.min(e00, e10), math.min(e01, e11)).floor();
  final ixMax = math.max(math.max(e00, e10), math.max(e01, e11)).ceil();
  final iyMin = math.min(math.min(n00, n10), math.min(n01, n11)).floor();
  final iyMax = math.max(math.max(n00, n10), math.max(n01, n11)).ceil();

  final gw = ixMax - ixMin;
  final gh = iyMax - iyMin;
  if (gw <= 2 || gh <= 2 || gw > 2048 || gh > 2048) return null;

  var grid = Float32List(gw * gh)..fillRange(0, gw * gh, double.nan);
  var populated = 0;

  for (final chunk in args.chunks) {
    final stride = chunk.stride;
    final bytes = chunk.bytes;
    final bd = ByteData.sublistView(bytes);
    final nPts = bytes.length ~/ stride;
    final sx = chunk.scaleX, sy = chunk.scaleY, sz = chunk.scaleZ;
    final ox = chunk.offsetX, oy = chunk.offsetY, oz = chunk.offsetZ;

    for (var i = 0; i < nPts; i++) {
      final off = i * stride;
      final px = bd.getInt32(off, Endian.little) * sx + ox;
      if (px < xMin || px > xMax) continue;
      final py = bd.getInt32(off + 4, Endian.little) * sy + oy;
      if (py < yMin || py > yMax) continue;
      final pz = bd.getInt32(off + 8, Endian.little) * sz + oz;

      final u = (px - xMin) * invSpanX;
      final v = (py - yMin) * invSpanY;
      final pe = (e00 * (1.0 - u) + e10 * u) * (1.0 - v) + (e01 * (1.0 - u) + e11 * u) * v;
      final pn = (n00 * (1.0 - u) + n10 * u) * (1.0 - v) + (n01 * (1.0 - u) + n11 * u) * v;

      final col = (pe - ixMin).floor();
      final row = (iyMax - pn).floor();
      if (col >= 0 && col < gw && row >= 0 && row < gh) {
        final idx = row * gw + col;
        if (grid[idx].isNaN) populated++;
        grid[idx] = pz;
      }
    }
  }

  if (populated == 0) return null;

  // 陸域の 1〜2m の微小欠損（周囲 8 近傍に有効値が 3 点以上ある穴）だけ近傍平均で埋め、
  // 河川水面や整備範囲外の大穴は NaN のまま残して下位 DEM（DEM1A/5A）に委ねる
  for (var pass = 0; pass < 2; pass++) {
    final next = Float32List.fromList(grid);
    for (var r = 1; r < gh - 1; r++) {
      final rowOff = r * gw;
      for (var c = 1; c < gw - 1; c++) {
        if (!grid[rowOff + c].isNaN) continue;
        var sum = 0.0;
        var cnt = 0;
        for (var dr = -1; dr <= 1; dr++) {
          final nrOff = (r + dr) * gw;
          for (var dc = -1; dc <= 1; dc++) {
            final v = grid[nrOff + c + dc];
            if (!v.isNaN) {
              sum += v;
              cnt++;
            }
          }
        }
        if (cnt >= 3) next[rowOff + c] = sum / cnt;
      }
    }
    grid = next;
  }

  // 1px 孤立スパイク除去
  final despiked = despikeIsolated1px(grid, gw, gh);

  // Web Mercator タイル (256×256) の各ピクセル中心を双一次補間して地理院数値 PNG に符号化
  final outImage = img.Image(width: ts, height: ts, numChannels: 3);
  final outBytes = outImage.toUint8List();
  final mpp = WebMercator.metersPerPixel(args.z);
  var validPixels = 0;

  for (var iy = 0; iy < ts; iy++) {
    final py = north - (iy + 0.5) * mpp;
    final v = (py - yMin) * invSpanY;
    for (var ix = 0; ix < ts; ix++) {
      final px = west + (ix + 0.5) * mpp;
      final u = (px - xMin) * invSpanX;

      final pe = (e00 * (1.0 - u) + e10 * u) * (1.0 - v) + (e01 * (1.0 - u) + e11 * u) * v;
      final pn = (n00 * (1.0 - u) + n10 * u) * (1.0 - v) + (n01 * (1.0 - u) + n11 * u) * v;

      final fx = pe - ixMin - 0.5;
      final fy = iyMax - pn - 0.5;
      final c0 = fx.floor();
      final r0 = fy.floor();

      var elev = double.nan;
      if (c0 >= 0 && c0 + 1 < gw && r0 >= 0 && r0 + 1 < gh) {
        final tx = fx - c0;
        final ty = fy - r0;
        final idx00 = r0 * gw + c0;
        final v00 = despiked[idx00];
        final v10 = despiked[idx00 + 1];
        final v01 = despiked[idx00 + gw];
        final v11 = despiked[idx00 + gw + 1];
        if (!v00.isNaN && !v10.isNaN && !v01.isNaN && !v11.isNaN) {
          elev = (v00 * (1.0 - tx) + v10 * tx) * (1.0 - ty) + (v01 * (1.0 - tx) + v11 * tx) * ty;
        } else {
          final cr = fx.round().clamp(0, gw - 1);
          final rr = fy.round().clamp(0, gh - 1);
          elev = despiked[rr * gw + cr];
        }
      }

      final dst = (iy * ts + ix) * 3;
      if (elev.isNaN) {
        outBytes[dst] = 128;
        outBytes[dst + 1] = 0;
        outBytes[dst + 2] = 0;
      } else {
        validPixels++;
        var q = (elev * 100.0).round();
        if (q < 0) q += 1 << 24;
        outBytes[dst] = (q >> 16) & 0xFF;
        outBytes[dst + 1] = (q >> 8) & 0xFF;
        outBytes[dst + 2] = q & 0xFF;
      }
    }
  }

  if (validPixels == 0) return null;
  return Uint8List.fromList(img.encodePng(outImage, level: 1));
}
