// 3-way マージのための base（最後に同期が成立した時点の写し）の置き場。
//
// Drive はただのファイル置き場なので、base は端末ごとにローカルで持つ:
//   <プロジェクト dir>/.sync/base/<相対パス>
// `.sync/` は同期対象から外し（scanLocalFiles）、レイヤツリーにも出さない（FolderNode.loadNodes）。
// 対象は `.gpkg` だけ（行単位マージができるのは GeoPackage だけ）。web は geodiff が無いので何もしない。
// 設計: docs/technical/drive-geodiff-sync.md
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/geopackage/geopackage_connection.dart';
import '../../utils/app_logger.dart';
import '../geodiff/geodiff.dart';

abstract final class SyncBaseStore {
  /// プロジェクト dir 直下の作業 dir 名
  static const dirName = '.sync';

  static String _syncDir(String localPath) => p.join(localPath, dirName);

  /// base の置き場（dir）
  static String baseDir(String localPath) => p.join(_syncDir(localPath), 'base');

  /// [relativePath] の base の絶対パス
  static String basePath(String localPath, String relativePath) =>
      p.join(baseDir(localPath), p.joinAll(p.posix.split(relativePath)));

  /// リモートを落とす一時ファイル
  static String tmpPath(String localPath, String relativePath) =>
      p.join(_syncDir(localPath), 'tmp', '${p.posix.basename(relativePath)}.remote');

  /// 同期対象から外す相対パスか（`.sync` 配下）
  static bool isInside(String relativePath) {
    final n = relativePath.replaceAll('\\', '/');
    return n == dirName || n.startsWith('$dirName/');
  }

  /// 行単位マージの対象か
  static bool isGpkg(String relativePath) => relativePath.toLowerCase().endsWith('.gpkg');

  /// この端末で base を持てるか（geodiff が使えて実ファイルがある）
  static bool get isAvailable => Geodiff.isSupported && fs.hasRealPaths;

  static Future<bool> hasBase(String localPath, String relativePath) async {
    if (!isAvailable || !isGpkg(relativePath)) return false;
    return fs.exists(basePath(localPath, relativePath));
  }

  /// いまのローカルファイルを base として写す（同期が成立した直後に呼ぶ）。
  /// gpkg 以外・web では何もしない。失敗しても同期自体は止めない（false を返すだけ）。
  static Future<bool> saveBase(String localPath, String relativePath, {Geodiff? geodiff}) async {
    if (!isAvailable || !isGpkg(relativePath)) return false;
    final src = p.join(localPath, p.joinAll(p.posix.split(relativePath)));
    final dst = basePath(localPath, relativePath);
    try {
      if (!await fs.exists(src)) return false;
      await fs.createDirectory(p.dirname(dst));
      // geodiff の SQLite が読む前に、アプリの接続を閉じる（別の SQLite 同士で同じファイルを開かない）
      await GeoPackageConnection.closeAllFor(src);
      // sqlite のバックアップ API で写す（書き込み途中でも一貫した写しになる）
      final g = geodiff ?? Geodiff();
      try {
        final rc = g.makeCopySqlite(src, dst);
        if (rc != GeodiffResult.success) {
          AppLogger.debug('[SyncBase] base の写しに失敗: $relativePath rc=$rc ${g.lastError}');
          return false;
        }
      } finally {
        if (geodiff == null) g.dispose();
      }
      return true;
    } catch (e) {
      AppLogger.debug('[SyncBase] base の写しで例外: $relativePath - $e');
      return false;
    }
  }

  /// Drive から gpkg を上書きダウンロードする前に呼ぶ。開いている接続を閉じる
  /// （開いたまま下で中身が入れ替わるのを避ける）。gpkg 以外・web では何もしない。
  static Future<void> releaseBeforeOverwrite(String absPath) async {
    if (!fs.hasRealPaths || !isGpkg(absPath)) return;
    await GeoPackageConnection.closeAllFor(absPath);
  }

  /// Drive から落とした gpkg を、同期済みと記録する前にアプリの SQLite で一度開いて閉じる。
  ///
  /// Android の SQLite は開いた gpkg に `android_metadata` 表を足す。落とした直後に同期済みと記録すると、
  /// 最初にレイヤを開いた時点で更新時刻が進み、地物は同じなのに次の同期で 1 回アップロードしていた。
  /// 記録の前に足させておけば、更新時刻は記録より前になる。Android 以外では何もしない。
  static Future<void> settleAfterDownload(String absPath) async {
    if (defaultTargetPlatform != TargetPlatform.android || !fs.hasRealPaths || !isGpkg(absPath)) return;
    try {
      final db = await openDatabase(absPath, singleInstance: false);
      await db.close();
    } catch (e) {
      AppLogger.debug('[SyncBase] 落とした gpkg を開けなかった: $absPath - $e');
    }
  }

  static Future<void> removeBase(String localPath, String relativePath) async {
    final path = basePath(localPath, relativePath);
    try {
      if (await fs.exists(path)) await fs.delete(path);
    } catch (e) {
      AppLogger.debug('[SyncBase] base の削除に失敗: $relativePath - $e');
    }
  }
}
