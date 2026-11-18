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

/// PMTiles v3 の純粋 Dart HTTP `Range` リーダー。
///
/// 単一の `.pmtiles` アーカイブから 127 バイトのヘッダと Hilbert 曲線のディレクトリ索引を読み、
/// 指定された `(z, x, y)` タイルの圧縮データだけを `Range: bytes=start-end` で取得する。
/// 地籍筆界や県別の森林小班など、静的ストレージ（Cloudflare R2 等）に置いたアーカイブを
/// サーバーレスでそのまま配信・閲覧できるようにする基盤。
library;

import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoder, ZLibDecoder;

/// Byte range 取得コールバック (`start` から `length` バイトを取得して返す)
typedef ByteRangeFetcher = Future<Uint8List?> Function(int offset, int length);

/// PMTiles v3 ヘッダ（127 bytes）
class PmTilesHeader {
  const PmTilesHeader({
    required this.rootDirOffset,
    required this.rootDirLength,
    required this.metadataOffset,
    required this.metadataLength,
    required this.leafDirsOffset,
    required this.leafDirsLength,
    required this.tileDataOffset,
    required this.tileDataLength,
    required this.internalCompression,
    required this.tileCompression,
    required this.tileType,
    required this.minZoom,
    required this.maxZoom,
  });

  final int rootDirOffset;
  final int rootDirLength;
  final int metadataOffset;
  final int metadataLength;
  final int leafDirsOffset;
  final int leafDirsLength;
  final int tileDataOffset;
  final int tileDataLength;

  /// 1 = none, 2 = gzip, 3 = brotli, 4 = zstd
  final int internalCompression;
  final int tileCompression;

  /// 1 = MVT, 2 = PNG, 3 = JPEG, 4 = WebP, 5 = AVIF
  final int tileType;
  final int minZoom;
  final int maxZoom;

  static PmTilesHeader? parse(Uint8List bytes) {
    if (bytes.length < 127) return null;
    // Magic: "PMTiles" + version 3
    const magic = [0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73, 0x03];
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return null;
    }
    return PmTilesHeader(
      rootDirOffset: _readUint64LE(bytes, 8),
      rootDirLength: _readUint64LE(bytes, 16),
      metadataOffset: _readUint64LE(bytes, 24),
      metadataLength: _readUint64LE(bytes, 32),
      leafDirsOffset: _readUint64LE(bytes, 40),
      leafDirsLength: _readUint64LE(bytes, 48),
      tileDataOffset: _readUint64LE(bytes, 56),
      tileDataLength: _readUint64LE(bytes, 64),
      internalCompression: bytes[97],
      tileCompression: bytes[98],
      tileType: bytes[99],
      minZoom: bytes[100],
      maxZoom: bytes[101],
    );
  }

  /// JS (Web) でも 53bit まで正確に読める Little-Endian uint64
  static int _readUint64LE(Uint8List b, int pos) {
    final bd = ByteData.sublistView(b, pos, pos + 8);
    final lo = bd.getUint32(0, Endian.little);
    final hi = bd.getUint32(4, Endian.little);
    return hi * 4294967296 + lo;
  }
}

/// PMTiles ディレクトリの 1 エントリ
class PmTilesEntry {
  const PmTilesEntry({
    required this.tileId,
    required this.offset,
    required this.length,
    required this.runLength,
  });

  final int tileId;
  final int offset;
  final int length;

  /// `runLength == 0` は leaf directory、`> 0` は連続する同一タイル数
  final int runLength;
}

/// 単一 `.pmtiles` リソースのリーダー（ヘッダとディレクトリをメモリに控え、並行取得を合流させる）
class PmTilesReader {
  PmTilesReader(this.fetchRange);

  final ByteRangeFetcher fetchRange;

  PmTilesHeader? _header;
  List<PmTilesEntry>? _rootEntries;
  Future<bool>? _initFuture;
  final Map<(int, int), List<PmTilesEntry>> _leafCache = {};

  static const GZipDecoder _gzip = GZipDecoder();
  static const ZLibDecoder _zlib = ZLibDecoder();

  /// `(z, x, y)` を PMTiles v3 の Hilbert 曲線 `tileId` に変換する
  static int zxyToTileId(int z, int x, int y) {
    if (z == 0) return 0;
    // 前のズームまでの累積タイル数: (4^z - 1) / 3
    var acc = 0;
    var pow4 = 1;
    for (var i = 0; i < z; i++) {
      acc += pow4;
      pow4 *= 4;
    }
    var tx = x;
    var ty = y;
    var d = 0;
    var s = 1 << (z - 1);
    while (s > 0) {
      final rx = (tx & s) > 0 ? 1 : 0;
      final ry = (ty & s) > 0 ? 1 : 0;
      d += s * s * ((3 * rx) ^ ry);
      if (ry == 0) {
        if (rx == 1) {
          tx = s - 1 - tx;
          ty = s - 1 - ty;
        }
        final tmp = tx;
        tx = ty;
        ty = tmp;
      }
      s ~/= 2;
    }
    return acc + d;
  }

