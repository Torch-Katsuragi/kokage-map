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
// Root Maps: 同期ファイル操作ヘルパー
// ファイル収集、パス正規化、Driveフォルダ解決、並列実行を担当

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import 'google_drive_service.dart';
import 'sync_engine.dart';

/// 同期用ファイル操作ヘルパー
class SyncFileOperations {
  final GoogleDriveService driveService;

  /// 同期対象のファイルパターン
  static const List<String> syncPatterns = [
    '*.gpkg',
    '*.kmeta.json',
    '*.qgs', // dir ごとの QGIS プロジェクト（2026-09-06〜。共有 dir を QGIS でも開けるように）
    '*.jpg',
    '*.jpeg',
    '*.png',
    '*.tiff',
    '*.tif',
  ];

  SyncFileOperations({required this.driveService});

  /// 同期対象ファイルを収集
  Future<List<LocalSyncFile>> collectSyncFiles(String projectPath) async {
    final files = <LocalSyncFile>[];

    for (final entry in await fs.listRecursive(projectPath)) {
      final fileName = p.basename(entry.path);
      final relativePath = normalizeRelativePath(
        p.relative(entry.path, from: projectPath),
      );

      if (!matchesSyncPattern(fileName)) continue;
      if (fileName == '.ksync-state.json') continue;

      // サイズはここで1回だけ聞いて持ち回る（web は都度問い合わせが高い）
      final size = await fs.length(entry.path) ?? 0;
      files.add(
        LocalSyncFile(
          path: entry.path,
          relativePath: relativePath,
          size: size,
        ),
      );
      AppLogger.debug('[SyncEngine] 同期対象: $relativePath');
    }

    return files;
  }

  /// 相対パスを正規化（Drive側は / 区切り）
  String normalizeRelativePath(String path) {
    return path.replaceAll('\\', '/');
  }

  /// 相対パスからローカルパスを生成
  String relativePathToLocalPath(String basePath, String relativePath) {
    final segments = p.posix.split(relativePath);
    return p.joinAll([basePath, ...segments]);
  }

  /// Driveの相対フォルダパスに対応するフォルダIDを取得/作成
  Future<String?> getDriveFolderIdForRelativeDir(
    String rootFolderId,
    String relativeDir,
    Map<String, String> cache,
  ) async {
    if (relativeDir.isEmpty || relativeDir == '.') {
      return rootFolderId;
    }

    final normalized = normalizeRelativePath(relativeDir);
    if (cache.containsKey(normalized)) {
      return cache[normalized];
    }

    String currentId = rootFolderId;
    final segments = p.posix.split(normalized);
    String currentPath = '';

    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      if (cache.containsKey(currentPath)) {
        currentId = cache[currentPath]!;
        continue;
      }

      final created = await driveService.getOrCreateSubFolder(
        currentId,
        segment,
      );
      if (created == null || created.id == null) {
        return null;
      }
      currentId = created.id!;
      cache[currentPath] = currentId;
    }

    return currentId;
  }

  /// Driveフォルダ配下のファイル一覧とフォルダマップを一括取得
  /// 1フォルダにつきAPI 1回（listFiles）でフォルダ/ファイル両方を取得
  Future<({List<DriveFileEntry> files, Map<String, String> folderMap})>
      listDriveFilesWithFolders(
    String rootFolderId, {
    String currentPath = '',
    Map<String, String>? folderMap,
  }) async {
    final entries = <DriveFileEntry>[];
    final map = folderMap ?? <String, String>{};

    if (currentPath.isEmpty) {
      map[rootFolderId] = '';
    }

    final allItems = await driveService.listFiles(rootFolderId);

    final folders = <drive.File>[];
    for (final item in allItems) {
      if (item.mimeType == 'application/vnd.google-apps.folder') {
        folders.add(item);
      } else {
        final name = item.name ?? '';
        if (name.isEmpty) continue;
        if (!matchesSyncPattern(name)) continue;
        final relativePath = currentPath.isEmpty ? name : '$currentPath/$name';
        entries.add(DriveFileEntry(
          file: item,
          relativePath: normalizeRelativePath(relativePath),
        ));
      }
    }

    final futures =
        <Future<({List<DriveFileEntry> files, Map<String, String> folderMap})>>[];
    for (final folder in folders) {
      final folderName = folder.name ?? '';
      if (folderName.isEmpty) continue;
      final nextPath =
          currentPath.isEmpty ? folderName : '$currentPath/$folderName';
      map[folder.id!] = nextPath;
      futures.add(listDriveFilesWithFolders(
        folder.id!,
        currentPath: nextPath,
        folderMap: map,
      ));
    }
    final results = await Future.wait(futures);
    for (final sub in results) {
      entries.addAll(sub.files);
    }

    return (files: entries, folderMap: map);
  }

  /// ローカルフォルダ内のファイルを再帰スキャンし、相対パス→更新日時のマップを返す
  Future<Map<String, DateTime>> scanLocalFiles(String localPath) async {
    final localFiles = <String, DateTime>{};
    if (!await fs.isDirectory(localPath)) return localFiles;

    for (final entry in await fs.listRecursive(localPath)) {
      final fileName = p.basename(entry.path);
      if (fileName == kMetaFileName) continue;
      if (!matchesSyncPattern(fileName)) continue;

      final modified = await fs.lastModified(entry.path);
      if (modified == null) continue;
      final relativePath = normalizeRelativePath(
        p.relative(entry.path, from: localPath),
      );
      localFiles[relativePath] = modified;
    }
    return localFiles;
  }

  /// Driveフォルダ配下のファイルを再帰的に取得
  Future<List<DriveFileEntry>> listDriveFilesRecursive(
    String folderId,
  ) async {
    final result = await listDriveFilesWithFolders(folderId);
    return result.files;
  }

  /// ファイル名が同期パターンにマッチするか
  bool matchesSyncPattern(String fileName) {
    for (final pattern in syncPatterns) {
      if (pattern.startsWith('*.')) {
        final extension = pattern.substring(1);
        if (fileName.endsWith(extension)) return true;
      } else if (pattern == fileName) {
        return true;
      }
    }
    return false;
  }

  /// 並列数を制限して非同期タスクを実行
  static Future<List<T>> runParallel<T>(
    Iterable<Future<T> Function()> tasks, {
    int maxConcurrency = 3,
  }) async {
    final results = <T>[];
    final active = <Future<void>>[];

    for (final task in tasks) {
      if (active.length >= maxConcurrency) {
        await Future.any(active);
      }

      final future = task().then((result) {
        results.add(result);
      });
      active.add(future);
      // ignore: unawaited_futures
      future.whenComplete(() => active.remove(future));
    }

    await Future.wait(active);
    return results;
  }
}
