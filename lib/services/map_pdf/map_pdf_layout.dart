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
// こかげマップ: 地図の PDF 出力の紙面の割り付け・縮尺・縮尺記号・タイルの段（純粋な計算）
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:latlong2/latlong.dart';

import '../../core/terrain/dem_tiles.dart';
import '../../core/terrain/web_mercator.dart';

/// 用紙
enum MapPdfPaper {
  a4(210, 297),
  a3(297, 420);

  const MapPdfPaper(this.shortMm, this.longMm);
  final double shortMm;
  final double longMm;

  Size sizeMm({required bool landscape}) => landscape ? Size(longMm, shortMm) : Size(shortMm, longMm);
}

/// 出力の解像度（印刷に足りる 200 dpi。A3 横で 3307 × 2339 px）
const double kMapPdfDpi = 200;

/// 紙面の割り付け（単位 mm、左上原点）
class MapPdfLayout {
  const MapPdfLayout({required this.page, required this.header, required this.map, this.panel});

  final Size page;

  /// 表題と日付の帯
  final Rect header;

  /// 地図の枠
  final Rect map;

  /// 凡例と備考の欄（横長は右、縦長は下）。無ければ地図が広がる
  final Rect? panel;

  static const margin = 10.0;
  static const headerHeight = 14.0;
  static const gap = 4.0;

  factory MapPdfLayout.compute(MapPdfPaper paper, {required bool landscape, required bool withPanel}) {
    final page = paper.sizeMm(landscape: landscape);
    final header = Rect.fromLTWH(margin, margin, page.width - 2 * margin, headerHeight);
    final body = Rect.fromLTRB(margin, header.bottom + gap, page.width - margin, page.height - margin);
    if (!withPanel) return MapPdfLayout(page: page, header: header, map: body);
    if (landscape) {
      final w = (page.width * 0.19).roundToDouble();
      return MapPdfLayout(
        page: page,
        header: header,
        map: Rect.fromLTRB(body.left, body.top, body.right - w - gap, body.bottom),
        panel: Rect.fromLTRB(body.right - w, body.top, body.right, body.bottom),
      );
    }
    final h = (page.height * 0.16).roundToDouble();
    return MapPdfLayout(
      page: page,
      header: header,
      map: Rect.fromLTRB(body.left, body.top, body.right, body.bottom - h - gap),
      panel: Rect.fromLTRB(body.left, body.bottom - h, body.right, body.bottom),
    );
  }
}

/// 縮尺記号（バー）の長さと目盛り
class ScaleBarSpec {
  const ScaleBarSpec({required this.meters, required this.lengthMm, required this.groundMetersPerMm});

  /// バーが表す地上の距離（m）
  final double meters;

  /// 紙の上の長さ（mm）
  final double lengthMm;

  /// 紙 1 mm あたりの地上の距離（m）。測地線で測ったもの
  final double groundMetersPerMm;

  String get label => meters >= 1000 ? '${_trim(meters / 1000)} km' : '${_trim(meters)} m';

  static String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

/// 縮尺・縮尺記号・タイルの段の計算
class MapPdfScale {
  MapPdfScale._();

  /// 分母の候補（1 桁ぶん。10 のべき乗を掛けて使う）
  static const _niceSteps = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0];

  /// [denominator] 以上で一番小さい切りのよい分母（1:2,500・1:5,000 など）
  static double niceDenominator(double denominator) {
    if (denominator <= 0 || !denominator.isFinite) return 1000;
    final p = math.pow(10, (math.log(denominator) / math.ln10 + 1e-9).floor()).toDouble();
    for (final s in _niceSteps) {
      if (s * p >= denominator * (1 - 1e-9)) return s * p;
    }
    return 10 * p;
  }

  /// 画面に見えている範囲（[viewport] 論理 px、ズーム [zoom]）が地図枠 [frameMm] に収まる縮尺の分母（中心の緯度で）。
  /// 切りのよい値に丸める（1:5,000 などの方が書類に書きやすい）
  static double fitDenominator({
    required Size viewport,
    required double zoom,
    required double latDeg,
    required Size frameMm,
  }) {
    final groundPerPx = WebMercator.metersPerPixel(0) / math.pow(2, zoom) * math.cos(latDeg * math.pi / 180);
    final metersPerMm = math.max(viewport.width * groundPerPx / frameMm.width, viewport.height * groundPerPx / frameMm.height);
    return niceDenominator(metersPerMm * 1000);
  }

