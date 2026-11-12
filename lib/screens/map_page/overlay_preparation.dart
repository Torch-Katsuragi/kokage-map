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
// GDAL のワープが遅い・止まると、gpkg の目を消しても地図が変わらなかった（Android 実機、大きな `.tif` のあるフォルダ）
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/fs/k_file_system.dart';
import '../../core/gdal/gdal.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/external_overlay_image_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../providers/notification_providers.dart';
import '../../services/geotiff_service.dart';
import '../../utils/app_logger.dart';

/// 直近で失敗を通知したオーバーレイ（パス → ファイル印）。
/// 地図の描き直し（`updateFeatures`）のたびに同じ壊れたラスタの通知が重ならないよう控え、
/// ファイルが変わったら改めて通知し、正常に作れたら消す。
final _notifiedRenderErrors = <String, String>{};

@visibleForTesting
void resetOverlayErrorHistory() => _notifiedRenderErrors.clear();

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
/// 画像の置き場か形（中心・m/px・画素数）が変わったノードがあれば true。1 枚の失敗で他を止めない。
/// [notifications] を渡すと、ワープ・PNG 化に失敗したとき通知センターに出す（同じファイル印では 1 回だけ）。
Future<bool> prepareOverlayImages(
  List<OverlayImageNode> nodes, {
  required bool web,
  NotificationCenter? notifications,
}) async {
  var changed = false;
  for (final node in nodes) {
    final before = (node.cachedPngPath, node.overlayParams.toJson().toString());
    final pathKey = node is ExternalOverlayImageNode ? node.filePath : (node.getAbsoluteFilePath() ?? node.filePath);
    try {
      if (node is ExternalOverlayImageNode) {
        // QGIS / GDAL のラスタは GDAL でワープした PNG（web も。GDAL は別スレッド／worker で動く）
        await node.ensureRendered();
      } else if (!web && _isTiff(node)) {
        // アプリの GeoTIFF は PNG キャッシュ（3D の地図面はこれを読む。web は元ファイルを直接読む）
        final abs = node.getAbsoluteFilePath();
        if (abs != null) node.cachedPngPath = await GeoTiffService.ensurePngCache(abs);
      }
      _notifiedRenderErrors.remove(pathKey);
    } catch (e) {
      AppLogger.debug('[Features] ${node.name} の表示用の画像を作れない: $e');
      if (notifications != null) {
        final stamp = await _errorStamp(pathKey);
        if (_notifiedRenderErrors[pathKey] != stamp) {
          _notifiedRenderErrors[pathKey] = stamp;
          final (reason, detail) = _formatOverlayError(e);
          notifications.add(
            title: t.externalLayer.overlayRenderFailed(name: node.name, reason: reason),
            detail: detail,
            level: NotificationLevel.error,
          );
        }
      }
    }
    if (before != (node.cachedPngPath, node.overlayParams.toJson().toString())) changed = true;
  }
  return changed;
}

Future<String> _errorStamp(String path) async {
  try {
    if (!await fs.exists(path)) return 'missing';
    return '${await fs.length(path)}:${(await fs.lastModified(path))?.millisecondsSinceEpoch}';
  } catch (_) {
    return 'unreadable';
  }
}

(String, String?) _formatOverlayError(Object error) {
  final raw = (error is GdalException ? error.message : error.toString())
      .replaceFirst(RegExp(r'^(GdalException|Exception|FileSystemException):\s*'), '')
      .trim();
  if (raw.isEmpty) return ('unknown error', null);
  final firstLine = raw.split(RegExp(r'\r?\n')).map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => raw);
  return (firstLine, raw != firstLine ? raw : null);
}
