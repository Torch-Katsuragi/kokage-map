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
// Root Maps: ギャラリーインポート
// file_picker で画像を選択し、プロジェクトフォルダにコピー（EXIF完全保持）
//
// Android の Photo Picker は content URI 経由でキャッシュコピーを返す際に
// EXIF GPS データをプライバシー保護のため除去してしまう。
// そこで file_picker の identifier (content URI) を MethodChannel 経由で
// Kotlin 側に渡し、MediaStore から実ファイルパスを解決して直接コピーすることで
// EXIF メタデータを完全保持する。
//
// ⚠ 原本が読めるのは「全ファイルアクセス」か「ACCESS_MEDIA_LOCATION」を持っているときだけ。
// どちらも無いと Android はリダクション済み（GPSゼロ埋め）のバイトしか渡さない。
// ネイティブ側は掴んだバイトの素性（original / maybe_redacted）を返すので、
// 位置情報が取れなかった写真があればユーザーに知らせる。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../core/platform_capabilities.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/folder_node.dart';
import '../models/nodes/image_node.dart';
import '../providers/notification_providers.dart';
import '../utils/app_logger.dart';
import '../utils/exif_parser.dart';

/// コピーしたバイトの素性（ネイティブ側の戻り値に対応）
enum _CopyResult {
  /// 位置情報を含む原本
  original,

  /// 権限不足でリダクション済み（GPSゼロ埋め）の複製を掴んだ可能性がある
  maybeRedacted,

  /// コピー失敗
  failed,
}

/// ギャラリーからプロジェクトフォルダに写真をインポートするユーティリティ
class GalleryImporter {
  GalleryImporter._();

  static const _channel = MethodChannel('com.k_root.k_maps/media_copy');