  /// 縮尺の分母 → 紙 1 mm あたりの Mercator の m（Mercator は緯度 φ で 1/cos φ 倍に伸びる）
  static double mercatorMetersPerMm(double denominator, double latDeg) =>
      denominator / 1000 / math.cos(latDeg * math.pi / 180);

  /// 縮尺記号: [center] を通る東西の線で、紙の [maxLengthMm] ぶんの地上の距離を測地線（Vincenty）で測り、
  /// その中に収まる切りのよい距離（1・2・5 × 10^k m）のバーにする
  static ScaleBarSpec scaleBar({
    required LatLng center,
    required double mercatorMetersPerMm,
    required double maxLengthMm,
  }) {
    final cx = WebMercator.xFromLon(center.longitude);
    final half = maxLengthMm / 2 * mercatorMetersPerMm;
    final west = LatLng(center.latitude, WebMercator.lonFromX(cx - half));
    final east = LatLng(center.latitude, WebMercator.lonFromX(cx + half));
    final ground = const Distance().as(LengthUnit.Meter, west, east);
    final perMm = ground / maxLengthMm;
    final max = ground;
    final p = math.pow(10, (math.log(max) / math.ln10 + 1e-9).floor()).toDouble();
    var meters = p;
    for (final s in const [5.0, 2.0, 1.0]) {
      if (s * p <= max) {
        meters = s * p;
        break;
      }
    }
    return ScaleBarSpec(meters: meters, lengthMm: meters / perMm, groundMetersPerMm: perMm);
  }

  /// 地図枠を覆うタイルの段と範囲。
  ///
  /// 紙の 1 px（[pxPerMercatorMeter]）にタイルの 1 px が届く段を選び（[maxZoom] まで）、方位 [bearingRad] で回した枠の外接矩形を覆う。
  /// 一辺 [maxTilesAcross] 枚を超えるなら段を下げる（合成する絵が大きすぎるとメモリ・GPU のテクスチャの上限に掛かる）
  static TileRange tilesFor({
    required double centerX,
    required double centerY,
    required Size framePx,
    required double pxPerMercatorMeter,
    required double bearingRad,
    required int maxZoom,
    int minZoom = 0,
    int maxTilesAcross = 16,
  }) {
    // 回した枠の外接矩形（Mercator m）
    final c = math.cos(bearingRad).abs();
    final s = math.sin(bearingRad).abs();
    final w = (framePx.width * c + framePx.height * s) / pxPerMercatorMeter;
    final h = (framePx.width * s + framePx.height * c) / pxPerMercatorMeter;
    // 紙の 1 px ≦ タイルの 1 px になる段
    final ideal = (math.log(pxPerMercatorMeter * WebMercator.metersPerPixel(0)) / math.ln2 - 0.2).ceil();
    var z = ideal.clamp(minZoom, maxZoom);
    while (true) {
      final x0 = WebMercator.tileXAt(centerX - w / 2, z);
      final x1 = WebMercator.tileXAt(centerX + w / 2, z);
      final y0 = WebMercator.tileYAt(centerY + h / 2, z);
      final y1 = WebMercator.tileYAt(centerY - h / 2, z);
      final n = (1 << z) - 1;
      final range = TileRange(z: z, x0: x0.clamp(0, n), y0: y0.clamp(0, n), x1: x1.clamp(0, n), y1: y1.clamp(0, n));
      if (z <= minZoom || (range.width <= maxTilesAcross && range.height <= maxTilesAcross)) return range;
      z--;
    }
  }

  /// Mercator の点 → 紙の上の px（[frameCenter] が地図の中心。方位 [bearingRad] の向きが上）
  static Offset toPage({
    required double x,
    required double y,
    required double centerX,
    required double centerY,
    required double pxPerMercatorMeter,
    required double bearingRad,
    required Offset frameCenter,
  }) {
    final dx = (x - centerX) * pxPerMercatorMeter;
    final dy = -(y - centerY) * pxPerMercatorMeter; // 紙は下向きが +
    final c = math.cos(-bearingRad);
    final s = math.sin(-bearingRad);
    return frameCenter + Offset(dx * c - dy * s, dx * s + dy * c);
  }
}
