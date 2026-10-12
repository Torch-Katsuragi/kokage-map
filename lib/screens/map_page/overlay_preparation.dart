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
// こかげマップ: オーバーレイ画像の表示用の画像（GeoTIFF の PNG キャッシュ・外のラスタの GDAL ワープ）の用意。
//
// 地図の描き直し（`MapFeatureCacheMixin.updateFeatures`）は、地物と可視性を先に地図へ流し、
// これを後から待つ（2026-10-13）。⚠ 以前は全オーバーレイの用意を待ってから地物を流していたので、
// GDAL のワープが遅い・止まると、gpkg の目を消しても地図が変わらなかった（Pixel 9、`林相.tif` のあるフォルダ）
import '../../models/nodes/external_overlay_image_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../services/geotiff_service.dart';
import '../../utils/app_logger.dart';

bool _isTiff(OverlayImageNode n) {
  final lower = n.filePath.toLowerCase();
  return lower.endsWith('.tif') || lower.endsWith('.tiff');
}

/// 表示用の画像を待たずに描けるか。外のラスタは GDAL の PNG ができてから、
/// アプリの GeoTIFF は Android では PNG キャッシュができてから（web は元ファイルを直接読む）
bool overlayDrawableNow(OverlayImageNode n, {required bool web}) {
  if (n is ExternalOverlayImageNode) return n.cachedPngPath != null;
  if (web || !_isTiff(n)) return true;
  return n.cachedPngPath != null;
}

/// [nodes] の表示用の画像を用意する（あれば使う。元が変わっていれば作り直す）。
/// 画像の置き場か形（中心・m/px・画素数）が変わったノードがあれば true。1 枚の失敗で他を止めない
Future<bool> prepareOverlayImages(List<OverlayImageNode> nodes, {required bool web}) async {
  var changed = false;
  for (final node in nodes) {
    final before = (node.cachedPngPath, node.overlayParams.toJson().toString());
    try {
      if (node is ExternalOverlayImageNode) {
        // QGIS / GDAL のラスタは GDAL でワープした PNG（web も。GDAL は別スレッド／worker で動く）
        await node.ensureRendered();
      } else if (!web && _isTiff(node)) {
        // アプリの GeoTIFF は PNG キャッシュ（3D の地図面はこれを読む。web は元ファイルを直接読む）
        final abs = node.getAbsoluteFilePath();
        if (abs != null) node.cachedPngPath = await GeoTiffService.ensurePngCache(abs);
      }
    } catch (e) {
      AppLogger.debug('[Features] ${node.name} の表示用の画像を作れない: $e');
    }
    if (before != (node.cachedPngPath, node.overlayParams.toJson().toString())) changed = true;
  }
  return changed;
}
