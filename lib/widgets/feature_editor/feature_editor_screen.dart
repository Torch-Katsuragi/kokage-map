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
/// 全画面フィーチャ編集スクリーン
///
/// MapLibreMap を背景に、下部パネルで編集コントロールを表示。
/// カメラツールと同じ Navigator.push パターンで遷移する。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:maplibre/maplibre.dart' as ml;

import '../../core/r_map_controller.dart';
import '../../i18n/strings.g.dart';
import '../../models/nodes/feature_node.dart';
import '../../providers/service_providers.dart';
import '../../services/basemap_service.dart';
import '../../services/tile_server.dart';
import '../../utils/geo_converter.dart';
import '../map/r_map_widget.dart';
import 'feature_edit_action.dart';

class FeatureEditorScreen extends ConsumerStatefulWidget {
  final FeatureNode feature;
  final List<FeatureEditAction> actions;

  const FeatureEditorScreen({
    super.key,
    required this.feature,
    required this.actions,
  });

  @override
  ConsumerState<FeatureEditorScreen> createState() => _FeatureEditorScreenState();
}

class _FeatureEditorScreenState extends ConsumerState<FeatureEditorScreen> {
  late final List<FeatureEditAction> _applicable;
  late final ValueNotifier<PreviewLines> _previewLines;
  final RMapController _mapController = RMapController();
  bool _mapReady = false;
  bool _initialFitDone = false;

  @override
  void initState() {
    super.initState();
    _applicable =
        widget.actions.where((a) => a.canApplyTo(widget.feature)).toList();
    _previewLines = ValueNotifier(PreviewLines.empty);
    _previewLines.addListener(_onPreviewChanged);
  }

  @override
  void dispose() {
    _previewLines.removeListener(_onPreviewChanged);
    _previewLines.dispose();
    super.dispose();
  }

  void _onPreviewChanged() {
    _tryInitialFit();
    setState(() {});
  }

  void _onMapReady() {
    _mapReady = true;
    _tryInitialFit();
  }

  void _tryInitialFit() {
    final controller = _mapController.raw;
    if (_initialFitDone || !_mapReady || controller == null) return;
    final allPoints = [
      ..._previewLines.value.backgroundLine,
      ..._previewLines.value.foregroundLine,
    ];
    if (allPoints.isEmpty) return;
    _initialFitDone = true;

    // バウンディングボックスを計算
    double minLat = allPoints.first.latitude;
    double maxLat = allPoints.first.latitude;
    double minLng = allPoints.first.longitude;
    double maxLng = allPoints.first.longitude;
    for (final p in allPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || controller != _mapController.raw) return;
      controller.fitBounds(
        bounds: ml.LngLatBounds(
          longitudeWest: minLng,
          longitudeEast: maxLng,
          latitudeSouth: minLat,
          latitudeNorth: maxLat,
        ),
        padding: const EdgeInsets.all(40),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_applicable.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(t.featureEditorScreen.title)),
        body: Center(child: Text(t.featureEditorScreen.noActions)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.feature.name} — ${t.featureEditorScreen.title}',
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _buildMap(
              ref.watch(baseMapServiceProvider),
              ref.watch(tileServerProvider),
            ),
          ),

          // 下: コントロールパネル
          Material(
            elevation: 8,
            child: _applicable.length == 1
                ? _buildSinglePanel()
                : _buildTabbedPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(BaseMapService baseMapService, TileServer ts) {
    final lines = _previewLines.value;
    return RMapWidget(
      options: ml.MapOptions(
        initZoom: 14,
        initCenter: const geo.Geographic(lon: 139.7671, lat: 35.6812),
        initStyle: TileServer.localStyleUri ?? kEmptyMapStyle,
      ),
      onMapCreated: (controller) {
        _mapController.attach(controller.raw!);
      },
      onStyleLoaded: (_, style) async {
        final layers = baseMapService.activeLayerConfig;
        for (final (provider, opacity) in layers) {
          final url = ts.isRunning
              ? ts.urlTemplate(provider.id)
              : provider.urlTemplate;
          final sourceId = 'editor-basemap-${provider.id}';
          await style.addSource(ml.RasterSource(
            id: sourceId,
            tiles: [url],
            maxZoom: provider.maxZoom.toDouble(),
            tileSize: 256,
          ));
          await style.addLayer(ml.RasterStyleLayer(
            id: 'editor-basemap-layer-${provider.id}',
            sourceId: sourceId,
            paint: {'raster-opacity': opacity},
          ));
        }
        _onMapReady();
      },
      layers: [
        if (lines.backgroundLine.length >= 2)
          ml.PolylineLayer(
            polylines: [
              geo.Feature(
                geometry: geo.LineString.from(
                  lines.backgroundLine.toGeographics(),
                ),
              ),
            ],
            color: Colors.grey.shade400,
            width: 3,
          ),
        if (lines.foregroundLine.length >= 2)
          ml.PolylineLayer(
            polylines: [
              geo.Feature(
                geometry: geo.LineString.from(
                  lines.foregroundLine.toGeographics(),
                ),
              ),
            ],
            color: Colors.blue.shade700,
            width: 4,
          ),
      ],
    );
  }

  Widget _buildSinglePanel() {
    final action = _applicable.first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: action.buildControls(
        context,
        widget.feature,
        _previewLines,
      ),
    );
  }

  Widget _buildTabbedPanel() {
    return DefaultTabController(
      length: _applicable.length,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TabBar(
            isScrollable: true,
            tabs: [
              for (final action in _applicable)
                Tab(icon: Icon(action.icon, size: 18), text: action.label),
            ],
          ),
          SizedBox(
            height: 200,
            child: TabBarView(
              children: [
                for (final action in _applicable)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: action.buildControls(
                      context,
                      widget.feature,
                      _previewLines,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
