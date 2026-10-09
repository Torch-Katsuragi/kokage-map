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
// 読み取り専用レイヤの裏の「読み込み済み gpkg」（キャッシュ）
// 設計は docs/technical/external-formats.md#ノード
//
// 置き場所は `<プロジェクトルート>/.kokage/cache/external/<元のパスの hash>.gpkg`。
// 印（元ファイル一式の更新時刻と大きさ）は中の `kokage_external_source` 表に持ち、変わっていたら作り直す。
// キャッシュは都合の印で、真実源ではない（消しても次に開いたときに作り直すだけ）

import 'dart:async';

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/path_resolver.dart';
import '../../models/geopackage/geopackage_connection.dart';
import '../../models/geopackage/geopackage_file.dart';
import '../../utils/app_logger.dart';
import '../../utils/stable_hash.dart';
import '../global_folder_locator.dart';
import 'external_dataset.dart';
import 'external_dataset_writer.dart';
import 'external_readers.dart';

class ExternalLayerCache {
  ExternalLayerCache._();

  /// 印の表（キャッシュ gpkg の中。変換で書く gpkg からは落とす）
  static const markerTable = 'kokage_external_source';

  /// 読み方を変えたら上げる（古い読み方で作ったキャッシュを作り直させる）
  static const formatVersion = 1;

  /// キャッシュの置き場（プロジェクトルートの `.kokage/cache/external`）。
  /// ルートが決まっていなければ元ファイルと同じ dir の `.kokage` の下
  static String cacheDirFor(String sourcePath) {
    final root = ProjectPathResolver.instance.rootPath ?? p.dirname(sourcePath);
    return p.join(root, GlobalFolderLocator.systemDirName, 'cache', 'external');
  }

  /// [sourcePath] のキャッシュ gpkg のパス
  static String cachePathFor(String sourcePath) =>
      p.join(cacheDirFor(sourcePath), '${stableHashHex(p.normalize(sourcePath), length: 20)}.gpkg');

  /// 元ファイル一式の印（名前・更新時刻・大きさ）。元が無ければ null
  static Future<String?> signatureOf(String sourcePath, ExternalReader reader) async {
    final paths = [sourcePath, ...await existingSidecars(sourcePath, reader)];
    final parts = <String>['v$formatVersion'];
    for (final path in paths) {
      final modified = await fs.lastModified(path);
      final size = await fs.length(path);
      if (modified == null || size == null) {
        if (path == sourcePath) return null;
        continue;
      }
      parts.add('${p.basename(path).toLowerCase()}|${modified.millisecondsSinceEpoch}|$size');
    }
    return parts.join(';');
  }

  /// [cache] に書いてある印。無い・読めなければ null
  static Future<String?> storedSignature(GeoPackageFile cache) async {
    final path = cache.getAbsolutePath();
    if (path == null || !await fs.exists(path)) return null;
    try {
      final db = await cache.getDatabase();
      final rows = await db.rawQuery("SELECT value FROM $markerTable WHERE key = 'signature'");
      return rows.firstOrNull?['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  static final Map<String, Future<bool>> _running = {};

  /// [cache] を [sourcePath] の今の中身に合わせる。作り直したら true。
  ///
  /// 同じキャッシュへの呼び出しは 1 本にまとめる（フォルダの読み直しが重なっても 2 度作らない）。
  /// 読めなければ投げる（キャッシュは消える）
  static Future<bool> ensure(GeoPackageFile cache, String sourcePath, ExternalReader reader) {
    final key = cache.getAbsolutePath() ?? sourcePath;
    final running = _running[key];
    if (running != null) return running;
    final future = _ensure(cache, sourcePath, reader).whenComplete(() {
      // ⚠ `=> _running.remove(key)` と書くと、取り除いた自分自身（Future）を待って止まる
      _running.remove(key);
    });
    _running[key] = future;
    return future;
  }

  static Future<bool> _ensure(GeoPackageFile cache, String sourcePath, ExternalReader reader) async {
    final cachePath = cache.getAbsolutePath()!;
    final signature = await signatureOf(sourcePath, reader);
    if (signature == null) throw StateError('元のファイルがありません: $sourcePath');
    if (await storedSignature(cache) == signature) return false;

    AppLogger.debug('[ExternalLayerCache] 作り直す: $sourcePath → $cachePath');
    final datasets = await reader.read(sourcePath);
    await build(cachePath, p.basename(sourcePath), datasets, signature: signature, sourcePath: sourcePath);
    return true;
  }

  /// [datasets] から [cachePath] にキャッシュ gpkg を作る（あれば作り直す）
  static Future<void> build(
    String cachePath,
    String sourceName,
    List<ExternalDataset> datasets, {
    required String signature,
    required String sourcePath,
  }) async {
    await discard(cachePath);
    await fs.createDirectory(p.dirname(cachePath));
    final gpkg = GeoPackageFile([sourceName], absolutePath: cachePath);
    try {
      if (!await gpkg.createEmptyDatabase()) throw StateError('キャッシュを作れません: $cachePath');
      for (final dataset in datasets) {
        await writeExternalDataset(gpkg, dataset);
      }
      final db = await gpkg.getDatabase();
      await db.execute('CREATE TABLE IF NOT EXISTS $markerTable (key TEXT PRIMARY KEY, value TEXT)');
      await db.rawInsert('INSERT OR REPLACE INTO $markerTable (key, value) VALUES (?, ?)', ['signature', signature]);
      await db.rawInsert('INSERT OR REPLACE INTO $markerTable (key, value) VALUES (?, ?)', ['source', sourcePath]);
      await gpkg.dispose();
    } catch (e) {
      await gpkg.dispose();
      await discard(cachePath);
      rethrow;
    }
  }

  /// キャッシュを消す（開いている接続は閉じる。次に開いたときに作り直す）
  static Future<void> discard(String cachePath) async {
    await GeoPackageConnection.closeAllFor(cachePath);
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final path = '$cachePath$suffix';
      try {
        if (await fs.exists(path)) await fs.delete(path);
      } catch (e) {
        AppLogger.debug('[ExternalLayerCache] 消せない: $path - $e');
      }
    }
    await GeoPackageConnection.discardWebCopy(cachePath);
  }
}
