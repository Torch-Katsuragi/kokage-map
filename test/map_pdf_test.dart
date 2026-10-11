// 地図の PDF 出力: 縮尺記号・縮尺・タイルの段・凡例・PDF の組み立て
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/qgis_renderer.dart';
import 'package:root_maps/services/map_pdf/map_pdf_layout.dart';
import 'package:root_maps/services/map_pdf/map_pdf_legend.dart';
import 'package:root_maps/services/map_pdf/map_pdf_renderer.dart';

const _strings = MapPdfStrings(legend: '凡例', notes: '備考', scale: '縮尺', source: '出典', more: _more);
String _more(int n) => 'ほか $n 件';

void main() {
  group('縮尺記号', () {
    for (final lat in [0.0, 34.0, 35.7, 45.0, 60.0]) {
      for (final denominator in [1000.0, 5000.0, 25000.0, 200000.0]) {
        test('緯度 $lat・1:$denominator で、紙 1 mm が地上の分母/1000 m（測地線）', () {
          final merc = MapPdfScale.mercatorMetersPerMm(denominator, lat);
          final spec = MapPdfScale.scaleBar(center: LatLng(lat, 136.0), mercatorMetersPerMm: merc, maxLengthMm: 50);
          // 球の Mercator の倍率と楕円体（Vincenty）の差は 0.7% 未満
          expect(spec.groundMetersPerMm, closeTo(denominator / 1000, denominator / 1000 * 0.007));
          expect(spec.lengthMm, lessThanOrEqualTo(50 + 1e-9));
          expect(spec.lengthMm, greaterThan(50 / 5 - 1e-9)); // 1・2・5 刻みなので 1/5 以上は残る
          expect(spec.lengthMm * spec.groundMetersPerMm, closeTo(spec.meters, 1e-6));
          final lead = spec.meters / math.pow(10, (math.log(spec.meters) / math.ln10 + 1e-9).floor());
          expect([1, 2, 5], contains(lead.round()));
        });
      }
    }

    test('1 km 以上は km で書く', () {
      expect(const ScaleBarSpec(meters: 2000, lengthMm: 40, groundMetersPerMm: 50).label, '2 km');
      expect(const ScaleBarSpec(meters: 500, lengthMm: 40, groundMetersPerMm: 12.5).label, '500 m');
    });

    test('ズームを 1 段上げると同じ画面の縮尺の分母はほぼ半分', () {
      double d(double zoom) => MapPdfScale.fitDenominator(
            viewport: const Size(1080, 2000),
            zoom: zoom,
            latDeg: 34,
            frameMm: const Size(190, 230),
          );
      expect(d(14) / d(15), inInclusiveRange(1.5, 2.67));
      expect(d(16), lessThan(d(15)));
    });
  });

  group('縮尺', () {
    test('切りのよい分母に丸める（小さくはしない）', () {
      expect(MapPdfScale.niceDenominator(4321), 5000);
      expect(MapPdfScale.niceDenominator(5000), 5000);
      expect(MapPdfScale.niceDenominator(2100), 2500);
      expect(MapPdfScale.niceDenominator(9000), 10000);
      expect(MapPdfScale.niceDenominator(13000), 15000);
    });

    test('画面の範囲が地図枠に収まる', () {
      const viewport = Size(1080, 2000);
      const frame = Size(190, 230);
      const lat = 33.9;
      const zoom = 15.3;
      final d = MapPdfScale.fitDenominator(viewport: viewport, zoom: zoom, latDeg: lat, frameMm: frame);
      final groundPerPx = WebMercator.metersPerPixel(0) / math.pow(2, zoom) * math.cos(lat * math.pi / 180);
      expect(frame.width * d / 1000, greaterThanOrEqualTo(viewport.width * groundPerPx - 1e-6));
      expect(frame.height * d / 1000, greaterThanOrEqualTo(viewport.height * groundPerPx - 1e-6));
    });
  });

  group('タイルの段', () {
    test('紙の 1 px にタイルの 1 px が届く段で、回した枠を覆う', () {
      final cx = WebMercator.xFromLon(136.0);
      final cy = WebMercator.yFromLat(34.0);
      const frame = Size(2000, 1500);
      final pxPerM = 1 / WebMercator.metersPerPixel(16) * 0.9; // z16 の 1 px より少し粗い紙
      final r = MapPdfScale.tilesFor(
        centerX: cx,
        centerY: cy,
        framePx: frame,
        pxPerMercatorMeter: pxPerM,
        bearingRad: math.pi / 6,
        maxZoom: 18,
        maxTilesAcross: 64,
      );
      expect(r.z, 16);
      // 枠の四隅（回したもの）がタイルの範囲に入る
      for (final corner in [const Offset(-1, -1), const Offset(1, -1), const Offset(1, 1), const Offset(-1, 1)]) {
        final dx = corner.dx * frame.width / 2, dy = corner.dy * frame.height / 2;
        const b = math.pi / 6;
        // 紙 → Mercator（toPage の逆: 紙の回転を戻す）
        final mx = (dx * math.cos(b) - dy * math.sin(b)) / pxPerM;
        final my = -(dx * math.sin(b) + dy * math.cos(b)) / pxPerM;
        final tx = WebMercator.tileXAt(cx + mx, r.z);
        final ty = WebMercator.tileYAt(cy + my, r.z);
        expect(tx, inInclusiveRange(r.x0, r.x1));
        expect(ty, inInclusiveRange(r.y0, r.y1));
      }
    });

    test('大きすぎれば段を下げ、最大ズームを超えない', () {
      final r = MapPdfScale.tilesFor(
        centerX: 0,
        centerY: 0,
        framePx: const Size(3300, 2300),
        pxPerMercatorMeter: 1 / WebMercator.metersPerPixel(20),
        bearingRad: math.pi / 4,
        maxZoom: 18,
      );
      expect(r.z, lessThanOrEqualTo(18));
      expect(r.width, lessThanOrEqualTo(16));
      expect(r.height, lessThanOrEqualTo(16));
    });

    test('方位 90°: 東が紙の上', () {
      final p = MapPdfScale.toPage(
        x: 100,
        y: 0,
        centerX: 0,
        centerY: 0,
        pxPerMercatorMeter: 1,
        bearingRad: math.pi / 2,
        frameCenter: Offset.zero,
      );
      expect(p.dx, closeTo(0, 1e-9));
      expect(p.dy, closeTo(-100, 1e-9));
    });
  });

  group('凡例', () {
    final resolver = (
      point: (KMetaLayerStyle? s) => s?.pointColor ?? const Color(0xFFFF0000),
      pointSize: (KMetaLayerStyle? s) => s?.pointSize ?? 6.0,
      line: (KMetaLayerStyle? s) => s?.lineColor ?? const Color(0xFF0000FF),
      lineWidth: (KMetaLayerStyle? s) => s?.lineWidth ?? 3.0,
      fill: (KMetaLayerStyle? s) => s?.polygonFillColor ?? const Color(0xFF00FF00),
      fillOpacity: (KMetaLayerStyle? s) => s?.polygonFillOpacity ?? 0.4,
      border: (KMetaLayerStyle? s) => s?.polygonBorderColor ?? const Color(0xFF008000),
      borderOpacity: (KMetaLayerStyle? s) => s?.polygonBorderOpacity ?? 1.0,
    );

    test('単一シンボルは 1 行で、種類ごとの見本（色はレイヤ → 既定）', () {
      final items = buildMapPdfLegend([
        const MapPdfLegendLayer(name: '標柱', geometry: GeometryType.point),
        const MapPdfLegendLayer(
            name: '作業道', geometry: GeometryType.linestring, style: KMetaLayerStyle(lineColor: Color(0xFF795548))),
        const MapPdfLegendLayer(name: '林班', geometry: GeometryType.polygon),
      ], resolver: resolver);
      expect(items.map((i) => i.label), ['標柱', '作業道', '林班']);
      expect(items[0].swatch!.pointColor, const Color(0xFFFF0000));
      expect(items[0].swatch!.lineColor, isNull);
      expect(items[1].swatch!.lineColor, const Color(0xFF795548));
      expect(items[2].swatch!.polygonFillColor, const Color(0xFF00FF00));
      expect(items[2].swatch!.polygonFillOpacity, 0.4);
      expect(items.every((i) => i.depth == 0), isTrue);
    });

    test('QGIS の描き分け: 見出しの下に描く項目だけ（チェックを外した項目は出さない）', () {
      final renderer = QgisRenderer(kind: QgisRendererKind.categorized, attr: '樹種', classes: const [
        QgisRendererClass(label: 'スギ', values: ['スギ'], style: KMetaLayerStyle(polygonFillColor: Color(0xFF2E7D32))),
        QgisRendererClass(label: 'ヒノキ', values: ['ヒノキ'], style: KMetaLayerStyle(polygonFillColor: Color(0xFF8BC34A))),
        QgisRendererClass(label: '', values: [], render: false),
      ]);
      final items = buildMapPdfLegend([
        MapPdfLegendLayer(
          name: '小班',
          geometry: GeometryType.polygon,
          style: KMetaLayerStyle(qgisRenderer: 'categorizedSymbol', qgisRendererDef: renderer, polygonFillOpacity: 0.6),
        ),
      ], resolver: resolver);
      expect(items.map((i) => i.label), ['小班', 'スギ', 'ヒノキ']);
      expect(items[0].swatch, isNull); // 見出し
      expect(items[1].depth, 1);
      expect(items[1].swatch!.polygonFillColor, const Color(0xFF2E7D32));
      expect(items[1].swatch!.polygonFillOpacity, 0.6); // 項目に無い値はレイヤのもの
      expect(items[2].swatch!.polygonFillColor, const Color(0xFF8BC34A));
    });

    test('View があればレイヤの見出しの下に View ごと', () {
      final items = buildMapPdfLegend([
        const MapPdfLegendLayer(name: '作業道', geometry: GeometryType.linestring, views: [
          (name: '既設', style: KMetaLayerStyle(lineColor: Color(0xFF000000))),
          (name: '計画', style: KMetaLayerStyle(lineColor: Color(0xFFFF9800))),
        ]),
      ], resolver: resolver);
      expect(items.map((i) => (i.label, i.depth)), [('作業道', 0), ('既設', 1), ('計画', 1)]);
      expect(items[2].swatch!.lineColor, const Color(0xFFFF9800));
    });
  });

  group('ラベル', () {
    test('面は頂点の平均、線は長さの中点、点はそのまま。k-label の無いものは拾わない', () {
      final labels = collectMapPdfLabels(
        polygons: [
          geo.Feature(
            geometry: geo.Polygon.build(const [
              [136.0, 34.0, 136.002, 34.0, 136.002, 34.002, 136.0, 34.002],
            ]),
            properties: const {'k-label': '12-い'},
          ),
          geo.Feature(geometry: geo.Polygon.build(const [
            [136.0, 34.0, 136.1, 34.0, 136.1, 34.1],
          ])),
        ],
        polylines: [
          geo.Feature(
            geometry: geo.LineString.build(const [136.0, 34.0, 136.01, 34.0, 136.03, 34.0]),
            properties: const {'k-label': '林道'},
          ),
        ],
        markers: [
          geo.Feature(geometry: geo.Point.build(const [136.5, 34.5]), properties: const {'k-label': '標柱1'}),
        ],
      );
      expect(labels.map((l) => l.text), ['12-い', '林道', '標柱1']);
      expect(labels[0].x, closeTo(WebMercator.xFromLon(136.001), 0.01));
      expect(labels[1].x, closeTo(WebMercator.xFromLon(136.015), 0.01));
      expect(labels[2].besideMarker, isTrue);
    });
  });

  group('PDF', () {
    MapPdfRequest request({required MapPdfPaper paper, required bool landscape, String notes = ''}) => MapPdfRequest(
          paper: paper,
          landscape: landscape,
          title: '北山村 12 林班 施業図',
          notes: notes,
          date: DateTime(2026, 10, 11),
          center: const LatLng(33.93, 135.97),
          zoom: 15,
          bearingDeg: 30,
          viewport: const Size(1080, 1800),
          strings: _strings,
          legend: const [
            MapPdfLegendItem(label: '林班', swatch: KMetaLayerStyle(polygonFillColor: Color(0xFF2E7D32), polygonFillOpacity: 0.3)),
            MapPdfLegendItem(label: '作業道', swatch: KMetaLayerStyle(lineColor: Color(0xFF795548), lineWidth: 3)),
          ],
          attributions: const ['国土地理院'],
          labels: const [MapPdfLabel(x: 0, y: 0, text: 'x')],
        );

    /// 背景地図の代わり: タイルの範囲と同じ大きさの単色の絵（呼ばれた範囲を覚える）
    Future<ui.Image> fakeSnapshot(TileRange range, double strokeScale, TileProgress? onProgress, List<TileRange> calls) async {
      calls.add(range);
      onProgress?.call(1, 1);
      final rec = ui.PictureRecorder();
      final w = range.width * 256, h = range.height * 256;
      ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const Color(0xFFCCE0CC));
      final pic = rec.endRecording();
      final im = await pic.toImage(w, h);
      pic.dispose();
      return im;
    }

    for (final (paper, landscape) in [(MapPdfPaper.a4, true), (MapPdfPaper.a4, false), (MapPdfPaper.a3, true)]) {
      test('${paper.name} ${landscape ? '横' : '縦'}: ページの大きさ・表題・画像 1 枚', () async {
        final calls = <TileRange>[];
        final progress = <double>[];
        // テストは 50 dpi（200 dpi だと A3 で 1 枚 30MB を作る）
        final bytes = await renderMapPdf(
          request(paper: paper, landscape: landscape, notes: '現地説明用。\n2026-10-15 9:00 集合'),
          (r, s, p) => fakeSnapshot(r, s, p, calls),
          dpi: 50,
          onProgress: progress.add,
        );
        expect(bytes, isNotEmpty);
        final text = latin1.decode(bytes);
        expect(text.startsWith('%PDF-'), isTrue);
        expect(calls, hasLength(1));
        expect(progress, isNotEmpty);
        // MediaBox は mm × 72 / 25.4 pt
        final size = paper.sizeMm(landscape: landscape);
        final box = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]').firstMatch(text);
        expect(box, isNotNull, reason: 'MediaBox が無い');
        expect(double.parse(box!.group(1)!), closeTo(size.width * 72 / 25.4, 0.5));
        expect(double.parse(box.group(2)!), closeTo(size.height * 72 / 25.4, 0.5));
        // 表題は文書情報に入る（UTF-16BE の 16 進。紙面の文字は画像なので本文からは取れない）
        expect(text, contains('/Title'));
        expect(_pdfStrings(text, '/Title'), contains('北山村 12 林班 施業図'));
        expect(RegExp(r'/Subtype\s*/Image').allMatches(text), hasLength(1));
        final dims = RegExp(r'/Width\s+(\d+)').firstMatch(text)!;
        expect(int.parse(dims.group(1)!), (size.width * 50 / 25.4).round());
      });
    }

    test('紙面の画像: 余白は白、地図枠の中は地図', () async {
      final calls = <TileRange>[];
      final image = await renderMapPdfPage(
        request(paper: MapPdfPaper.a4, landscape: true),
        (r, s, p) => fakeSnapshot(r, s, p, calls),
        dpi: 50,
      );
      final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int px(int x, int y) => data.getUint32((y * image.width + x) * 4);
      expect(px(2, 2), 0xFFFFFFFF); // 左上の余白（RGBA）
      final layout = MapPdfLayout.compute(MapPdfPaper.a4, landscape: true, withPanel: true);
      final mid = layout.map.center * (50 / 25.4);
      // 地図の真ん中あたり（ラベル・記号の無いところ）は地図の色
      final x = (layout.map.left * 50 / 25.4 + 40).round();
      final y = mid.dy.round();
      expect(px(x, y), 0xCCE0CCFF);
      image.dispose();
    });
  });
}

