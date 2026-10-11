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
// こかげマップ: 地図の PDF 出力（1 ページ）。
//
// 紙面は dart:ui の Canvas に 200 dpi で描き、1 枚の画像として PDF に入れる。
// 文字も画面と同じ文字の描き方（端末のフォント）で描くので、日本語のフォントを同梱しなくてよい
// （pdf パッケージは TrueType しか埋め込めず、Noto Sans JP を同梱すると APK が数 MB 増える）。
// その代わり PDF の文字は選択・検索できない。設計は docs/features/map-pdf.md
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:pdf/pdf.dart';

import '../../core/terrain/dem_tiles.dart';
import '../../core/terrain/terrain_scene.dart';
import '../../core/terrain/web_mercator.dart';
import '../../widgets/qgis_renderer_legend.dart';
import 'map_pdf_layout.dart';
import 'map_pdf_legend.dart';

/// 地図に載せるラベル（Mercator m の位置）
class MapPdfLabel {
  const MapPdfLabel({required this.x, required this.y, required this.text, this.besideMarker = false});
  final double x;
  final double y;
  final String text;

  /// 点の右に置く（面・線は真ん中）
  final bool besideMarker;
}

/// 紙面の文言（i18n は呼び出し側）
class MapPdfStrings {
  const MapPdfStrings({
    required this.legend,
    required this.notes,
    required this.scale,
    required this.source,
    required this.more,
  });

  /// 「凡例」
  final String legend;

  /// 「備考」
  final String notes;

  /// 「縮尺」
  final String scale;

  /// 「出典」
  final String source;

  /// 「ほか N 件」
  final String Function(int n) more;
}

/// 出力の指定と、地図から集めた材料
class MapPdfRequest {
  const MapPdfRequest({
    required this.paper,
    required this.landscape,
    required this.title,
    required this.date,
    required this.center,
    required this.zoom,
    required this.bearingDeg,
    required this.viewport,
    required this.strings,
    this.notes = '',
    this.legend = const [],
    this.attributions = const [],
    this.labels = const [],
    this.labelFontSize = 12,
    this.labelColor = const Color(0xFF000000),
    this.maxZoom = 18,
    this.locale,
  });

  final MapPdfPaper paper;
  final bool landscape;
  final String title;
  final String notes;
  final DateTime date;

  /// 画面の地図の中心・ズーム・方位（度、北が 0 で時計回り）。傾きは見ない（PDF は真上から）
  final LatLng center;
  final double zoom;
  final double bearingDeg;

  /// 画面の地図の大きさ（論理 px）。紙の地図枠にこの範囲が収まる縮尺にする
  final Size viewport;

  final List<MapPdfLegendItem> legend;

  /// 見えている背景地図の出典（地理院タイルは出典の明示が利用条件）
  final List<String> attributions;

  final List<MapPdfLabel> labels;

  /// ラベルの文字の大きさ（画面の論理 px）と色
  final double labelFontSize;
  final Color labelColor;

  /// 背景地図を取りに行く一番細かい段（見えている層の最大ズームのうち一番大きいもの）
  final int maxZoom;

  final MapPdfStrings strings;
  final Locale? locale;
}

/// 真上からの地図の絵（[MapSurface.snapshotTopDown]）
typedef MapPdfSnapshot = Future<ui.Image> Function(TileRange range, double strokeScale, TileProgress? onProgress);

/// 画面の 1 論理 px を紙の何 mm にするか（線の太さ・点・ラベル）。画面の見た目より少し太め
const double kMapPdfMmPerDp = 0.2;

/// 地図の PDF を作る（1 ページ）。[onProgress] は背景地図のタイルの読み込み（0〜1）
Future<Uint8List> renderMapPdf(
  MapPdfRequest req,
  MapPdfSnapshot snapshot, {
  double dpi = kMapPdfDpi,
  void Function(double progress)? onProgress,
}) async {
  final page = await renderMapPdfPage(req, snapshot, dpi: dpi, onProgress: onProgress);
  try {
    final bytes = await page.toByteData(format: ui.ImageByteFormat.rawRgba);
    return await encodeMapPdf(
      rgba: bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      width: page.width,
      height: page.height,
      pageMm: req.paper.sizeMm(landscape: req.landscape),
      title: req.title,
    );
  } finally {
    page.dispose();
  }
}

