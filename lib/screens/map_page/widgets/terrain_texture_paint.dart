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
// こかげマップ: 地形のテクスチャへの上描き（地物・選んだ面の塗り・オーバーレイ画像）。
// 真上からの投影で、座標はテクスチャの範囲の左上を原点とするピクセル
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../../core/terrain/dem_tiles.dart';
import '../../../core/terrain/terrain_scene.dart';
import '../../../core/terrain/web_mercator.dart';

/// テクスチャ 1 枚の範囲（[TileRange]）と、緯度経度 → テクスチャのピクセルの換算
class TextureFrame {
  TextureFrame(this.range)
      : west = range.west,
        north = WebMercator.tileNorth(range.y0, range.z),
        pxPerM = range.width * WebMercator.tileSize / range.widthMeters;

  final TileRange range;
  final double west;
  final double north;
  final double pxPerM;

  /// 範囲の Mercator の矩形（地物のふるい分け用）
  Rect get mercator =>
      Rect.fromLTRB(west, north - range.height * WebMercator.tileSpan(range.z), west + range.widthMeters, north);

  /// テクスチャ全体のピクセルの矩形
  Rect get pixels => Rect.fromLTWH(
        0,
        0,
        range.width * WebMercator.tileSize * 1.0,
        range.height * WebMercator.tileSize * 1.0,
      );

  Offset at(double lon, double lat) =>
      Offset((WebMercator.xFromLon(lon) - west) * pxPerM, (north - WebMercator.yFromLat(lat)) * pxPerM);

  Offset ofPosition(geo.Position p) => at(p.x, p.y);

  /// 面のリング（穴を含む）を 1 本の Path に（evenOdd）
  ui.Path polygonPath(geo.Geometry? g) {
    final path = ui.Path()..fillType = ui.PathFillType.evenOdd;
    for (final rings in TerrainSceneBuilder.ringsOf(g)) {
      for (final ring in rings) {
        _addPolyline(path, ring.positions);
        path.close();
      }
    }
    return path;
  }

  /// 線（多重線は部分ごと）を 1 本の Path に
  ui.Path linePath(geo.Geometry? g) {
    final path = ui.Path();
    for (final chain in TerrainSceneBuilder.chainsOf(g)) {
      _addPolyline(path, chain.positions);
    }
    return path;
  }

