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
// 手元と Drive のファイルの列挙、パスの変換、Drive フォルダの解決、ダウンロード、並列実行を担当

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/fs/safe_path.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'google_drive_service.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';

/// Drive のフォルダ配下を丸ごと見たもの
class DriveTree {
  const DriveTree({required this.files, required this.folderMap});

  /// 同期対象のファイル（相対パス付き）
  final List<DriveFileEntry> files;

  /// フォルダ ID → 相対パス（根は空文字）
  final Map<String, String> folderMap;

  /// 根を除くフォルダの相対パス
  Iterable<String> get folderPaths => folderMap.values.where((v) => v.isNotEmpty);

  /// 相対パス → フォルダ ID（[SyncFileOperations.getDriveFolderIdForRelativeDir] のキャッシュの種）
  Map<String, String> folderIdsByPath() => {
        for (final e in folderMap.entries)
          if (e.value.isNotEmpty) e.value: e.key,
      };

  /// ファイル ID → エントリ
  Map<String, DriveFileEntry> byId() => {
        for (final e in files)
          if (e.file.id != null) e.file.id!: e,
      };
}

/// 手元の同期対象ファイル 1 件（[SyncFileOperations.listLocalSyncFiles]）
typedef LocalSyncEntry = ({String path, String relativePath});

/// 同期用ファイル操作ヘルパー
class SyncFileOperations {
  final GoogleDriveService driveService;

  /// 同期対象のファイルパターン
  static const List<String> syncPatterns = [
    '*.gpkg',
    // `.kmeta.json` は 2026-09-29 に `.qgs` へ移したので扱わない（旧版アプリが Drive に置いても落とさない）
    '*.qgs', // dir ごとの QGIS プロジェクト（2026-09-06〜。共有 dir を QGIS でも開けるように）
    '*.jpg',
    '*.jpeg',
    '*.png',
    '*.tiff',
    '*.tif',
    // 読み取り専用で開く形式（2026-10-09〜。[[external-formats]]）。shp は付属ファイルも一緒に運ぶ
    '*.shp',
    '*.shx',
    '*.dbf',
    '*.prj',
    '*.cpg',
    '*.qix',
    '*.sbn',
    '*.sbx',
    '*.shp.xml',
    '*.geojson',
    '*.json', // 点で始まる名前（旧 `.kmeta.json`）と点で始まるフォルダの中は [isHiddenPath] で外す
    '*.kml',
    '*.kmz',
    '*.csv',
  ];

  static const String _folderMime = 'application/vnd.google-apps.folder';

  SyncFileOperations({required this.driveService});

  // ========== パス ==========

  /// 相対パスを正規化（Drive側は / 区切り）
  String normalizeRelativePath(String path) {
    return path.replaceAll('\\', '/');
  }

  /// 相対パスからローカルパスを生成。[basePath] の外を指す相対パスは [UnsafePathException]
  String relativePathToLocalPath(String basePath, String relativePath) => resolveUnder(basePath, relativePath);

  /// ファイル名が同期パターンにマッチするか（大文字小文字は区別しない。`IMG.JPG` も同期する）。
  /// 点で始まる名前（`.kmeta.json` など）は対象外
  bool matchesSyncPattern(String fileName) {
    if (fileName.startsWith('.')) return false;
    final name = fileName.toLowerCase();
    for (final pattern in syncPatterns) {
      if (pattern.startsWith('*.')) {
        if (name.endsWith(pattern.substring(1))) return true;
      } else if (pattern == name) {
        return true;
      }
    }
    return false;
  }

  /// 同期しない相対パスか。点で始まるフォルダ（3-way マージの base を置く `.sync`、
  /// 外部形式のキャッシュなどアプリ用の `.kokage`）とその中、点で始まるファイル
  static bool isHiddenPath(String relativePath) =>
      relativePath.replaceAll('\\', '/').split('/').any((segment) => segment.startsWith('.') && segment != '.');

  // ========== 手元 ==========