/// 紙面の画像を PDF の 1 ページにする（[rgba] は不透明な紙面）
Future<Uint8List> encodeMapPdf({
  required Uint8List rgba,
  required int width,
  required int height,
  required Size pageMm,
  required String title,
}) async {
  final doc = PdfDocument();
  PdfInfo(doc, title: title, creator: 'こかげマップ', producer: 'こかげマップ'); // 作るだけで文書情報に入る
  final n = width * height;
  final rgb = Uint8List(n * 3);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    rgb[i * 3] = rgba[j];
    rgb[i * 3 + 1] = rgba[j + 1];
    rgb[i * 3 + 2] = rgba[j + 2];
  }
  final image = PdfImage(doc, image: rgb, width: width, height: height, alpha: false);
  final format = PdfPageFormat(pageMm.width * PdfPageFormat.mm, pageMm.height * PdfPageFormat.mm);
  final p = PdfPage(doc, pageFormat: format);
  p.getGraphics().drawImage(image, 0, 0, format.width, format.height);
  return doc.save();
}

/// 紙面を 1 枚の画像に描く（[dpi] の解像度）
Future<ui.Image> renderMapPdfPage(
  MapPdfRequest req,
  MapPdfSnapshot snapshot, {
  double dpi = kMapPdfDpi,
  void Function(double progress)? onProgress,
}) async {
  final pxPerMm = dpi / 25.4;
  final hasPanel = req.legend.isNotEmpty || req.notes.trim().isNotEmpty;
  final layout = MapPdfLayout.compute(req.paper, landscape: req.landscape, withPanel: hasPanel);
  Rect px(Rect mm) => Rect.fromLTRB(mm.left * pxPerMm, mm.top * pxPerMm, mm.right * pxPerMm, mm.bottom * pxPerMm);
  final pageW = (layout.page.width * pxPerMm).round();
  final pageH = (layout.page.height * pxPerMm).round();
  final frame = px(layout.map);

  // 縮尺: 画面の範囲が地図枠に収まる切りのよい値
  final lat = req.center.latitude;
  final denominator = MapPdfScale.fitDenominator(viewport: req.viewport, zoom: req.zoom, latDeg: lat, frameMm: layout.map.size);
  final mercPerMm = MapPdfScale.mercatorMetersPerMm(denominator, lat);
  final pxPerM = pxPerMm / mercPerMm;
  final cx = WebMercator.xFromLon(req.center.longitude);
  final cy = WebMercator.yFromLat(lat);
  final bearing = req.bearingDeg * math.pi / 180;
  final dp = kMapPdfMmPerDp * pxPerMm; // 画面の 1 論理 px → 紙の px

  // 地図の絵（真上から、北が上）
  final range = MapPdfScale.tilesFor(
    centerX: cx,
    centerY: cy,
    framePx: frame.size,
    pxPerMercatorMeter: pxPerM,
    bearingRad: bearing,
    maxZoom: req.maxZoom,
  );
  final texPxPerM = WebMercator.tileSize / WebMercator.tileSpan(range.z);
  final map = await snapshot(
    range,
    dp * texPxPerM / pxPerM,
    onProgress == null ? null : (done, total) => onProgress(total == 0 ? 1 : done / total),
  );

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, pageW.toDouble(), pageH.toDouble()), Paint()..color = const Color(0xFFFFFFFF));

  // 地図
  canvas.save();
  canvas.clipRect(frame);
  canvas.translate(frame.center.dx, frame.center.dy);
  canvas.rotate(-bearing);
  final k = pxPerM / texPxPerM;
  canvas.scale(k);
  final texWest = WebMercator.tileWest(range.x0, range.z);
  final texNorth = WebMercator.tileNorth(range.y0, range.z);
  canvas.translate(-(cx - texWest) * texPxPerM, -(texNorth - cy) * texPxPerM);
  canvas.drawImage(map, Offset.zero, Paint()..filterQuality = FilterQuality.medium);
  canvas.restore();
  map.dispose();

  final painter = _PagePainter(canvas, pxPerMm, req.locale);

  // ラベル（向きは紙に合わせて立てる）
  canvas.save();
  canvas.clipRect(frame);
  _paintLabels(painter, req, frame, (x, y) => MapPdfScale.toPage(
        x: x,
        y: y,
        centerX: cx,
        centerY: cy,
        pxPerMercatorMeter: pxPerM,
        bearingRad: bearing,
        frameCenter: frame.center,
      ), dp);
  canvas.restore();

  // 地図枠
  canvas.drawRect(frame, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.3 * pxPerMm
    ..color = const Color(0xFF000000));

  _paintNorthArrow(painter, frame, bearing);
  _paintScaleBar(painter, req, frame, denominator, mercPerMm);
  _paintAttribution(painter, req, frame);
  _paintHeader(painter, req, px(layout.header));
  final panel = layout.panel;
  if (panel != null) _paintPanel(painter, req, px(panel), landscape: req.landscape);

  final picture = recorder.endRecording();
  try {
    return await picture.toImage(pageW, pageH);
  } finally {
    picture.dispose();
  }
}