  void _addPolyline(ui.Path path, Iterable<geo.Position> positions) {
    var first = true;
    for (final p in positions) {
      final o = ofPosition(p);
      if (first) {
        path.moveTo(o.dx, o.dy);
        first = false;
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
  }
}

/// テクスチャに重ねる 1 歩（[composeTextureDraws]）
sealed class TextureDrawStep {
  const TextureDrawStep();
}

/// オーバーレイ画像 [overlay]（渡した一覧の番号）を描く
final class OverlayDraw extends TextureDrawStep {
  const OverlayDraw(this.overlay);
  final int overlay;

  @override
  bool operator ==(Object other) => other is OverlayDraw && other.overlay == overlay;
  @override
  int get hashCode => overlay.hashCode;
  @override
  String toString() => 'OverlayDraw($overlay)';
}

/// 面の塗りの一続き（渡した一覧の [from] から [to] の手前まで）を描く
final class FillRun extends TextureDrawStep {
  const FillRun(this.from, this.to);
  final int from;
  final int to;

  @override
  bool operator ==(Object other) => other is FillRun && other.from == from && other.to == to;
  @override
  int get hashCode => Object.hash(from, to);
  @override
  String toString() => 'FillRun($from, $to)';
}

/// 面の塗りとオーバーレイ画像を描く順（下から）に混ぜる。
///
/// [fillRanks] は描く面それぞれの段（下から積む順に並んでいる前提。レイヤの並びで、大きいほど手前）、
/// [overlayRanks] はオーバーレイ画像それぞれの段。段の小さいものから描き、同じ段ならオーバーレイが先
/// （QGIS のレイヤ一覧で、上にあるものほど手前に描くのと同じ）。
/// 線・点・枠線・ラベルはこの後（いつも一番上）。[[qgis-interop#レイヤの並びと描く順（2026-10-13）]]
List<TextureDrawStep> composeTextureDraws({required List<int> fillRanks, required List<int> overlayRanks}) {
  final overlays = [for (var i = 0; i < overlayRanks.length; i++) i]
    ..sort((a, b) {
      final c = overlayRanks[a].compareTo(overlayRanks[b]);
      return c != 0 ? c : a.compareTo(b);
    });
  final out = <TextureDrawStep>[];
  var o = 0;
  var runStart = 0;
  for (var i = 0; i < fillRanks.length; i++) {
    if (o < overlays.length && overlayRanks[overlays[o]] <= fillRanks[i]) {
      if (i > runStart) out.add(FillRun(runStart, i));
      runStart = i;
      while (o < overlays.length && overlayRanks[overlays[o]] <= fillRanks[i]) {
        out.add(OverlayDraw(overlays[o++]));
      }
    }
  }
  if (fillRanks.length > runStart) out.add(FillRun(runStart, fillRanks.length));
  while (o < overlays.length) {
    out.add(OverlayDraw(overlays[o++]));
  }
  return out;
}

/// 面の塗りだけを描く（[indexes] は [polygons] の番号。並んだ順に描く）
void paintPolygonFills(
  ui.Canvas canvas,
  TextureFrame frame, {
  required List<geo.Feature<geo.Geometry>> polygons,
  required Iterable<int> indexes,
  required TerrainFeatureStyle Function(geo.Feature f) styleOf,
}) {
  final fill = Paint()..style = PaintingStyle.fill;
  for (final i in indexes) {
    final f = polygons[i];
    final st = styleOf(f);
    if (st.fillColor.a > 0) canvas.drawPath(frame.polygonPath(f.geometry), fill..color = st.fillColor);
  }
}

/// 地物をテクスチャに描き、描いた件数を返す。[fillsOnly] なら面の塗りだけ、[fills] が false なら塗り以外
/// （枠線・線・点。塗りはオーバーレイ画像と混ぜて先に描いてある: [composeTextureDraws]）。
///
/// 太さは画面で見える太さに合わせる。テクスチャは表示の段とほぼ同じ段で作るので、テクスチャの 1 px ≒ 画面の 1 px。
/// [indexesIn] は範囲に掛かる地物の番号（範囲の索引で先にふるう）
int paintFeatures(
  ui.Canvas canvas,
  TextureFrame frame, {
  required List<geo.Feature<geo.Geometry>> polygons,
  required List<geo.Feature<geo.Geometry>> polylines,
  required List<geo.Feature<geo.Point>> markers,
  required List<int> Function(List<geo.Feature<geo.Geometry>> fs, Rect clip) indexesIn,
  required TerrainFeatureStyle Function(geo.Feature f) styleOf,
  bool fillsOnly = false,
  bool fills = true,
}) {
  final merc = frame.mercator;
  final fill = Paint()..style = PaintingStyle.fill;
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  var n = 0;
  for (final i in indexesIn(polygons, merc)) {
    final f = polygons[i];
    final st = styleOf(f);
    final outline = !fillsOnly && st.outlineColor.a > 0 && st.outlineWidth > 0;
    final filled = fills && st.fillColor.a > 0;
    if (filled || outline) {
      final path = frame.polygonPath(f.geometry);
      if (filled) canvas.drawPath(path, fill..color = st.fillColor);
      if (outline) canvas.drawPath(path, stroke..color = st.outlineColor..strokeWidth = math.max(1.0, st.outlineWidth));
    }
    n++;
  }
  if (fillsOnly) return n;
  for (final i in indexesIn(polylines, merc)) {
    final f = polylines[i];
    final st = styleOf(f);
    canvas.drawPath(frame.linePath(f.geometry), stroke..color = st.lineColor..strokeWidth = math.max(1.5, st.lineWidth));
    n++;
  }
  for (final f in markers) {
    final pos = f.geometry?.position;
    if (pos == null) continue;
    final x = WebMercator.xFromLon(pos.x);
    final y = WebMercator.yFromLat(pos.y);
    if (x < merc.left || x > merc.right || y < merc.top || y > merc.bottom) continue;
    final st = styleOf(f);
    canvas.drawCircle(frame.ofPosition(pos), math.max(2.0, st.pointSize), fill..color = st.pointColor);
    n++;
  }
  return n;
}

/// 選んだ面の塗り
void paintSelectionFill(
  ui.Canvas canvas,
  TextureFrame frame, {
  required List<geo.Feature<geo.Geometry>> selected,
  required List<int> Function(List<geo.Feature<geo.Geometry>> fs, Rect clip) indexesIn,
  required Color color,
}) {
  if (selected.isEmpty) return;
  final fill = Paint()
    ..style = PaintingStyle.fill
    ..color = color;
  for (final i in indexesIn(selected, frame.mercator)) {
    canvas.drawPath(frame.polygonPath(selected[i].geometry), fill);
  }
}

/// オーバーレイ画像（四隅 TL, TR, BR, BL の緯度経度 → テクスチャのピクセルへのアフィン変換）
void paintOverlayImage(ui.Canvas canvas, TextureFrame frame, ui.Image image, List<LatLng> corners) {
  final tl = frame.at(corners[0].longitude, corners[0].latitude);
  final tr = frame.at(corners[1].longitude, corners[1].latitude);
  final br = frame.at(corners[2].longitude, corners[2].latitude);
  final bl = frame.at(corners[3].longitude, corners[3].latitude);
  final bbox = Rect.fromPoints(tl, br).expandToInclude(Rect.fromPoints(tr, bl));
  if (!bbox.overlaps(frame.pixels)) return;
  final w = image.width.toDouble();
  final h = image.height.toDouble();
  // 画像ピクセル (u, v) → tl + u/w (tr − tl) + v/h (bl − tl)
  final m = Float64List.fromList([
    (tr.dx - tl.dx) / w, (tr.dy - tl.dy) / w, 0, 0,
    (bl.dx - tl.dx) / h, (bl.dy - tl.dy) / h, 0, 0,
    0, 0, 1, 0,
    tl.dx, tl.dy, 0, 1,
  ]);
  canvas.save();
  canvas.transform(m);
  canvas.drawImage(image, Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.medium);
  canvas.restore();
}
