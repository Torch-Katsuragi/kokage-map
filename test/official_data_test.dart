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

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipEncoder;
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/core/official/mvt_decoder.dart';
import 'package:root_maps/core/official/official_data_catalog.dart';
import 'package:root_maps/core/official/pmtiles_reader.dart';
import 'package:root_maps/core/terrain/cs_relief_tiles.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';
import 'package:root_maps/models/basemap_provider.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/global_folder_node.dart';
import 'package:root_maps/models/nodes/official_layer_node.dart';
import 'package:root_maps/models/nodes/sys_node.dart';
import 'package:root_maps/services/basemap_service.dart';
import 'package:root_maps/services/official/official_layer_service.dart';
import 'package:root_maps/services/tile_cache_mbtiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── テスト用 MVT / PMTiles エンコーダ補助 ────────────────────────

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 128) {
    out.addByte((v & 0x7f) | 0x80);
    v ~/= 128;
  }
  out.addByte(v & 0x7f);
}

int _zigzag(int n) => n >= 0 ? n * 2 : (-n) * 2 - 1;

void _writeTag(BytesBuilder out, int fieldNo, int wireType) =>
    _writeVarint(out, fieldNo * 8 + wireType);

void _writeBytesField(BytesBuilder out, int fieldNo, List<int> bytes) {
  _writeTag(out, fieldNo, 2);
  _writeVarint(out, bytes.length);
  out.add(bytes);
}

void _writeStringField(BytesBuilder out, int fieldNo, String text) =>
    _writeBytesField(out, fieldNo, utf8.encode(text));

void _writeVarintField(BytesBuilder out, int fieldNo, int value) {
  _writeTag(out, fieldNo, 0);
  _writeVarint(out, value);
}

void _writePackedUint32(BytesBuilder out, int fieldNo, List<int> values) {
  final sub = BytesBuilder();
  for (final v in values) {
    _writeVarint(sub, v);
  }
  _writeBytesField(out, fieldNo, sub.takeBytes());
}

Uint8List _mvtStringVal(String s) {
  final b = BytesBuilder();
  _writeStringField(b, 1, s);
  return b.takeBytes();
}

Uint8List _mvtUintVal(int v) {
  final b = BytesBuilder();
  _writeVarintField(b, 5, v);
  return b.takeBytes();
}

Uint8List _mvtSintVal(int v) {
  final b = BytesBuilder();
  _writeVarintField(b, 6, _zigzag(v));
  return b.takeBytes();
}

Uint8List _mvtBoolVal(bool v) {
  final b = BytesBuilder();
  _writeVarintField(b, 7, v ? 1 : 0);
  return b.takeBytes();
}

int _cmd(int id, int count) => (id & 0x7) | (count << 3);

