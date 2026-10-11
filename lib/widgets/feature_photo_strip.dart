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
// こかげマップ: 地物に付けた写真（情報パネル・編集パネルの属性）
//
// 「写真を撮る」は端末のカメラアプリ（image_picker の camera）。アプリ内のカメラは持たない
// （CAMERA の扱いをカメラアプリに任せる）。「写真を選ぶ」は Android ならアプリ内のギャラリー
// （位置の有り無しが選ぶ前に見える。ギャラリーの取り込みと同じ）、web は OS のファイル選択。
// 縮図を押すと大きく見る、長押しで外す（ファイルも消すかを聞く）。

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../core/platform_capabilities.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/feature_node.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../screens/gallery_import_screen.dart';
import '../screens/photo_picker_screen.dart';
import '../services/feature_photos/feature_photo_service.dart';
import '../services/gps_manager_service.dart';
import '../utils/app_logger.dart';
import 'external_layer_actions.dart';
import 'photo_viewer.dart';

class FeaturePhotoStrip extends ConsumerStatefulWidget {
  const FeaturePhotoStrip({super.key, required this.feature});

  final FeatureNode feature;

  @override
  ConsumerState<FeaturePhotoStrip> createState() => _FeaturePhotoStripState();
}

class _FeaturePhotoStripState extends ConsumerState<FeaturePhotoStrip> {
  /// 縮図の中身（パス → 読んだバイト列。読めなければ null）
  final _bytes = <String, Future<Uint8List?>>{};
  bool _busy = false;

  FeatureNode get _f => widget.feature;

  Future<Uint8List?> _load(String path) => _bytes.putIfAbsent(path, () async {
        try {
          if (!await fs.exists(path)) return null;
          return await fs.readAsBytes(path);
        } on Object catch (e) {
          AppLogger.debug('[FeaturePhoto] 読めない $path: $e');
          return null;
        }
      });

  // 通知と描き直しの合図は、await の前に取っておく（カメラから戻る前にパネルが閉じると ref は使えない。
  // 写真は gpkg に付くので、ツリーと地図の描き直しはパネルが無くても行う）
  late final NotificationCenter _notes;
  late final FeatureRefreshTrigger _refresh;

  @override
  void initState() {
    super.initState();
    _notes = ref.read(notificationCenterProvider.notifier);
    _refresh = ref.read(featureRefreshTriggerProvider.notifier);
  }

  void _notify(String title, NotificationLevel level, {String? detail}) =>
      _notes.add(title: title, detail: detail, level: level);

  /// 付けたあと: レイヤ一覧に photos/ を出し、地図（写真の印）とパネルを描き直す
  Future<void> _afterAttach(int count) async {
    if (count == 0) return;
    await FeaturePhotoService.refreshTree(_f);
    _refresh.trigger();
    _notify(t.featurePhotos.attached(count: count), NotificationLevel.success);
  }

