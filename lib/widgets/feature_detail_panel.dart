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
// フィーチャ詳細パネルウィジェット
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/current_location_node.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/image_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/overlay_image_node.dart';
import '../providers/notification_providers.dart';
import '../providers/project_providers.dart';
import '../providers/selection_providers.dart';
import '../providers/ui_state_providers.dart';
import '../widgets/feature_editor/actions/simplify_action.dart';
import '../widgets/feature_editor/actions/trim_action.dart';
import '../widgets/feature_editor/feature_editor_screen.dart';
import '../widgets/info_panel_card.dart';
import '../widgets/long_press_delete_button.dart';
import '../widgets/photo_viewer.dart';

class FeatureDetailPanel extends ConsumerWidget {
  final dynamic feature;
  const FeatureDetailPanel({super.key, required this.feature});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (feature == null) return const SizedBox.shrink();

    // 現在位置（擬似フィーチャ）
    if (feature is CurrentLocationNode) {
      return _buildCurrentLocation(context, ref, feature as CurrentLocationNode);
    }

    // OverlayImageNode用の詳細パネル（ImageNodeより先にチェック）
    if (feature is OverlayImageNode) {
      final overlay = feature as OverlayImageNode;
      final params = overlay.overlayParams;

      return _buildPanel(
        context,
        ref,
        title: '🗺️ オーバーレイ画像',
        children: [
          // オーバーレイアイコン
          Container(
            width: double.infinity,
            height: 60,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.teal.shade200),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.layers, color: Colors.teal.shade400, size: 24),
                const SizedBox(height: 4),
                Text(
                  'GeoTIFF',
                  style: TextStyle(
                    color: Colors.teal.shade600,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // 名前
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.featureDetail.nameLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: Text(overlay.name)),
            ],
          ),
          const SizedBox(height: 4),
          // 中心座標
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.featureDetail.coordLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(
                child: Text(
                  '${params.centerLat.toStringAsFixed(6)}, ${params.centerLng.toStringAsFixed(6)}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // スケール・回転
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Scale: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('${params.scale.toStringAsFixed(3)} m/px', style: const TextStyle(fontSize: 11)),
              const SizedBox(width: 12),
              const Text('Rot: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('${params.rotation.toStringAsFixed(1)}°', style: const TextStyle(fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          // 画像サイズ
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.featureDetail.sizeLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(
                child: Text(
                  '${params.imageWidth} x ${params.imageHeight}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          // 削除ボタン
          const SizedBox(height: 12),
          LongPressDeleteButton(
            label: t.featureDetail.delete,
            onDelete: () => _handleDelete(ref),
          ),
        ],
      );
    }

    // ImageNode用の詳細パネル
    if (feature is ImageNode) {
      final photo = feature as ImageNode;

      // プロジェクトルートからの相対パスを計算
      final projectRoot = ref.read(projectRootDirProvider);
      String displayPath = photo.filePath;
      if (projectRoot != null && photo.filePath.startsWith(projectRoot)) {
        displayPath = photo.filePath.substring(projectRoot.length);
        if (displayPath.startsWith('\\') || displayPath.startsWith('/')) {
          displayPath = displayPath.substring(1);
        }
      }

      return _buildPanel(
        context,
        ref,
        title: '📸 写真ファイル',
        children: [
          // 画像プレビューを追加（タップでフルスクリーン表示）
          GestureDetector(
            onTap: () {
              showPhotoViewer(
                context,
                imagePath: photo.filePath,
              );
            },
            child: Container(
              width: double.infinity,
              height: 120,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                children: [
                  // 画像
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(photo.filePath),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: Colors.grey.shade100,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.broken_image, color: Colors.grey, size: 24),
                              const SizedBox(height: 4),
                              Text(
                                t.featureDetail.imageError,
                                style: const TextStyle(color: Colors.grey, fontSize: 10),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  // 拡大アイコン（ホバーヒント）
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(
                        Icons.zoom_in,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 詳細情報
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.featureDetail.nameLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: Text(photo.name)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.featureDetail.pathLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(
                child: Text(displayPath, style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.featureDetail.coordLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(
                child: Text(
                  photo.hasLocation
                      ? '${photo.location!.latitude.toStringAsFixed(6)}, ${photo.location!.longitude.toStringAsFixed(6)}'
                      : t.featureDetail.noLocation,
                  style: TextStyle(
                    fontSize: 11,
                    color: photo.hasLocation ? null : Colors.grey,
                    fontStyle: photo.hasLocation ? null : FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
          if (photo.takenAt != null) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.featureDetail.dateLabel,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Expanded(
                  child: Text(
                    '${photo.takenAt}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.featureDetail.sizeLabel,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: Text(
                  '${(photo.metadata.fileSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          // 削除ボタン
          const SizedBox(height: 12),
          LongPressDeleteButton(
            label: t.featureDetail.delete,
            onDelete: () => _handleDelete(ref),
          ),
        ],
      );
    }

    // 既存のFeatureNode用の処理
    if (feature is FeatureNode) {
      final node = feature as FeatureNode; // dynamic のフィールドは is で昇格しない
      final infoMap = node.infoMap;
      const hiddenKeys = {'geom', 'sub_table'};
      final filteredEntries =
          infoMap.entries
              .where((entry) =>
                  !entry.key.toLowerCase().contains('metadata') &&
                  !hiddenKeys.contains(entry.key))
              .toList();

      final children = <Widget>[
        for (final entry in filteredEntries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.key}: ',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Expanded(child: Text(entry.value)),
              ],
            ),
          ),
      ];

      // Point は Google Maps のリンクをコピー（長押しで開く。開くのは隠し機能扱い）
      if (feature is PointFeatureNode) {
        final point = (feature as PointFeatureNode).point;
        final lat = point.latitude;
        final lng = point.longitude;
        children.addAll([
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _copyGoogleMapsLink(ref, lat, lng),
              onLongPress: () => _openInGoogleMaps(ref, lat, lng),
              icon: const Icon(Icons.link, size: 16),
              label: Text(t.featureDetail.copyGoogleMapsLink),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade50,
                foregroundColor: Colors.green.shade700,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ]);
      }

      // Line/Polygonの場合は「編集」ボタンを追加
      if (feature is LineFeatureNode || feature is PolygonFeatureNode) {
        children.addAll([
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _openFeatureEditor(context, feature),
              icon: const Icon(Icons.edit, size: 16),
              label: Text(t.featureDetail.edit),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade50,
                foregroundColor: Colors.blue.shade700,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ]);
      }

      // 全フィーチャ共通: 削除ボタンを追加
      children.addAll([
        const SizedBox(height: 12),
        LongPressDeleteButton(
          label: t.featureDetail.delete,
          onDelete: () => _handleDelete(ref),
        ),
      ]);

      // タイトルをシンプルに（PointFeatureNode → Point等）
      String displayTitle = 'Feature';
      if (feature is PointFeatureNode) {
        displayTitle = 'Point';
      } else if (feature is LineFeatureNode) {
        displayTitle = 'Line';
      } else if (feature is PolygonFeatureNode) {
        displayTitle = 'Polygon';
      }
      
      return _buildPanel(
        context,
        ref,
        title: displayTitle,
        children: children,
      );
    }
    return const SizedBox.shrink();
  }

  static Uri _googleMapsWebUri(double lat, double lng) =>
      Uri.parse('https://www.google.com/maps?q=$lat,$lng');

  /// Google Maps のリンクをクリップボードへ（LINE 等に貼る用途が主）
  Future<void> _copyGoogleMapsLink(WidgetRef ref, double lat, double lng) async {
    await Clipboard.setData(
      ClipboardData(text: _googleMapsWebUri(lat, lng).toString()),
    );
    ref.read(notificationCenterProvider.notifier).add(
      title: t.featureDetail.googleMapsLinkCopied,
      level: NotificationLevel.success,
    );
  }

  /// Google Mapsでポイントを開く（ボタン長押し）
  /// Android: geo: intentでGoogle Mapsアプリを優先起動
  /// PC/アプリなし: https:// URLでブラウザにフォールバック
  Future<void> _openInGoogleMaps(WidgetRef ref, double lat, double lng) async {
    // Android向け: geo: URIでGoogle Mapsアプリを直接起動
    final geoUri = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    final webUri = _googleMapsWebUri(lat, lng);

    try {
      if (await canLaunchUrl(geoUri)) {
        await launchUrl(geoUri);
      } else {
        // PC or Google Maps未インストール → ブラウザで開く
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // 両方失敗した場合
      ref.read(notificationCenterProvider.notifier).add(
        title: t.featureDetail.googleMapsOpenFailed,
        detail: e.toString(),
        level: NotificationLevel.error,
      );
    }
  }

  /// フィーチャ/写真を削除
  Future<void> _handleDelete(WidgetRef ref) async {
    final target = feature as LayerTreeNode; // FeatureNode / ImageNode / OverlayImageNode はいずれも LayerTreeNode
    // 選択解除でウィジェットがアンマウントされるため、先にNotifier参照をキャプチャ
    final selectionNotifier = ref.read(selectedFeaturesProvider.notifier);
    final refreshNotifier = ref.read(featureRefreshTriggerProvider.notifier);
    final notifNotifier = ref.read(notificationCenterProvider.notifier);
    try {
      // 1. 選択解除 → パネルが消える → ファイル参照が無くなる
      selectionNotifier.remove(target);
      // 2. UIリビルドを確実に挟む
      await Future<void>.delayed(Duration.zero);
      // 3. ファイル/DB削除
      await target.dispose();
      refreshNotifier.trigger();
      notifNotifier.add(
        title: t.featureDetail.deleted,
        level: NotificationLevel.success,
      );
    } catch (e) {
      notifNotifier.add(
        title: t.featureDetail.deleteFailed,
        detail: e.toString(),
        level: NotificationLevel.error,
      );
    }
  }

  /// フィーチャ編集画面に遷移
  void _openFeatureEditor(BuildContext context, FeatureNode feature) {
    Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => FeatureEditorScreen(
          feature: feature,
          actions: [
            SimplifyAction(),
            TrimAction(),
          ],
        ),
      ),
    );
  }

  /// パネルの枠は [InfoPanelCard]（複数選択・現在位置のカードと共通）
  Widget _buildPanel(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required List<Widget> children,
  }) =>
      InfoPanelCard(
        title: title,
        onClose: () => ref.read(selectedFeaturesProvider.notifier).clear(),
        children: children,
      );

  /// 現在位置（擬似フィーチャ）の GPS 情報
  Widget _buildCurrentLocation(
    BuildContext context,
    WidgetRef ref,
    CurrentLocationNode node,
  ) {
    final info = node.gpsInfo;
    final active = info != null && info['isActive'] == true;
    final lat = info?['latitude'] as double?;
    final lon = info?['longitude'] as double?;
    final accuracy = info?['accuracy'] as double?;
    final satellites = info?['satelliteCount'] as int?;
    final hdop = info?['hdop'] as double?;
    final sourceName = info?['sourceName'] as String? ?? t.gps.unknownDevice;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: Text(value)),
            ],
          ),
        );

    return _buildPanel(
      context,
      ref,
      title: t.gpsPanel.title,
      children: [
        if (!active) row(t.gpsPanel.status, t.gps.acquiring),
        if (lat != null && lon != null)
          row(t.gpsPanel.position, '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}'),
        if (accuracy != null) row(t.gpsPanel.accuracy, '±${accuracy.toStringAsFixed(1)} m'),
        if (satellites != null) row(t.gpsPanel.satellites, '$satellites'),
        if (hdop != null) row('HDOP', hdop.toStringAsFixed(2)),
        row(t.gpsPanel.source, sourceName),
        ValueListenableBuilder<double?>(
          valueListenable: node.headingNotifier,
          builder: (_, heading, _) => heading == null
              ? const SizedBox.shrink()
              : row(t.gpsPanel.heading, '${heading.toStringAsFixed(0)}°'),
        ),
      ],
    );
  }
}