/// MVT v2.1 の穴あきポリゴン＋線＋点を含むテストタイルを生成する
Uint8List _buildSampleMvtTile() {
  // Feature 1: 外環 (CW in Y-down: (512,512)->(3584,512)->(3584,3584)->(512,3584))
  //          + 内環＝穴 (CCW in Y-down: (1200,1200)->(1200,2000)->(2000,2000)->(2000,1200))
  final polyCmds = <int>[
    // Exterior ring (CW in screen Y-down)
    _cmd(1, 1), _zigzag(512), _zigzag(512), // MoveTo(512, 512)
    _cmd(2, 3),
    _zigzag(3072), _zigzag(0), // -> (3584, 512)
    _zigzag(0), _zigzag(3072), // -> (3584, 3584)
    _zigzag(-3072), _zigzag(0), // -> (512, 3584)
    _cmd(7, 1), // ClosePath
    // Interior hole ring (CCW in screen Y-down; cursor starts from (512, 3584))
    _cmd(1, 1), _zigzag(688), _zigzag(-2384), // MoveTo(1200, 1200)
    _cmd(2, 3),
    _zigzag(0), _zigzag(800), // -> (1200, 2000)
    _zigzag(800), _zigzag(0), // -> (2000, 2000)
    _zigzag(0), _zigzag(-800), // -> (2000, 1200)
    _cmd(7, 1), // ClosePath
  ];

  final fPoly = BytesBuilder();
  // 32bit を超える 53bit 安全範囲の ID: 2^40 + 42
  _writeVarintField(fPoly, 1, 1099511627818);
  _writePackedUint32(fPoly, 2, [
    0, 0, // 民国別: 国有林
    1, 1, // 林班: 0042
    2, 2, // 市町村コード5桁: 30427
    3, 3, // 森林計画区コード: 02
    4, 4, // big_uint: 1099511627776
    5, 5, // sint_offset: -42
    6, 6, // active: true
  ]);
  _writeVarintField(fPoly, 3, 3); // POLYGON
  _writePackedUint32(fPoly, 4, polyCmds);

  // Feature 2: 民有林ポリゴン (小区画: (100,100)->(400,100)->(400,400)->(100,400))
  final fPrivate = BytesBuilder();
  _writeVarintField(fPrivate, 1, 99);
  _writePackedUint32(fPrivate, 2, [
    0, 7, // 民国別: 民有林
    1, 8, // 林班: 0000
  ]);
  _writeVarintField(fPrivate, 3, 3);
  _writePackedUint32(fPrivate, 4, [
    _cmd(1, 1), _zigzag(100), _zigzag(100),
    _cmd(2, 3), _zigzag(300), _zigzag(0), _zigzag(0), _zigzag(300), _zigzag(-300), _zigzag(0),
    _cmd(7, 1),
  ]);

  // Feature 3: LineString
  final fLine = BytesBuilder();
  _writeVarintField(fLine, 1, 200);
  _writeVarintField(fLine, 3, 2); // LINESTRING
  _writePackedUint32(fLine, 4, [
    _cmd(1, 1), _zigzag(256), _zigzag(256),
    _cmd(2, 2), _zigzag(1024), _zigzag(512), _zigzag(512), _zigzag(-256),
  ]);

  // Feature 4: Point
  final fPoint = BytesBuilder();
  _writeVarintField(fPoint, 1, 300);
  _writeVarintField(fPoint, 3, 1); // POINT
  _writePackedUint32(fPoint, 4, [
    _cmd(1, 1), _zigzag(2048), _zigzag(2048),
  ]);

  // Layer 1: 森林計画対象森林レイヤ
  final layer1 = BytesBuilder();
  _writeStringField(layer1, 1, '森林計画対象森林レイヤ');
  _writeBytesField(layer1, 2, fPoly.takeBytes());
  _writeBytesField(layer1, 2, fPrivate.takeBytes());
  _writeBytesField(layer1, 2, fLine.takeBytes());
  _writeBytesField(layer1, 2, fPoint.takeBytes());
  for (final k in ['民国別', '林班', '市町村コード5桁', '森林計画区コード', 'big_uint', 'sint_offset', 'active']) {
    _writeStringField(layer1, 3, k);
  }
  _writeBytesField(layer1, 4, _mvtStringVal('国有林'));
  _writeBytesField(layer1, 4, _mvtStringVal('0042'));
  _writeBytesField(layer1, 4, _mvtStringVal('30427'));
  _writeBytesField(layer1, 4, _mvtStringVal('02'));
  _writeBytesField(layer1, 4, _mvtUintVal(1099511627776));
  _writeBytesField(layer1, 4, _mvtSintVal(-42));
  _writeBytesField(layer1, 4, _mvtBoolVal(true));
  _writeBytesField(layer1, 4, _mvtStringVal('民有林'));
  _writeBytesField(layer1, 4, _mvtStringVal('0000'));
  _writeVarintField(layer1, 5, 4096); // extent

  // Layer 2: 別レイヤ（sourceLayer フィルタで読み飛ばされることの確認用）
  final layer2 = BytesBuilder();
  _writeStringField(layer2, 1, 'ignored_layer');
  final fIgnored = BytesBuilder();
  _writeVarintField(fIgnored, 3, 1);
  _writePackedUint32(fIgnored, 4, [_cmd(1, 1), _zigzag(10), _zigzag(10)]);
  _writeBytesField(layer2, 2, fIgnored.takeBytes());
  _writeVarintField(layer2, 5, 4096);

  final tile = BytesBuilder();
  _writeBytesField(tile, 3, layer1.takeBytes());
  _writeBytesField(tile, 3, layer2.takeBytes());
  return tile.takeBytes();
}