  Future<void> _run(Future<int> Function() body) async {
    if (_busy) return;
    // 読み取り専用レイヤ（shp・GeoJSON など）は列を足せない。「gpkg に変換して編集」を出す
    if (refuseReadOnlyEditBy(ref.read, _f)) return;
    setState(() => _busy = true);
    try {
      final count = await body();
      await _afterAttach(count);
    } on Object catch (e) {
      AppLogger.debug('[FeaturePhoto] 付けられない: $e');
      _notify(t.featurePhotos.attachFailed, NotificationLevel.error, detail: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 端末のカメラアプリで撮る。位置が入っていなければ今の GPS の位置を書き込む
  Future<void> _take() => _run(() async {
        XFile? shot;
        try {
          shot = await ImagePicker().pickImage(source: ImageSource.camera, requestFullMetadata: true);
        } on Object catch (e) {
          _notify(t.featurePhotos.cameraFailed, NotificationLevel.error, detail: '$e');
          return 0;
        }
        if (shot == null) return 0;
        final gps = GpsManagerService().currentInfo;
        final lat = gps.latitude;
        final lng = gps.longitude;
        final photo = await FeaturePhotoService.attachBytes(
          _f,
          await shot.readAsBytes(),
          ext: _extOf(shot.name, shot.path),
          fix: lat != null && lng != null ? LatLng(lat, lng) : null,
          altitude: gps.altitude,
        );
        if (photo == null) throw StateError('gpkg の場所が分からない');
        return 1;
      });

  /// 撮ってある写真から選ぶ（位置は書き足さない。別の場所で撮った写真かもしれないので）
  Future<void> _pick() => _run(() async {
        var count = 0;
        if (PlatformCapabilities.supportsNativeGalleryCopy) {
          await GalleryImporter.ensureMediaLocationPermission();
          if (!mounted) return 0;
          final assets = await PhotoPickerScreen.pick(context);
          if (assets != null) {
            for (final a in assets) {
              final file = await a.originFile;
              if (file == null) continue;
              final title = await a.titleAsync;
              final photo = await FeaturePhotoService.attachBytes(
                _f,
                await file.readAsBytes(),
                ext: _extOf(title, file.path),
                takenAt: a.createDateTime,
              );
              if (photo != null) count++;
            }
            return count;
          }
        }
        final files = await ImagePicker().pickMultiImage(requestFullMetadata: true);
        for (final x in files) {
          final photo = await FeaturePhotoService.attachBytes(
            _f,
            await x.readAsBytes(),
            ext: _extOf(x.name, x.path),
            takenAt: await x.lastModified(),
          );
          if (photo != null) count++;
        }
        return count;
      });

  static String _extOf(String name, String path) {
    final e = p.extension(name).isNotEmpty ? p.extension(name) : p.extension(path);
    return e.isEmpty ? '.jpg' : e;
  }

  Future<void> _view(FeaturePhoto photo) async {
    final bytes = await _load(photo.path);
    if (!mounted) return;
    if (bytes == null) {
      _notify(t.featurePhotos.missing, NotificationLevel.warning, detail: photo.value);
      return;
    }
    showPhotoViewer(context, imagePath: photo.path, bytes: bytes);
  }

  /// 外す（ファイルも消すかを選ぶ）
  Future<void> _remove(FeaturePhoto photo) async {
    if (refuseReadOnlyEditBy(ref.read, _f)) return;
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.featurePhotos.removeTitle),
        content: Text('${t.featurePhotos.removeBody}\n\n${photo.value}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.featurePhotos.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(t.featurePhotos.unlinkAndDelete),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.featurePhotos.unlinkOnly)),
        ],
      ),
    );
    if (choice == null) return;
    await FeaturePhotoService.unlink(_f, photo, deleteFile: choice);
    _bytes.remove(photo.path)?.ignore();
    if (choice) await FeaturePhotoService.refreshTree(_f);
    _refresh.trigger();
    if (mounted) setState(() {});
    _notify(t.featurePhotos.removed, NotificationLevel.success);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photos = FeaturePhotoService.photosOf(_f);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(t.featurePhotos.title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(
              tooltip: t.featurePhotos.pick,
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.photo_library_outlined),
            ),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _take,
              icon: const Icon(Icons.photo_camera, size: 18),
              label: Text(t.featurePhotos.take),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        if (photos.isNotEmpty)
          SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) => _thumb(photos[i], theme),
            ),
          ),
      ],
    );
  }

  Widget _thumb(FeaturePhoto photo, ThemeData theme) => Tooltip(
        message: photo.value,
        child: InkWell(
          onTap: () => _view(photo),
          onLongPress: () => _remove(photo),
          borderRadius: BorderRadius.circular(6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 76,
              height: 76,
              child: FutureBuilder<Uint8List?>(
                future: _load(photo.path),
                builder: (_, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return ColoredBox(color: theme.colorScheme.surfaceContainerHighest);
                  }
                  final data = snap.data;
                  if (data == null) {
                    return ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.broken_image_outlined, color: theme.colorScheme.outline),
                    );
                  }
                  return Image.memory(
                    data,
                    fit: BoxFit.cover,
                    cacheWidth: 228,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: theme.colorScheme.outline),
                  );
                },
              ),
            ),
          ),
        ),
      );
}