/// 文書情報の文字列（`/Key (...)` か `/Key <FEFF...>`）を読む
String _pdfStrings(String pdf, String key) {
  final hex = RegExp('${RegExp.escape(key)}\\s*<([0-9A-Fa-f]+)>').firstMatch(pdf);
  if (hex != null) {
    final h = hex.group(1)!;
    final units = <int>[];
    for (var i = 0; i + 3 < h.length; i += 4) {
      units.add(int.parse(h.substring(i, i + 4), radix: 16));
    }
    if (units.isNotEmpty && units.first == 0xFEFF) units.removeAt(0);
    return String.fromCharCodes(units);
  }
  // 文字列リテラル: 括弧の入れ子とバックスラッシュのエスケープを解く
  final start = pdf.indexOf(key);
  if (start < 0) return '';
  var i = pdf.indexOf('(', start);
  if (i < 0) return '';
  final raw = <int>[];
  var depth = 0;
  for (i++; i < pdf.length; i++) {
    final c = pdf.codeUnitAt(i);
    if (c == 0x5C) {
      i++;
      final e = pdf[i];
      const simple = {'n': 10, 'r': 13, 't': 9, 'b': 8, 'f': 12, '(': 40, ')': 41, r'\': 92};
      if (simple.containsKey(e)) {
        raw.add(simple[e]!);
      } else if (RegExp('[0-7]').hasMatch(e)) {
        var oct = e;
        while (oct.length < 3 && RegExp('[0-7]').hasMatch(pdf[i + 1])) {
          oct += pdf[++i];
        }
        raw.add(int.parse(oct, radix: 8));
      }
      continue;
    }
    if (c == 0x28) depth++;
    if (c == 0x29) {
      if (depth == 0) break;
      depth--;
    }
    raw.add(c);
  }
  if (raw.length >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) {
    return String.fromCharCodes([for (var k = 2; k + 1 < raw.length; k += 2) (raw[k] << 8) | raw[k + 1]]);
  }
  return String.fromCharCodes(raw);
}