/// PMTiles v3 ディレクトリを列指向 varint にシリアライズする
Uint8List _serializePmTilesDir(List<PmTilesEntry> entries) {
  final out = BytesBuilder();
  _writeVarint(out, entries.length);
  var lastId = 0;
  for (final e in entries) {
    _writeVarint(out, e.tileId - lastId);
    lastId = e.tileId;
  }
  for (final e in entries) {
    _writeVarint(out, e.runLength);
  }
  for (final e in entries) {
    _writeVarint(out, e.length);
  }
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (i > 0 && e.offset == entries[i - 1].offset + entries[i - 1].length) {
      _writeVarint(out, 0);
    } else {
      _writeVarint(out, e.offset + 1);
    }
  }
  return out.takeBytes();
}

void _putUint64LE(ByteData bd, int byteOffset, int value) {
  final lo = value % 4294967296;
  final hi = value ~/ 4294967296;
  bd.setUint32(byteOffset, lo, Endian.little);
  bd.setUint32(byteOffset + 4, hi, Endian.little);
}

/// 256×256 の単色 PNG タイルを生成する（`TileCacheMBTiles.isPlausibleTile` を満たす）
Uint8List _solidPng({int r = 40, int g = 120, int b = 200}) {
  final im = img.Image(width: 256, height: 256, numChannels: 4);
  for (var y = 0; y < 256; y++) {
    for (var x = 0; x < 256; x++) {
      // 単色すぎると極端に小さくなる場合に備え、微細なグラデーションを入れて実タイルに近いサイズにする
      im.setPixelRgba(x, y, (r + (x & 15)) & 255, (g + (y & 15)) & 255, b, 255);
    }
  }
  return img.encodePng(im, level: 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 北山村付近の z=14 タイル
  const sampleZ = 14;
  const sampleX = 14373;
  const sampleY = 6518;

  group('MvtDecoder', () {
    test('非圧縮および gzip 圧縮の MVT v2.1 を WGS84 地物（穴あき面・線・点・64bit 属性）へ復号する', () {
      final raw = _buildSampleMvtTile();
      final gz = const GZipEncoder().encodeBytes(raw);

      for (final payload in [raw, gz]) {
        final decoded = MvtDecoder.decode(
          payload,
          z: sampleZ,
          x: sampleX,
          y: sampleY,
          sourceLayer: '森林計画対象森林レイヤ',
        );
        expect(decoded.layers.keys, ['森林計画対象森林レイヤ']);
        final features = decoded.allFeatures('森林計画対象森林レイヤ');
        expect(features, hasLength(4));

        // 1) 穴あきポリゴン（外環 1 + 穴 1）と 53bit 整数・zigzag 負数属性
        final polyF = features[0];
        expect(polyF.id, 1099511627818);
        expect(polyF.properties['民国別'], '国有林');
        expect(polyF.properties['林班'], '0042');
        expect(polyF.properties['big_uint'], 1099511627776);
        expect(polyF.properties['sint_offset'], -42);
        expect(polyF.properties['active'], isTrue);

        final poly = polyF.geometry as geo.Polygon;
        expect(poly.rings, hasLength(2));
        final ext = poly.exterior!;
        expect(ext.positionCount, 5); // 閉じた四角形
        expect(poly.interior.single.positionCount, 5);

        // 投影後の経緯度がタイル矩形内に収まること
        final west = WebMercator.lonFromX(WebMercator.tileWest(sampleX, sampleZ));
        final east = WebMercator.lonFromX(WebMercator.tileWest(sampleX + 1, sampleZ));
        final north = WebMercator.latFromY(WebMercator.tileNorth(sampleY, sampleZ));
        final south = WebMercator.latFromY(WebMercator.tileNorth(sampleY + 1, sampleZ));
        for (var i = 0; i < ext.positionCount; i++) {
          expect(ext.x(i), inInclusiveRange(west, east));
          expect(ext.y(i), inInclusiveRange(south, north));
        }

        // 2) 線と点
        expect(features[2].geometry, isA<geo.LineString>());
        expect((features[2].geometry as geo.LineString).chain.positionCount, 3);
        expect(features[3].geometry, isA<geo.Point>());
      }
    });
  });

  group('PmTilesReader', () {
    test('Hilbert 曲線の zxyToTileId が PMTiles v3 仕様と一致し、ズーム内で全単射になる', () {
      expect(PmTilesReader.zxyToTileId(0, 0, 0), 0);
      expect(PmTilesReader.zxyToTileId(1, 0, 0), 1);
      expect(PmTilesReader.zxyToTileId(1, 0, 1), 2);
      expect(PmTilesReader.zxyToTileId(1, 1, 1), 3);
      expect(PmTilesReader.zxyToTileId(1, 1, 0), 4);

      // z=3 は累積 (1 + 4 + 16) = 21 から 84 までの 64 個すべてが一意に並ぶ
      final ids = <int>{};
      for (var x = 0; x < 8; x++) {
        for (var y = 0; y < 8; y++) {
          ids.add(PmTilesReader.zxyToTileId(3, x, y));
        }
      }
      expect(ids, hasLength(64));
      expect(ids.reduce(math.min), 21);
      expect(ids.reduce(math.max), 84);
    });

    test('127B ヘッダ・ルートディレクトリ・leaf ディレクトリを HTTP Range 相当で辿ってタイルを取り出す', () async {
      const gz = GZipEncoder();
      final mvtRaw = _buildSampleMvtTile();
      final mvtGz = gz.encodeBytes(mvtRaw);
      final targetTileId = PmTilesReader.zxyToTileId(sampleZ, sampleX, sampleY);

      // Leaf directory に実タイルエントリを置き、root directory からは runLength=0 で leaf を指す
      final leafRaw = _serializePmTilesDir([
        PmTilesEntry(tileId: targetTileId, offset: 0, length: mvtGz.length, runLength: 1),
      ]);
      final leafGz = gz.encodeBytes(leafRaw);

      final rootRaw = _serializePmTilesDir([
        PmTilesEntry(tileId: targetTileId - 10, offset: 0, length: leafGz.length, runLength: 0),
      ]);
      final rootGz = gz.encodeBytes(rootRaw);

      final header = Uint8List(127);
      const magic = [0x50, 0x4d, 0x54, 0x69, 0x6c, 0x65, 0x73, 0x03];
      header.setRange(0, magic.length, magic);
      final bd = ByteData.sublistView(header);
      const rootOffset = 127;
      final leafOffset = rootOffset + rootGz.length;
      final dataOffset = leafOffset + leafGz.length;
      _putUint64LE(bd, 8, rootOffset);
      _putUint64LE(bd, 16, rootGz.length);
      _putUint64LE(bd, 24, rootOffset); // metadata (unused)
      _putUint64LE(bd, 32, 0);
      _putUint64LE(bd, 40, leafOffset);
      _putUint64LE(bd, 48, leafGz.length);
      _putUint64LE(bd, 56, dataOffset);
      _putUint64LE(bd, 64, mvtGz.length);
      header[97] = 2; // internalCompression = gzip
      header[98] = 2; // tileCompression = gzip
      header[99] = 1; // MVT
      header[100] = 12; // minZoom
      header[101] = 16; // maxZoom

      final archive = BytesBuilder()
        ..add(header)
        ..add(rootGz)
        ..add(leafGz)
        ..add(mvtGz);
      final archiveBytes = archive.takeBytes();

      final requestedRanges = <(int, int)>[];
      final reader = PmTilesReader((offset, length) async {
        requestedRanges.add((offset, length));
        if (offset >= archiveBytes.length) return null;
        final end = math.min(offset + length, archiveBytes.length);
        return Uint8List.sublistView(archiveBytes, offset, end);
      });

      final fetched = await reader.getTile(sampleZ, sampleX, sampleY);
      expect(fetched, isNotNull);
      expect(fetched, equals(mvtRaw));

      // 2 回目は leaf キャッシュが効くため、ヘッダや leaf を再取得せずタイルデータ Range だけ読む
      final countAfterFirst = requestedRanges.length;
      final fetchedAgain = await reader.getTile(sampleZ, sampleX, sampleY);
      expect(fetchedAgain, equals(mvtRaw));
      expect(requestedRanges.length, countAfterFirst + 1);

      // ズーム範囲外および未収録タイルは null
      expect(await reader.getTile(8, 0, 0), isNull);
      expect(await reader.getTile(sampleZ, sampleX + 5, sampleY), isNull);
    });
  });

  group('CsReliefTiles', () {
    test('DEM 格子から 256×256 の CS立体図 PNG を生成し、尾根（暖色）と谷（寒色）を描き分ける', () {
      const cols = 64;
      const rows = 64;
      final heights = Float32List(cols * rows);
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          // 北側 (r ≈ 48) に東西方向の鋭い尾根（凸）、南側 (r ≈ 16) に深い谷（凹）を作る
          final ridge = 18.0 * math.exp(-math.pow((r - 48) / 2.5, 2));
          final valley = -18.0 * math.exp(-math.pow((r - 16) / 2.5, 2));
          heights[r * cols + c] = 300.0 + ridge + valley;
        }
      }

      final png = renderCsReliefTilePng(
        CsReliefTileArgs(
          heights: heights,
          cols: cols,
          rows: rows,
          cellSize: 2.0,
          col0: 4,
          row0: 4,
          cells: 56,
        ),
      );

      expect(TileCacheMBTiles.isPlausibleTile(png), isTrue);
      final decoded = img.decodePng(png);
      expect(decoded, isNotNull);
      expect(decoded!.width, 256);
      expect(decoded.height, 256);

      // row=48 は北寄り py ≈ (4 + 56 - 48.5) / (56/256) ≈ 52
      // row=16 は南寄り py ≈ (4 + 56 - 16.5) / (56/256) ≈ 199
      final ridgePx = decoded.getPixel(128, 52);
      final valleyPx = decoded.getPixel(128, 199);

      // 尾根は赤みが強く (R > B)、谷は青みが強い (B > R)
      expect(ridgePx.r, greaterThan(ridgePx.b + 40));
      expect(valleyPx.b, greaterThan(valleyPx.r + 30));
    });
  });

  group('BaseMapProvider & RegionalRasterSource', () {
    test('高精細航空写真カスケードは PLATEAU 404 時に地理院 seamlessphoto へフォールバックする', () async {
      final gsiPng = _solidPng(r: 30, g: 140, b: 60);
      final calledUrls = <String>[];
      final client = MockClient((req) async {
        calledUrls.add(req.url.toString());
        if (req.url.host.contains('plateauview.mlit.go.jp')) {
          return http.Response('', 404);
        }
        if (req.url.toString().contains('cyberjapandata.gsi.go.jp/xyz/seamlessphoto')) {
          return http.Response.bytes(gsiPng, 200);
        }
        return http.Response('', 404);
      });

      final res = await BaseMapService.fetchCascadedRasterTile(
        client,
        RegionalRasterSource.highResOrthoCascade,
        16,
        57492,
        26072,
      );
      expect(res.networkFailed, isFalse);
      expect(res.bytes, equals(gsiPng));
      expect(calledUrls, hasLength(3)); // PLATEAU 2024 -> PLATEAU 2023 -> GSI seamlessphoto

      // z=10（PLATEAU の minZoom=14 未満）では最初から地理院のみを叩く
      calledUrls.clear();
      final lowZoomRes = await BaseMapService.fetchCascadedRasterTile(
        client,
        RegionalRasterSource.highResOrthoCascade,
        10,
        898,
        407,
      );
      expect(lowZoomRes.bytes, equals(gsiPng));
      expect(calledUrls, hasLength(1));
      expect(calledUrls.single, contains('seamlessphoto/10/898/407.jpg'));
    });

    test('産総研シームレス地質図 V2 は z/y/x 順の URL を展開し、seamlessphoto 逆引きは gsi_photo を保つ', () {
      final gsj = BaseMapProvider.getProviderById('gsj_geology_v2')!;
      expect(gsj.maxZoom, 13);
      expect(gsj.tileUrl(13, 7186, 3259), 'https://gbank.gsj.jp/seamless/v2/api/1.3.1/tiles/13/3259/7186.png');

      final cs = BaseMapProvider.getProviderById('cs_relief')!;
      expect(cs.cacheId, 'cs_relief_v${CsReliefTiles.version}');

      final foundGsi = BaseMapProvider.findByTileUrl(
        'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg',
      );
      expect(foundGsi?.id, 'gsi_photo');
    });
  });

  group('OfficialLayerService & OfficialFeatureNode', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('System ツリー同期で Global フォルダを保ったまま公式レイヤを追加・非表示・削除できる', () async {
      final svc = OfficialLayerService.forTesting();
      final root = FolderNode('root');
      final sys = SysNode.ensureIn(root);
      final global = GlobalFolderNode('Global', globalPath: '/virtual/global', parent: sys);
      sys.children.add(global);

      await svc.addLayer('rinya_forest_plan', root: root);
      await svc.addLayer('gsj_seamless_geology', root: root);

      expect(sys.children.first, same(global));
      final officialNodes = sys.children.whereType<OfficialLayerNode>().toList();
      expect(officialNodes.map((n) => n.spec.id), ['rinya_forest_plan', 'gsj_seamless_geology']);
      expect(svc.visibleNodesIn(root), hasLength(2));

      // 個別レイヤを非表示にすると visibleNodesIn から外れ、SharedPreferences にも残る
      await officialNodes.first.persistVisibility();
      await svc.setLayerVisibility('rinya_forest_plan', false);
      await svc.syncToTree(root);
      expect(svc.visibleNodesIn(root).map((n) => n.spec.id), ['gsj_seamless_geology']);

      // 別インスタンスで設定を再読込しても復元される
      final reloaded = OfficialLayerService.forTesting();
      await reloaded.ensureInitialized();
      expect(reloaded.enabledIds, ['rinya_forest_plan', 'gsj_seamless_geology']);
      expect(reloaded.isLayerVisible('rinya_forest_plan'), isFalse);
      expect(reloaded.isLayerVisible('gsj_seamless_geology'), isTrue);

      // レイヤ削除
      await svc.removeLayer('rinya_forest_plan', root: root);
      expect(sys.children.whereType<OfficialLayerNode>().map((n) => n.spec.id), ['gsj_seamless_geology']);
    });

    test('林班 MVT の取得・国有林/民有林スタイル付与・z17 オーバーズーム・タップ当たり判定・地質図 API 照会', () async {
      final mvtGz = const GZipEncoder().encodeBytes(_buildSampleMvtTile());
      var gsjApiCalls = 0;

      final client = MockClient((req) async {
        final url = req.url.toString();
        if (url.contains('rinya-tiles.geospatial.jp/fr_layer_pbf_2025/$sampleZ/$sampleX/$sampleY.pbf')) {
          return http.Response.bytes(mvtGz, 200);
        }
        // z=16 用（z=17 の featuresForTileSync が z=16 へクランプすることの検証）
        if (url.contains('rinya-tiles.geospatial.jp/fr_layer_pbf_2025/16/${sampleX * 4}/${sampleY * 4}.pbf')) {
          return http.Response.bytes(mvtGz, 200);
        }
        if (url.contains('gbank.gsj.jp/seamless/v2/api/1.3.1/legend.json')) {
          gsjApiCalls++;
          return http.Response.bytes(
            utf8.encode(json.encode({
              'symbol': 'K2m',
              'formationAge_ja': '後期白亜紀',
              'group_ja': '四万十累層群',
              'lithology_ja': '砂岩頁岩互層',
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('', 404);
      });

      final svc = OfficialLayerService.forTesting(client: client);
      final root = FolderNode('root');
      await svc.addLayer('rinya_forest_plan', root: root);
      await svc.addLayer('gsj_seamless_geology', root: root);

      final features = await svc.ensureVectorTile(
        OfficialLayerSpec.rinyaForestPlan,
        sampleZ,
        sampleX,
        sampleY,
      );
      expect(features, isNotNull);
      expect(features, hasLength(4));

      // 国有林 "0042" -> style='rinya_national', label='国42'
      expect(features![0].properties[kOfficialStyleKeyProp], 'rinya_national');
      expect(features[0].properties[kOfficialLabelProp], '国42');
      // 民有林 "0000" -> style='rinya_private', label='0'
      expect(features[1].properties[kOfficialStyleKeyProp], 'rinya_private');
      expect(features[1].properties[kOfficialLabelProp], '0');

      // z=17 で要求しても maxZoom=16 にクランプされて取得・返却される
      await svc.ensureVectorTile(OfficialLayerSpec.rinyaForestPlan, 16, sampleX * 4, sampleY * 4);
      final overzoomed = svc.featuresForTileSync(
        OfficialLayerSpec.rinyaForestPlan,
        17,
        sampleX * 8 + 1,
        sampleY * 8 + 1,
      );
      expect(overzoomed, hasLength(4));

      // 外環の内側かつ穴の外側にある点 (MVT 座標 (2600, 2600) 付近 = タイル内の南東側) をタップ
      final westM = WebMercator.tileWest(sampleX, sampleZ);
      final northM = WebMercator.tileNorth(sampleY, sampleZ);
      final spanM = WebMercator.tileSpan(sampleZ);
      final tapLon = WebMercator.lonFromX(westM + spanM * (2600.0 / 4096.0));
      final tapLat = WebMercator.latFromY(northM - spanM * (2600.0 / 4096.0));
      final tap = LatLng(tapLat, tapLon);

      final hits = svc.hitTest(tap, root, zoom: 14.5);
      // 林班ポリゴン 1 件 + 地質図地点照会 1 件
      expect(hits, hasLength(2));
      final rinyaHit = hits.firstWhere((h) => h.spec.id == 'rinya_forest_plan');
      expect(rinyaHit.title, '国有林 林班 0042');
      expect(rinyaHit.attributes['民国別'], '国有林');
      expect(rinyaHit.attributes['林班'], '0042');
      expect(rinyaHit.attributes.containsKey(kOfficialStyleKeyProp), isFalse);
      expect(rinyaHit.silhouetteParts, isNotEmpty);

      // 同じ区画を再タップしたときの OfficialFeatureNode 同値判定（サイクル選択用）
      final secondHits = svc.hitTest(tap, root, zoom: 14.5);
      expect(secondHits.first, equals(rinyaHit));

      // 穴の内部 (MVT 座標 (1600, 1600)) をタップしたときは外環ポリゴンに当たらない
      final holeLon = WebMercator.lonFromX(westM + spanM * (1600.0 / 4096.0));
      final holeLat = WebMercator.latFromY(northM - spanM * (1600.0 / 4096.0));
      final holeHits = svc.hitTest(LatLng(holeLat, holeLon), root, zoom: 14.5);
      expect(holeHits.where((h) => h.spec.id == 'rinya_forest_plan'), isEmpty);

      // 地質図の遅延属性ローダを実行すると GSJ V2 JSON が整形され、2 回目はキャッシュから返る
      final gsjHit = hits.firstWhere((h) => h.spec.id == 'gsj_seamless_geology');
      expect(gsjHit.lazyAttributesLoader, isNotNull);
      final loaded = await gsjHit.lazyAttributesLoader!();
      expect(loaded, isNotNull);
      expect(loaded!.values, containsAll(['K2m', '後期白亜紀', '四万十累層群', '砂岩頁岩互層']));
      expect(gsjApiCalls, 1);

      final cachedAttrs = await svc.queryPointApi(OfficialLayerSpec.gsjSeamlessGeology, tap);
      expect(cachedAttrs, equals(loaded));
      expect(gsjApiCalls, 1);
    });
  });
}
