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
/// Root Maps: 写真タイルウィジェット
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../../../i18n/strings.g.dart';
import '../../../models/kmeta.dart';
import '../../../models/nodes/image_node.dart';
import '../../../models/nodes/overlay_image_node.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../services/geotiff_service.dart';
import '../../../services/kmeta_service.dart';
import '../../../utils/app_logger.dart';
import '../../dialogs/overlay_convert_dialog.dart';
import '../common_dialogs.dart';
import 'node_visibility_icon.dart';

/// 写真ノード用の ListTile ウィジェット
class PhotoTile extends ConsumerWidget {
  final ImageNode node;
  final VoidCallback? onRename;
  final void Function(LatLng)? onJumpTo;

  const PhotoTile({
    super.key,
    required this.node,
    this.onRename,
    this.onJumpTo,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOverlay = node is OverlayImageNode;

    return ListTile(
      leading: NodeVisibilityIcon(node: node),
      title: Text(node.name),
      subtitle: isOverlay
          ? Text(t.layerDrawer.photo.overlay, style: const TextStyle(fontSize: 11, color: Colors.teal))
          : node.hasLocation
              ? null
              : Text(t.layerDrawer.photo.noLocation, style: const TextStyle(fontSize: 11)),
      onTap: () {
        ref.read(selectedFeaturesProvider.notifier).set([node]);
        if (node.hasLocation && onJumpTo != null) {
          onJumpTo!(node.location!);
        }
      },
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          switch (value) {
            case 'rename':
              onRename?.call();
            case 'delete':
              await _handleDelete(context, ref);
            case 'convert_to_overlay':
              await _handleConvertToOverlay(context, ref);
            case 'convert_to_normal':
              await _handleConvertToNormal(context, ref);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'rename', child: Text(t.layerDrawer.photo.changeName)),
          if (!isOverlay)
            PopupMenuItem(
              value: 'convert_to_overlay',
              child: Text(t.layerDrawer.photo.convertToOverlay),
            ),
          if (isOverlay)
            PopupMenuItem(
              value: 'convert_to_normal',
              child: Text(t.layerDrawer.photo.convertToNormal),
            ),
          PopupMenuItem(value: 'delete', child: Text(t.layerDrawer.photo.deletePhoto)),
        ],
      ),
    );
  }

  Future<void> _handleDelete(BuildContext context, WidgetRef ref) async {
    await confirmAndExecute(
      context,
      ref: ref,
      title: t.layerDrawer.photo.deleteTitle,
      content: Text(t.layerDrawer.photo.deleteConfirm(name: node.name)),
      confirmLabel: t.common.delete,
      confirmColor: Colors.red,
      successMessage: t.layerDrawer.photo.photoDeleted(name: node.name),
      execute: () async {
        ref.read(selectedFeaturesProvider.notifier).remove(node);
        await node.dispose();
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      },
    );
  }

  /// 通常のImageNode → OverlayImageNodeに変換
  /// ダイアログでファイル名と画像処理を選択してからGeoTIFF生成
  Future<void> _handleConvertToOverlay(BuildContext context, WidgetRef ref) async {
    final absPath = node.getAbsoluteFilePath();
    if (absPath == null) return;

    final folderPath = p.dirname(absPath);
    final srcFileName = p.basename(absPath);

    // 変換ダイアログを表示
    if (!context.mounted) return;
    final result = await showOverlayConvertDialog(
      context,
      srcFileName: srcFileName,
    );
    if (result == null) return; // キャンセル

    // 画像サイズを取得
    int imageWidth = 1920;
    int imageHeight = 1080;
    try {
      final file = File(absPath);
      final imageBytes = await file.readAsBytes();
      final decoded = img.decodeImage(imageBytes);
      if (decoded != null) {
        imageWidth = decoded.width;
        imageHeight = decoded.height;
      }
    } catch (e) {
      AppLogger.debug('[PhotoTile] Failed to read image size: $e');
    }

    // カメラ中心座標を取得（現在表示中のマップ中心に配置）
    double centerLng = 139.767;
    double centerLat = 35.681;
    final mapController = ref.read(mapControllerHolderProvider);
    if (mapController?.raw != null) {
      final cameraCenter = mapController!.camera.center;
      centerLng = cameraCenter.longitude;
      centerLat = cameraCenter.latitude;
    } else if (node.hasLocation) {
      // マップコントローラ未初期化時はEXIF位置をフォールバック
      centerLng = node.location!.longitude;
      centerLat = node.location!.latitude;
    }

    final overlay = KMetaImageOverlay(
      centerLng: centerLng,
      centerLat: centerLat,
      scale: 1.0,  // 1 m/px
      rotation: 0.0,

      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );

    // GeoTIFFファイルを生成
    final tifPath = GeoTiffService.outputPathForSource(
      absPath,
      outputName: result.outputName,
    );
    final tifFileName = p.basename(tifPath);
    try {
      await GeoTiffService.createGeoTiff(
        absPath,
        tifPath,
        overlay,
        mode: result.mode,
        threshold: result.threshold,
      );
    } catch (e) {
      AppLogger.debug('[PhotoTile] GeoTIFF creation failed: $e');
      return;
    }

    // kmetaにGeoTIFFファイル名でオーバーレイ設定を登録
    final success = await KMetaService.instance.setImageOverlay(
      folderPath, tifFileName, overlay,
    );
    if (success) {
      AppLogger.debug('[PhotoTile] Converted to overlay: $tifFileName');
      if (node.parent != null) {
        await node.parent!.updateChildren();
      }
      if (context.mounted) {
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      }
    }
  }

  /// OverlayImageNode → 通常のImageNodeに戻す
  /// GeoTIFFファイルを削除し、kmetaからオーバーレイ設定を削除
  Future<void> _handleConvertToNormal(BuildContext context, WidgetRef ref) async {
    final absPath = node.getAbsoluteFilePath();
    if (absPath == null) return;

    final folderPath = p.dirname(absPath);
    final fileName = p.basename(absPath);

    // kmetaからオーバーレイ設定を削除
    final success = await KMetaService.instance.removeImageOverlay(
      folderPath, fileName,
    );
    if (success) {
      // GeoTIFFファイルを削除
      try {
        final file = File(absPath);
        if (await file.exists()) {
          await file.delete();
          AppLogger.debug('[PhotoTile] Deleted GeoTIFF: $fileName');
        }
      } catch (e) {
        AppLogger.debug('[PhotoTile] Failed to delete GeoTIFF: $e');
      }

      AppLogger.debug('[PhotoTile] Converted to normal: $fileName');
      if (node.parent != null) {
        await node.parent!.updateChildren();
      }
      if (context.mounted) {
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      }
    }
  }
}

