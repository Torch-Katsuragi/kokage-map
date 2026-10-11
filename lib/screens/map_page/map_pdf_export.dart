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
// こかげマップ: 「地図を PDF に」の材料集め（地図ページ → services/map_pdf）
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/terrain/dem_tiles.dart';
import '../../core/terrain/web_mercator.dart';
import '../../i18n/strings.g.dart';
import '../../interfaces/map_surface.dart';
import '../../models/app_notification.dart';
import '../../models/basemap_provider.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../providers/notification_providers.dart';
import '../../services/basemap_service.dart';
import '../../services/map_pdf/map_pdf_layout.dart';
import '../../services/map_pdf/map_pdf_legend.dart';
import '../../services/map_pdf/map_pdf_renderer.dart';
import '../../widgets/map_pdf_dialog.dart';
import '../layer_style_settings_screen.dart';
import 'feature_geojson_cache.dart';

/// 見えている背景地図の出典（地理院タイルは出典の明示が利用条件。等高線は標高タイルから作るので標高タイルの出典）
List<String> mapPdfAttributions(BaseMapService baseMaps) => [
      for (final (p, _) in baseMaps.activeLayers)
        if (p.type == BaseMapType.generated)
          for (final d in DemTileSource.defaultCascade) d.attribution
        else
          p.attribution.isNotEmpty ? p.attribution : p.name,
    ];

/// 凡例に出すレイヤ: 見えている地物の親のうち、[center] から [radiusM]（Mercator m）の正方形に地物が掛かるもの。並びは点 → 線 → 面
List<LayerNode> mapPdfLegendLayers(Iterable<FeatureNode> features, LatLng center, double radiusM) {
  final cx = WebMercator.xFromLon(center.longitude);
  final cy = WebMercator.yFromLat(center.latitude);
  final west = WebMercator.lonFromX(cx - radiusM), east = WebMercator.lonFromX(cx + radiusM);
  final south = WebMercator.latFromY(cy - radiusM), north = WebMercator.latFromY(cy + radiusM);
  bool hits(Iterable<LatLng> pts) {
    var minLat = double.infinity, maxLat = -double.infinity, minLon = double.infinity, maxLon = -double.infinity;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    return minLat <= north && maxLat >= south && minLon <= east && maxLon >= west;
  }

  final out = <LayerNode>{};
  for (final f in features) {
    final layer = f.parent;
    if (out.contains(layer)) continue;
    final pts = switch (f) {
      PointFeatureNode() => [f.point],
      LineFeatureNode() => f.line,
      PolygonFeatureNode() => f.polygon.isEmpty ? const <LatLng>[] : f.polygon.first,
      _ => const <LatLng>[],
    };
    if (pts.isNotEmpty && hits(pts)) out.add(layer);
  }
  int rank(LayerNode l) => switch (l) {
        PointLayerNode() => 0,
        LineLayerNode() => 1,
        _ => 2,
      };
  return out.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
}

/// ≡ メニュー →「地図を PDF に」
Future<void> openMapPdfExport(
  BuildContext context, {
  required MapSurface? projection,
  required KMapCamera camera,
  required FeatureGeoJsonCache geoJson,
  required BaseMapService baseMaps,
  required List<FeatureNode> features,
  required String defaultTitle,
  required NotificationCenter notify,
}) async {
  final proj = projection;
  if (proj == null || proj.viewportSize.isEmpty) {
    notify.add(title: t.mapPdf.notReady, level: NotificationLevel.warning);
    return;
  }
  final locale = Localizations.maybeLocaleOf(context);
  await showMapPdfDialog(
    context,
    defaultTitle: defaultTitle,
    build: (o, onProgress) async {
      // 凡例は紙の地図に入る範囲のレイヤだけ（縮尺は描くときと同じ計算）
      final layout = MapPdfLayout.compute(o.paper, landscape: o.landscape, withPanel: true);
      final lat = camera.center.latitude;
      final denominator = MapPdfScale.fitDenominator(
        viewport: proj.viewportSize,
        zoom: camera.zoom,
        latDeg: lat,
        frameMm: layout.map.size,
      );
      final radius = MapPdfScale.mercatorMetersPerMm(denominator, lat) *
          math.sqrt(math.pow(layout.map.width, 2) + math.pow(layout.map.height, 2)) /
          2;
      final legend = buildMapPdfLegend([
        for (final l in mapPdfLegendLayers(features, camera.center, radius)) ?MapPdfLegendLayer.fromLayer(l),
      ]);
      final providers = [for (final (p, _) in baseMaps.activeLayers) if (p.type != BaseMapType.generated) p.maxZoom];
      final s = layerStyleSettings;
      final req = MapPdfRequest(
        paper: o.paper,
        landscape: o.landscape,
        title: o.title,
        notes: o.notes,
        date: DateTime.now(),
        center: camera.center,
        zoom: camera.zoom,
        bearingDeg: camera.bearing,
        viewport: proj.viewportSize,
        legend: legend,
        attributions: mapPdfAttributions(baseMaps),
        labels: collectMapPdfLabels(polygons: geoJson.polygons, polylines: geoJson.polylines, markers: geoJson.markers),
        labelFontSize: s.getDouble(labelFontSizeDef),
        labelColor: s.getColor(labelColorDef),
        maxZoom: providers.isEmpty ? 18 : providers.reduce(math.max).clamp(0, 19),
        locale: locale,
        strings: MapPdfStrings(
          legend: t.mapPdf.legend,
          notes: t.mapPdf.notes,
          scale: t.mapPdf.scale,
          source: t.mapPdf.source,
          more: (n) => t.mapPdf.more(n: '$n'),
        ),
      );
      return renderMapPdf(
        req,
        (range, strokeScale, onTiles) => proj.snapshotTopDown(range, strokeScale: strokeScale, onProgress: onTiles),
        onProgress: onProgress,
      );
    },
  );
}
