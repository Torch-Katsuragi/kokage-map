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
import 'external_source.dart';

class ExternalLayerCache {
  ExternalLayerCache._();

  /// 印の表（キャッシュ gpkg の中。変換で書く gpkg からは落とす）
  static const markerTable = 'kokage_external_source';

  /// 読み方を変えたら上げる（古い読み方で作ったキャッシュを作り直させる）。
  /// 2: GDAL（ogr2ogr）で書く。座標系は元のまま
  static const formatVersion = 2;

  /// キャッシュの置き場（プロジェクトルートの `.kokage/cache/external`）。
  /// ルートが決まっていなければ元ファイルと同じ dir の `.kokage` の下
  static String cacheDirFor(String sourcePath) {
    final root = ProjectPathResolver.instance.rootPath ?? p.dirname(sourcePath);
    return p.join(root, GlobalFolderLocator.systemDirName, 'cache', 'external');
  }

  /// [sourcePath] のキャッシュ gpkg のパス
  static String cachePathFor(String sourcePath) =>
      p.join(cacheDirFor(sourcePath), '${stableHashHex(p.normalize(sourcePath), length: 20)}.gpkg');

  /// 元ファイル一式（[ExternalSource.files]）の印（名前・更新時刻・大きさ）。元が無ければ null
  static Future<String?> signatureOf(String sourcePath) async {
    if (!await fs.exists(sourcePath)) return null;
    final parts = <String>['v$formatVersion'];
    for (final path in await ExternalSource.files(sourcePath)) {
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

  /// [cache] の印の表の [key] の値。無い・読めなければ null
  static Future<String?> _marker(GeoPackageFile cache, String key) async {
    final path = cache.getAbsolutePath();
    if (path == null || !await fs.exists(path)) return null;
    try {
      final db = await cache.getDatabase();
      final rows = await db.rawQuery('SELECT value FROM $markerTable WHERE key = ?', [key]);
      return rows.firstOrNull?['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// [cache] に書いてある印。無い・読めなければ null
  static Future<String?> storedSignature(GeoPackageFile cache) => _marker(cache, 'signature');

  /// [cache] を作ったときのレイヤの割り当て（元の GDAL のレイヤ・型の分け方）。無ければ null
  static Future<ExternalSourcePlan?> storedPlan(GeoPackageFile cache) async =>
      ExternalSourcePlan.decodeLayers(await _marker(cache, 'layers'));

  static final Map<String, Future<bool>> _running = {};

  /// [cache] を [sourcePath] の今の中身に合わせる。作り直したら true。
  ///
  /// 同じキャッシュへの呼び出しは 1 本にまとめる（フォルダの読み直しが重なっても 2 度作らない）。
  /// 読めなければ投げる（キャッシュは消える）
  static Future<bool> ensure(GeoPackageFile cache, String sourcePath) {
    final key = cache.getAbsolutePath() ?? sourcePath;
    final running = _running[key];
    if (running != null) return running;
    final future = _ensure(cache, sourcePath).whenComplete(() {
      // ⚠ `=> _running.remove(key)` と書くと、取り除いた自分自身（Future）を待って止まる
      _running.remove(key);
    });
    _running[key] = future;
    return future;
  }

  static Future<bool> _ensure(GeoPackageFile cache, String sourcePath) async {
    final cachePath = cache.getAbsolutePath()!;
    final signature = await signatureOf(sourcePath);
    if (signature == null) throw StateError('元のファイルがありません: $sourcePath');
    if (await storedSignature(cache) == signature) return false;

    AppLogger.debug('[ExternalLayerCache] 作り直す: $sourcePath → $cachePath');
    await build(cachePath, sourcePath, signature: signature);
    return true;
  }

  /// [sourcePath] を GDAL（ogr2ogr）で [cachePath] のキャッシュ gpkg にする（あれば作り直す）。
  /// 座標系は元のまま。レイヤ名は GDAL のレイヤ名（型の混ざったレイヤは `<名前>_point` などに分ける）
  static Future<void> build(String cachePath, String sourcePath, {required String signature}) async {
    await discard(cachePath);
    await fs.createDirectory(p.dirname(cachePath));
    final plan = await ExternalSource.plan(sourcePath);
    if (plan.layers.isEmpty) throw StateError('形のあるレイヤがありません: ${p.basename(sourcePath)}');
    final gpkg = GeoPackageFile([p.basename(sourcePath)], absolutePath: cachePath);
    try {
      await ExternalSource.translate(sourcePath, cachePath, plan);
      final db = await gpkg.getDatabase();
      await db.execute('CREATE TABLE IF NOT EXISTS $markerTable (key TEXT PRIMARY KEY, value TEXT)');
      for (final (key, value) in [('signature', signature), ('source', sourcePath), ('layers', plan.encodeLayers())]) {
        await db.rawInsert('INSERT OR REPLACE INTO $markerTable (key, value) VALUES (?, ?)', [key, value]);
      }
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