/// 地図に流している GeoJSON からラベルを集める（`k-label`。面は頂点の平均、線は長さの中点、点は右）
List<MapPdfLabel> collectMapPdfLabels({
  required List<geo.Feature<geo.Geometry>> polygons,
  required List<geo.Feature<geo.Geometry>> polylines,
  required List<geo.Feature<geo.Point>> markers,
  String labelProp = 'k-label',
}) {
  final out = <MapPdfLabel>[];
  String? textOf(geo.Feature f) => switch (f.properties[labelProp]) {
        final String s when s.isNotEmpty => s,
        _ => null,
      };
  Offset merc(geo.Position p) => Offset(WebMercator.xFromLon(p.x), WebMercator.yFromLat(p.y));
  for (final f in polygons) {
    final text = textOf(f);
    if (text == null) continue;
    for (final rings in TerrainSceneBuilder.ringsOf(f.geometry)) {
      if (rings.isEmpty) continue;
      final pts = [for (final p in rings.first.positions) merc(p)];
      if (pts.isEmpty) continue;
      var sx = 0.0, sy = 0.0;
      for (final p in pts) {
        sx += p.dx;
        sy += p.dy;
      }
      out.add(MapPdfLabel(x: sx / pts.length, y: sy / pts.length, text: text));
    }
  }
  for (final f in polylines) {
    final text = textOf(f);
    if (text == null) continue;
    for (final chain in TerrainSceneBuilder.chainsOf(f.geometry)) {
      final pts = [for (final p in chain.positions) merc(p)];
      if (pts.length < 2) continue;
      final m = _midpointAlong(pts);
      out.add(MapPdfLabel(x: m.dx, y: m.dy, text: text));
    }
  }
  for (final f in markers) {
    final text = textOf(f);
    final pos = f.geometry?.position;
    if (text == null || pos == null) continue;
    final p = merc(pos);
    out.add(MapPdfLabel(x: p.dx, y: p.dy, text: text, besideMarker: true));
  }
  return out;
}

Offset _midpointAlong(List<Offset> pts) {
  var total = 0.0;
  for (var i = 0; i + 1 < pts.length; i++) {
    total += (pts[i + 1] - pts[i]).distance;
  }
  var remain = total / 2;
  for (var i = 0; i + 1 < pts.length; i++) {
    final d = (pts[i + 1] - pts[i]).distance;
    if (remain <= d) return d == 0 ? pts[i] : pts[i] + (pts[i + 1] - pts[i]) * (remain / d);
    remain -= d;
  }
  return pts.last;
}

/// 紙面に文字や図形を描く道具（寸法は mm）
class _PagePainter {
  _PagePainter(this.canvas, this.pxPerMm, this.locale);
  final Canvas canvas;
  final double pxPerMm;
  final Locale? locale;