  Future<bool> _ensureInitialized() => _initFuture ??= _init();

  Future<bool> _init() async {
    // 先頭 16KB を 1 回の Range 取得で読めば、通常ヘッダとルートディレクトリの両方が収まる
    final head = await fetchRange(0, 16384);
    if (head == null || head.length < 127) return false;
    final h = PmTilesHeader.parse(head);
    if (h == null) return false;
    _header = h;

    Uint8List? rootBytes;
    if (h.rootDirOffset + h.rootDirLength <= head.length) {
      rootBytes = Uint8List.sublistView(head, h.rootDirOffset, h.rootDirOffset + h.rootDirLength);
    } else {
      rootBytes = await fetchRange(h.rootDirOffset, h.rootDirLength);
    }
    if (rootBytes == null) return false;
    final decompressed = _decompress(rootBytes, h.internalCompression);
    if (decompressed == null) return false;
    _rootEntries = deserializeDirectory(decompressed);
    return true;
  }

  /// 指定タイルのバイト列を返す（無ければ null。MVT の場合は展開後の `.pbf`、または gzip のままでも `MvtDecoder` が読める）
  Future<Uint8List?> getTile(int z, int x, int y) async {
    if (!await _ensureInitialized()) return null;
    final h = _header!;
    if (z < h.minZoom || z > h.maxZoom) return null;
    final targetId = zxyToTileId(z, x, y);

    var entries = _rootEntries!;
    for (var depth = 0; depth < 4; depth++) {
      final hit = findEntry(entries, targetId);
      if (hit == null) return null;
      if (hit.runLength > 0) {
        final raw = await fetchRange(h.tileDataOffset + hit.offset, hit.length);
        if (raw == null) return null;
        return _decompress(raw, h.tileCompression);
      }
      // Leaf directory
      final leafKey = (hit.offset, hit.length);
      var leaf = _leafCache[leafKey];
      if (leaf == null) {
        final leafRaw = await fetchRange(h.leafDirsOffset + hit.offset, hit.length);
        if (leafRaw == null) return null;
        final dec = _decompress(leafRaw, h.internalCompression);
        if (dec == null) return null;
        leaf = deserializeDirectory(dec);
        if (_leafCache.length >= 64) _leafCache.remove(_leafCache.keys.first);
        _leafCache[leafKey] = leaf;
      }
      entries = leaf;
    }
    return null;
  }

  static Uint8List? _decompress(Uint8List data, int compression) {
    switch (compression) {
      case 1: // none
        return data;
      case 2: // gzip
        if (data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
          return _gzip.decodeBytes(data);
        }
        return _zlib.decodeBytes(data);
      default:
        return null;
    }
  }

  /// PMTiles v3 の圧縮ディレクトリ（列指向の varint 配列）を復号する
  static List<PmTilesEntry> deserializeDirectory(Uint8List buf) {
    var pos = 0;
    int readVarint() {
      var res = 0;
      var factor = 1;
      while (pos < buf.length) {
        final b = buf[pos++];
        res += (b & 0x7f) * factor;
        if ((b & 0x80) == 0) return res;
        factor *= 128;
      }
      return res;
    }

    final n = readVarint();
    if (n <= 0) return const [];
    final tileIds = List<int>.filled(n, 0);
    final runLengths = List<int>.filled(n, 0);
    final lengths = List<int>.filled(n, 0);
    final offsets = List<int>.filled(n, 0);

    var lastId = 0;
    for (var i = 0; i < n; i++) {
      lastId += readVarint();
      tileIds[i] = lastId;
    }
    for (var i = 0; i < n; i++) {
      runLengths[i] = readVarint();
    }
    for (var i = 0; i < n; i++) {
      lengths[i] = readVarint();
    }
    for (var i = 0; i < n; i++) {
      final v = readVarint();
      offsets[i] = (v == 0 && i > 0) ? offsets[i - 1] + lengths[i - 1] : v - 1;
    }

    return [
      for (var i = 0; i < n; i++)
        PmTilesEntry(
          tileId: tileIds[i],
          offset: offsets[i],
          length: lengths[i],
          runLength: runLengths[i],
        ),
    ];
  }

  /// 二分探索で `targetId` に該当するエントリまたは leaf directory を探す
  static PmTilesEntry? findEntry(List<PmTilesEntry> entries, int targetId) {
    if (entries.isEmpty) return null;
    var lo = 0;
    var hi = entries.length - 1;
    var idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (entries[mid].tileId <= targetId) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (idx < 0) return null;
    final e = entries[idx];
    if (e.runLength == 0) return e; // leaf directory
    return targetId < e.tileId + e.runLength ? e : null;
  }
}
