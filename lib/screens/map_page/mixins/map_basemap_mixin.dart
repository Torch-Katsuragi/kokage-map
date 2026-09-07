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
// こかげマップ: ベースマップ（ラスタタイル）のソース／レイヤを MapLibre のスタイルに積む

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart' as ml;

import '../../../core/platform_capabilities.dart';
import '../../../services/basemap_style_json.dart';
import '../../../services/map_source_manager.dart';
import '../../../utils/app_logger.dart';
import '../map_page_state_base.dart';

mixin MapBasemapMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  /// 積んだ basemap レイヤ／ソースの ID（切替時の削除用）
  final List<String> activeBasemapLayerIds = [];
  final List<String> activeBasemapSourceIds = [];

  /// ベースマップソース追加（複数プロバイダ対応）
  ///
  /// `activeLayerConfig` で有効なプロバイダごとに RasterSource + RasterStyleLayer を登録する。
  /// [belowLayerId] 指定時はそのレイヤの下に挿入（[replaceBasemapSource] 用）
  Future<void> addBasemapSources(
    ml.StyleController style, {
    String? belowLayerId,
  }) async {
    final layers = baseMapService.activeLayerConfig;
    if (layers.isEmpty) return;

    // web は `StyleController.addSource()` で RasterSource を登録できない
    // （maplibre_web 0.3.5 のバグ。詳細は basemap_style_json.dart）。
    // ソースは初期スタイルJSONに全プロバイダぶん焼き込んであるので、
    // ここではレイヤを積むだけでよい（`addLayer` は web でも正常に動く）。
    if (PlatformCapabilities.isWeb) {
      for (final (provider, opacity) in layers) {
        final layerId = basemapLayerId(provider.id);
        try {
          await style.addLayer(
            ml.RasterStyleLayer(
              id: layerId,
              sourceId: basemapSourceId(provider.id),
              paint: {'raster-opacity': opacity},
            ),
            belowLayerId: belowLayerId,
          );
          activeBasemapLayerIds.add(layerId);
          AppLogger.debug(
            '[MAP] addBasemapLayer(web): ${provider.id} '
            'opacity=${opacity.toStringAsFixed(2)}',
          );
        } catch (e) {
          AppLogger.debug('[MAP] addBasemapLayer error (${provider.id}): $e');
        }
      }
      return;
    }

    for (final (provider, opacity) in layers) {
      final sourceId = basemapSourceId(provider.id);
      final layerId = basemapLayerId(provider.id);

      // Android + オフラインで mbtiles があれば直接読む。それ以外は
      // TileServer 経由（キャッシュ＋フォールバック付き）
      final mbtilesPath =
          PlatformCapabilities.supportsOfflineMBTiles &&
                  !baseMapService.isNetworkAvailable
              ? baseMapService.getMBTilesPath(provider.id)
              : null;
      final ml.RasterSource source;
      if (mbtilesPath != null) {
        source = ml.RasterSource(
          id: sourceId,
          url: 'mbtiles://$mbtilesPath',
          maxZoom: provider.maxZoom.toDouble(),
          tileSize: 256,
        );
      } else {
        final url = tileServer.isRunning
            ? tileServer.urlTemplate(provider.id)
            : provider.urlTemplate;
        source = ml.RasterSource(
          id: sourceId,
          tiles: [url],
          maxZoom: provider.maxZoom.toDouble(),
          tileSize: 256,
          attribution: provider.attribution,
        );
      }

      try {
        await style.addSource(source);
        await style.addLayer(
          ml.RasterStyleLayer(
            id: layerId,
            sourceId: sourceId,
            paint: {'raster-opacity': opacity},
          ),
          belowLayerId: belowLayerId,
        );
        activeBasemapSourceIds.add(sourceId);
        activeBasemapLayerIds.add(layerId);
        AppLogger.debug(
          '[MAP] addBasemapSource: ${provider.id} opacity=${opacity.toStringAsFixed(2)}',
        );
      } catch (e) {
        AppLogger.debug('[MAP] addBasemapSource error (${provider.id}): $e');
      }
    }
  }

  /// ベースマップ切替（旧ソース全削除→新ソース追加）
  Future<void> replaceBasemapSource() async {
    final style = mapControllerInstance.style;
    if (style == null) return;

    // 既存の全basemapレイヤを削除
    for (final layerId in activeBasemapLayerIds.reversed) {
      try {
        await style.removeLayer(layerId);
      } catch (_) {}
    }
    activeBasemapLayerIds.clear();

    // ⚠ web のソースは初期スタイルJSONに焼き込んだもので、消すと二度と足せない
    // （`addSource` が壊れているのがそもそもの発端）。消すのは native だけ。
    if (!PlatformCapabilities.isWeb) {
      for (final sourceId in activeBasemapSourceIds.reversed) {
        try {
          await style.removeSource(sourceId);
        } catch (_) {}
      }
      activeBasemapSourceIds.clear();
    }

    await addBasemapSources(style, belowLayerId: MapSourceManager.kPolygonsFill);
  }
}