  double mm(double v) => v * pxPerMm;

  TextPainter text(
    String s, {
    required double sizeMm,
    Color color = const Color(0xFF000000),
    bool bold = false,
    double? maxWidth,
    int? maxLines = 1,
    TextAlign align = TextAlign.left,
  }) =>
      TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontSize: sizeMm * pxPerMm,
            color: color,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            locale: locale,
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: align,
        maxLines: maxLines,
        ellipsis: maxLines == null ? null : '…',
        locale: locale,
      )..layout(maxWidth: maxWidth ?? double.infinity);

  /// 白地の箱（地図の上に載せるもの）
  void box(Rect r) {
    canvas.drawRect(r, Paint()..color = const Color(0xE6FFFFFF));
    canvas.drawRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = mm(0.15)
      ..color = const Color(0xFF606060));
  }
}

void _paintLabels(
  _PagePainter p,
  MapPdfRequest req,
  Rect frame,
  Offset Function(double x, double y) toPage,
  double dp,
) {
  if (req.labels.isEmpty) return;
  final sizeMm = req.labelFontSize * kMapPdfMmPerDp;
  final placed = <Rect>[];
  const maxLabels = 3000;
  for (final l in req.labels) {
    if (placed.length >= maxLabels) break;
    final at = toPage(l.x, l.y);
    if (!frame.inflate(p.mm(10)).contains(at)) continue;
    final tp = p.text(l.text, sizeMm: sizeMm, color: req.labelColor, maxWidth: p.mm(60));
    final origin = l.besideMarker
        ? at + Offset(dp * 6, -tp.height / 2)
        : at - Offset(tp.width / 2, tp.height / 2);
    final rect = origin & tp.size;
    if (!frame.overlaps(rect)) continue;
    // 重なるものは先勝ちで間引く（地図と同じ）
    if (placed.any((r) => r.overlaps(rect))) continue;
    placed.add(rect);
    // 縁取り（白）
    final halo = TextPainter(
      text: TextSpan(
        text: l.text,
        style: TextStyle(
          fontSize: sizeMm * p.pxPerMm,
          height: 1.2,
          locale: p.locale,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = p.mm(0.5)
            ..strokeJoin = StrokeJoin.round
            ..color = const Color(0xFFFFFFFF),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: p.mm(60));
    halo.paint(p.canvas, origin);
    tp.paint(p.canvas, origin);
  }
}

/// 方位記号（真北。Web Mercator の経線は紙の上で縦なので、地図の方位だけ回せば真北になる）
void _paintNorthArrow(_PagePainter p, Rect frame, double bearing) {
  final r = p.mm(7);
  final c = Offset(frame.right - p.mm(10), frame.top + p.mm(10));
  p.canvas.drawCircle(c, r, Paint()..color = const Color(0xE6FFFFFF));
  p.canvas.save();
  p.canvas.translate(c.dx, c.dy);
  p.canvas.rotate(-bearing);
  final tip = Offset(0, -p.mm(4.2));
  final left = Offset(-p.mm(2.2), p.mm(3.5));
  final right = Offset(p.mm(2.2), p.mm(3.5));
  final notch = Offset(0, p.mm(2));
  final black = Paint()..color = const Color(0xFF000000);
  final outline = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = p.mm(0.25)
    ..strokeJoin = StrokeJoin.round
    ..color = const Color(0xFF000000);
  p.canvas.drawPath(Path()..addPolygon([tip, left, notch], true), black);
  p.canvas.drawPath(Path()..addPolygon([tip, left, notch, right], true), outline);
  final n = p.text('N', sizeMm: 3, bold: true);
  n.paint(p.canvas, Offset(-n.width / 2, tip.dy - n.height + p.mm(0.3)));
  p.canvas.restore();
}

void _paintScaleBar(_PagePainter p, MapPdfRequest req, Rect frame, double denominator, double mercPerMm) {
  final maxMm = math.min(frame.width / p.pxPerMm * 0.3, 60.0);
  final spec = MapPdfScale.scaleBar(center: req.center, mercatorMetersPerMm: mercPerMm, maxLengthMm: maxMm);
  final barW = p.mm(spec.lengthMm);
  final barH = p.mm(1.2);
  final title = p.text('${req.strings.scale} 1:${_groupDigits(denominator.round())}', sizeMm: 2.6);
  final zero = p.text('0', sizeMm: 2.2);
  final end = p.text(spec.label, sizeMm: 2.2);
  final pad = p.mm(1.5);
  final w = math.max(title.width, barW + end.width / 2 + zero.width / 2) + 2 * pad;
  final h = title.height + p.mm(1) + barH + p.mm(0.5) + end.height + 2 * pad;
  final box = Rect.fromLTWH(frame.left + p.mm(3), frame.bottom - p.mm(3) - h, w, h);
  p.box(box);
  title.paint(p.canvas, box.topLeft + Offset(pad, pad));
  final barLeft = box.left + pad + zero.width / 2;
  final barTop = box.top + pad + title.height + p.mm(1);
  // 4 等分の白黒
  const segs = 4;
  for (var i = 0; i < segs; i++) {
    final r = Rect.fromLTWH(barLeft + barW * i / segs, barTop, barW / segs, barH);
    p.canvas.drawRect(r, Paint()..color = i.isEven ? const Color(0xFF000000) : const Color(0xFFFFFFFF));
  }
  p.canvas.drawRect(Rect.fromLTWH(barLeft, barTop, barW, barH), Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = p.mm(0.2)
    ..color = const Color(0xFF000000));
  final ty = barTop + barH + p.mm(0.5);
  zero.paint(p.canvas, Offset(barLeft - zero.width / 2, ty));
  end.paint(p.canvas, Offset(barLeft + barW - end.width / 2, ty));
}

void _paintAttribution(_PagePainter p, MapPdfRequest req, Rect frame) {
  final names = {for (final a in req.attributions) if (a.trim().isNotEmpty) a.trim()};
  if (names.isEmpty) return;
  final tp = p.text('${req.strings.source}: ${names.join(' / ')}', sizeMm: 2.2, maxWidth: frame.width * 0.6, maxLines: 2);
  final pad = p.mm(1);
  final box = Rect.fromLTWH(frame.right - p.mm(2) - tp.width - 2 * pad, frame.bottom - p.mm(2) - tp.height - 2 * pad,
      tp.width + 2 * pad, tp.height + 2 * pad);
  p.canvas.drawRect(box, Paint()..color = const Color(0xD9FFFFFF));
  tp.paint(p.canvas, box.topLeft + Offset(pad, pad));
}

void _paintHeader(_PagePainter p, MapPdfRequest req, Rect header) {
  final d = req.date;
  final date = p.text(
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
    sizeMm: 3.2,
  );
  final title = p.text(req.title, sizeMm: 6, bold: true, maxWidth: header.width - date.width - p.mm(6));
  title.paint(p.canvas, Offset(header.left, header.top + (header.height - title.height) / 2 - p.mm(1)));
  date.paint(p.canvas, Offset(header.right - date.width, header.bottom - date.height - p.mm(1.5)));
  p.canvas.drawLine(
    Offset(header.left, header.bottom),
    Offset(header.right, header.bottom),
    Paint()
      ..strokeWidth = p.mm(0.3)
      ..color = const Color(0xFF000000),
  );
}

/// 凡例と備考の欄。横長は右の縦長の欄（凡例の下に備考）、縦長は下の横長の欄（凡例を段組み、右に備考）
void _paintPanel(_PagePainter p, MapPdfRequest req, Rect panel, {required bool landscape}) {
  p.canvas.drawRect(panel, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = p.mm(0.2)
    ..color = const Color(0xFF808080));
  final inner = panel.deflate(p.mm(2.5));
  final notes = req.notes.trim();
  Rect legendArea = inner;
  if (notes.isNotEmpty) {
    final Rect notesArea;
    if (landscape) {
      final body = p.text(notes, sizeMm: 2.8, maxWidth: inner.width, maxLines: null);
      final head = p.text(req.strings.notes, sizeMm: 3.2, bold: true);
      final h = math.min(head.height + p.mm(1) + body.height, req.legend.isEmpty ? inner.height : inner.height * 0.45);
      notesArea = Rect.fromLTRB(inner.left, inner.bottom - h, inner.right, inner.bottom);
      legendArea = Rect.fromLTRB(inner.left, inner.top, inner.right, notesArea.top - p.mm(3));
    } else {
      final w = req.legend.isEmpty ? inner.width : inner.width * 0.38;
      notesArea = Rect.fromLTRB(inner.right - w, inner.top, inner.right, inner.bottom);
      legendArea = Rect.fromLTRB(inner.left, inner.top, notesArea.left - p.mm(4), inner.bottom);
    }
    _paintNotes(p, req, notesArea, notes);
  }
  if (req.legend.isNotEmpty) _paintLegend(p, req, legendArea, columns: !landscape);
}

void _paintNotes(_PagePainter p, MapPdfRequest req, Rect area, String notes) {
  final head = p.text(req.strings.notes, sizeMm: 3.2, bold: true);
  head.paint(p.canvas, area.topLeft);
  final lineH = p.text('あ', sizeMm: 2.8).height;
  final maxLines = math.max(1, ((area.height - head.height - p.mm(1)) / lineH).floor());
  final body = p.text(notes, sizeMm: 2.8, maxWidth: area.width, maxLines: maxLines);
  body.paint(p.canvas, area.topLeft + Offset(0, head.height + p.mm(1)));
}

void _paintLegend(_PagePainter p, MapPdfRequest req, Rect area, {required bool columns}) {
  final head = p.text(req.strings.legend, sizeMm: 3.2, bold: true);
  head.paint(p.canvas, area.topLeft);
  final top = area.top + head.height + p.mm(1.5);
  final rowH = p.mm(5);
  // 段組み（縦向きの下の欄）: 1 段 52 mm 以上で詰める
  final cols = columns ? math.max(1, (area.width / p.mm(52)).floor()) : 1;
  final colW = area.width / cols;
  final rowsPerCol = math.max(1, ((area.bottom - top) / rowH).floor());
  final capacity = rowsPerCol * cols;
  final items = req.legend;
  final overflow = items.length > capacity;
  final shown = overflow ? capacity - 1 : items.length;
  final swW = p.mm(6);
  final swH = p.mm(3.6);
  for (var i = 0; i < shown; i++) {
    final it = items[i];
    final col = i ~/ rowsPerCol;
    final row = i % rowsPerCol;
    final x0 = area.left + col * colW + it.depth * p.mm(3);
    final y0 = top + row * rowH;
    final textLeft = x0 + (it.swatch == null ? 0 : swW + p.mm(1.5));
    final tp = p.text(it.label, sizeMm: 2.8, bold: it.swatch == null, maxWidth: math.max(p.mm(5), area.left + (col + 1) * colW - textLeft - p.mm(2)));
    if (it.swatch != null) {
      // アプリの凡例と同じ色見本（高さ 16 論理 px の見本を拡大して描く。太さ・点の大きさは論理 px）
      final s = swH / 16;
      p.canvas.save();
      p.canvas.translate(x0, y0 + (rowH - swH) / 2);
      p.canvas.scale(s);
      QgisSwatchPainter(it.swatch).paint(p.canvas, Size(swW / s, 16));
      p.canvas.restore();
    }
    tp.paint(p.canvas, Offset(textLeft, y0 + (rowH - tp.height) / 2));
  }
  if (overflow) {
    final i = shown;
    final more = p.text(req.strings.more(items.length - shown), sizeMm: 2.6, color: const Color(0xFF606060));
    more.paint(p.canvas, Offset(area.left + (i ~/ rowsPerCol) * colW, top + (i % rowsPerCol) * rowH + (rowH - more.height) / 2));
  }
}

String _groupDigits(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