  /// 手元の同期対象ファイルを列挙する（`.sync`・`.kokage` など点で始まるフォルダの中は見ない）
  Future<List<LocalSyncEntry>> listLocalSyncFiles(String localPath) async {
    final out = <LocalSyncEntry>[];
    final queue = <String>[localPath];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      for (final entry in await fs.list(dir)) {
        final relativePath = normalizeRelativePath(p.relative(entry.path, from: localPath));
        // 3-way マージの base やアプリ用のフォルダは同期しない（中も辿らない）
        if (isHiddenPath(relativePath)) continue;
        if (entry.isDirectory) {
          queue.add(entry.path);
        } else if (matchesSyncPattern(p.basename(entry.path))) {
          out.add((path: entry.path, relativePath: relativePath));
        }
      }
    }
    return out;
  }

  /// 手元の同期対象ファイルの、相対パス→更新日時
  Future<Map<String, DateTime>> scanLocalFiles(String localPath) async {
    final localFiles = <String, DateTime>{};
    for (final entry in await listLocalSyncFiles(localPath)) {
      final modified = await fs.lastModified(entry.path);
      if (modified == null) continue;
      localFiles[entry.relativePath] = modified;
    }
    return localFiles;
  }

  /// Drive にあるフォルダ（[folderPaths]）のうち、手元に無いものを作る。作った数を返す
  Future<int> ensureLocalDirs(String localPath, Iterable<String> folderPaths) async {
    var created = 0;
    for (final relativeFolderPath in folderPaths) {
      final dirPath = relativePathToLocalPath(localPath, relativeFolderPath);
      if (await fs.isDirectory(dirPath)) continue;
      await fs.createDirectory(dirPath);
      created++;
      AppLogger.debug('[SyncEngine] フォルダ作成: $relativeFolderPath');
    }
    return created;
  }

  /// Drive に無い（[keep] に無い）空のフォルダを手元から消す。深い階層から消すので連鎖して消える。
  /// `.sync`（3-way マージの base）・`.kokage` など点で始まるフォルダは触らない
  Future<void> removeEmptyLocalDirs(String localPath, Set<String> keep) async {
    if (!await fs.isDirectory(localPath)) return;
    final localDirs = await fs.listDirectoriesRecursive(localPath);
    localDirs.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final dir in localDirs) {
      final relativePath = normalizeRelativePath(p.relative(dir.path, from: localPath));
      if (isHiddenPath(relativePath)) continue;
      if (keep.contains(relativePath)) continue;
      if ((await fs.list(dir.path)).isEmpty) {
        await fs.delete(dir.path);
        AppLogger.debug('[SyncEngine] 空フォルダ削除: $relativePath');
      }
    }
  }

  /// Drive のファイルを落として手元の [localFilePath] を置き換える。
  ///
  /// この端末のリンク情報は、落とした `.qgs` で上書きしない。gpkg は開いている接続を閉じてから置き換え、
  /// 置き換えたあと一度開いて閉じる（[SyncBaseStore.settleAfterDownload]）。落とせなければ false
  Future<bool> downloadReplacing(String fileId, String localFilePath) async {
    final keepLink = await KMetaService.instance.linkBeforeReplace(localFilePath);
    await SyncBaseStore.releaseBeforeOverwrite(localFilePath);
    if (!await driveService.downloadFile(fileId, localFilePath)) return false;
    await SyncBaseStore.settleAfterDownload(localFilePath);
    await KMetaService.instance.afterReplace(localFilePath, keepLink);
    return true;
  }

  // ========== Drive ==========

  /// Driveの相対フォルダパスに対応するフォルダIDを取得/作成
  ///
  /// [cache] は相対パス→ID。[DriveTree.folderIdsByPath] で種を入れておけば、あるフォルダは Drive に聞かない
  Future<String?> getDriveFolderIdForRelativeDir(
    String rootFolderId,
    String relativeDir,
    Map<String, String> cache,
  ) async {
    if (relativeDir.isEmpty || relativeDir == '.') {
      return rootFolderId;
    }

    final normalized = normalizeRelativePath(relativeDir);
    final cached = cache[normalized];
    if (cached != null) return cached;

    String currentId = rootFolderId;
    String currentPath = '';

    for (final segment in p.posix.split(normalized)) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final known = cache[currentPath];
      if (known != null) {
        currentId = known;
        continue;
      }

      final created = await driveService.getOrCreateSubFolder(currentId, segment);
      if (created == null || created.id == null) {
        return null;
      }
      currentId = created.id!;
      cache[currentPath] = currentId;
    }

    return currentId;
  }

  /// Driveフォルダ配下のファイル一覧とフォルダマップを一括取得
  /// 1フォルダにつき一覧 1 回（listFiles）でフォルダ/ファイル両方を取得し、サブフォルダは並列にたどる
  Future<DriveTree> listDriveTree(String rootFolderId) async {
    final folderMap = <String, String>{rootFolderId: ''};
    final files = await _listDriveFolder(rootFolderId, '', folderMap);
    return DriveTree(files: files, folderMap: folderMap);
  }

  /// [folderId] 配下のファイル（直下のもの → サブフォルダの順）。見つけたフォルダは [folderMap] に足す
  Future<List<DriveFileEntry>> _listDriveFolder(
    String folderId,
    String currentPath,
    Map<String, String> folderMap,
  ) async {
    final entries = <DriveFileEntry>[];
    final subFolders = <Future<List<DriveFileEntry>>>[];
    for (final item in await driveService.listFiles(folderId)) {
      final name = item.name ?? '';
      if (name.isEmpty) continue;
      final path = currentPath.isEmpty ? name : '$currentPath/$name';
      // 手元のパスにできない名前（`..`・`/` 入りなど）と、点で始まるもの（アプリが手元で使う `.sync`・`.kokage`）は Drive から取らない
      if (!isSafePathSegment(name) || isHiddenPath(path)) {
        AppLogger.log('[SyncEngine] Drive の項目を飛ばした（手元に置けない名前）: ${item.id} "$name"');
        continue;
      }
      if (item.mimeType == _folderMime) {
        folderMap[item.id!] = path;
        subFolders.add(_listDriveFolder(item.id!, path, folderMap));
      } else if (matchesSyncPattern(name)) {
        entries.add(DriveFileEntry(file: item, relativePath: normalizeRelativePath(path)));
      }
    }
    for (final sub in await Future.wait(subFolders)) {
      entries.addAll(sub);
    }
    return entries;
  }

  // ========== 並列実行 ==========

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

      final future = task().then(results.add);
      active.add(future);
      // ignore: unawaited_futures
      future.whenComplete(() => active.remove(future));
    }

    await Future.wait(active);
    return results;
  }
}