  /// ファイルピッカーで画像を選択し、targetFolder にインポートする。
  static Future<bool> pickAndImport(
    BuildContext context,
    FolderNode targetFolder, {
    WidgetRef? ref,
  }) async {
    await _ensureMediaLocationPermission();

    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return false;

    final folderPath = targetFolder.getAbsoluteFilePath();
    if (folderPath == null) {
      if (ref != null) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.galleryImport.folderPathFailed,
          level: NotificationLevel.error,
        );
      }
      return false;
    }

    int imported = 0;
    // リダクションされた可能性があり、実際に位置情報が取れなかった枚数
    int strippedLocation = 0;
    for (final file in result.files) {
      try {
        // Photo Picker は表示名がメディアID（例: "20.jpg"）になるので、
        // MediaStore から元のファイル名を引き直せたらそちらを使う
        final name = await _resolveSourceName(file);

        // 拡張子を name から取得（identifier 経由だと srcPath が無い場合がある）
        final ext = p.extension(name).toLowerCase();
        if (ext.isEmpty) continue;

        final baseName = p.basenameWithoutExtension(name);
        final destPath = _uniquePath(folderPath, baseName, ext);

        // Android: content URI からネイティブ側で実ファイルを直接コピー（EXIF 保持）
        // 非 Android: 従来の File.copy フォールバック
        final copy = await _copyFile(file, destPath);
        if (copy == _CopyResult.failed) {
          AppLogger.debug('[GalleryImport] Failed to copy ${file.name}');
          continue;
        }

        final node = await _createImageNode(destPath, targetFolder);
        if (copy == _CopyResult.maybeRedacted && !node.hasLocation) {
          strippedLocation++;
        }
        AppLogger.debug(
          '[GalleryImport] ${p.basename(destPath)}: copy=${copy.name} '
          'location=${node.hasLocation}',
        );
        targetFolder.addChild(node);
        imported++;
      } catch (e) {
        AppLogger.debug('[GalleryImport] Error importing ${file.name}: $e');
      }
    }

    if (ref != null) {
      final notifier = ref.read(notificationCenterProvider.notifier);
      if (imported > 0) {
        notifier.add(
          title: t.galleryImport.imported(count: imported),
          level: NotificationLevel.success,
        );
      }
      if (strippedLocation > 0) {
        notifier.add(
          title: t.galleryImport.locationMayBeStripped(count: strippedLocation),
          detail: t.galleryImport.locationMayBeStrippedHint,
          level: NotificationLevel.warning,
        );
      }
    }
    return imported > 0;
  }

  /// 位置情報つきで原本を読むための権限を確保する（Android のみ）。
  ///
  /// 全ファイルアクセスがあれば実パス直読みで足りる。無い端末では
  /// READ_MEDIA_IMAGES + ACCESS_MEDIA_LOCATION を求め、ネイティブ側の
  /// `MediaStore.setRequireOriginal` 経路を通せるようにする。
  /// ACCESS_MEDIA_LOCATION 自体はダイアログ無しで付く。
  static Future<void> _ensureMediaLocationPermission() async {
    if (!PlatformCapabilities.supportsNativeGalleryCopy) return;
    try {
      if (await Permission.manageExternalStorage.isGranted) return;
      final statuses =
          await [Permission.photos, Permission.accessMediaLocation].request();
      AppLogger.debug('[GalleryImport] media permissions: $statuses');
    } catch (e) {
      AppLogger.debug('[GalleryImport] permission request failed: $e');
    }
  }

  /// 元のファイル名を解決する（Android のみ MediaStore へ問い合わせ）。
  /// 取れなければピッカーが報告した表示名のまま。
  static Future<String> _resolveSourceName(PlatformFile file) async {
    if (PlatformCapabilities.supportsNativeGalleryCopy &&
        file.identifier != null) {
      try {
        final name = await _channel.invokeMethod<String>(
          'resolveDisplayName',
          {'uri': file.identifier},
        );
        if (name != null && name.isNotEmpty) return name;
      } catch (_) {}
    }
    return file.name;
  }

  /// ファイルをコピーする。
  /// Android では MethodChannel 経由で content URI から実ファイルを直接コピーし、
  /// EXIF メタデータを完全保持する。
  /// 非 Android や identifier が無い場合は File.copy でフォールバック。
  static Future<_CopyResult> _copyFile(PlatformFile file, String destPath) async {
    // Android: content URI が取れればネイティブ側で実ファイルコピー
    if (PlatformCapabilities.supportsNativeGalleryCopy &&
        file.identifier != null) {
      try {
        final mode = await _channel.invokeMethod<String>('copyOriginal', {
          'uri': file.identifier,
          'destPath': destPath,
        });
        switch (mode) {
          case 'original':
            return _CopyResult.original;
          case 'maybe_redacted':
            return _CopyResult.maybeRedacted;
          default:
            break; // null = ネイティブ側で失敗 → フォールバックへ
        }
      } catch (e) {
        AppLogger.debug('[GalleryImport] Native copy failed, falling back: $e');
      }
    }

    // フォールバック: file_picker のキャッシュパスからコピー
    // ⚠ Android ではこのキャッシュはピッカーが渡したリダクション済みの複製
    final srcPath = file.path;
    if (srcPath == null) return _CopyResult.failed;
    await File(srcPath).copy(destPath);
    return PlatformCapabilities.supportsNativeGalleryCopy
        ? _CopyResult.maybeRedacted
        : _CopyResult.original;
  }

  /// EXIF から位置情報・メタデータを読み取って ImageNode を生成
  static Future<ImageNode> _createImageNode(
    String destPath,
    FolderNode parent,
  ) async {
    LatLng? location;
    DateTime? takenAt;
    double? direction;
    int? width;
    int? height;

    final exif = await ExifParser.extractFromFile(destPath);
    if (exif != null) {
      location = exif.location;
      takenAt = exif.takenAt;
      direction = exif.direction;
      width = exif.metadata.width;
      height = exif.metadata.height;
    }

    final stats = await File(destPath).stat();
    return ImageNode(
      destPath,
      location,
      ImageMetadata(
        fileSize: stats.size,
        width: width,
        height: height,
        camera: null,
      ),
      takenAt: takenAt,
      direction: direction,
      visible: true,
      parent: parent,
      isPhoto: true,
    );
  }

  static String _uniquePath(String dir, String baseName, String ext) {
    var path = p.join(dir, '$baseName$ext');
    var i = 1;
    while (File(path).existsSync()) {
      path = p.join(dir, '${baseName}_$i$ext');
      i++;
    }
    return path;
  }
}
