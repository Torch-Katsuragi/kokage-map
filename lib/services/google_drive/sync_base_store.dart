// 3-way マージのための base（最後に同期が成立した時点の写し）の置き場。
//
// Drive はただのファイル置き場なので、base は端末ごとにローカルで持つ:
//   <プロジェクト dir>/.sync/base/<相対パス>
// `.sync/` は同期対象から外し（scanLocalFiles）、レイヤツリーにも出さない（FolderNode.loadNodes）。
// 対象は `.gpkg` だけ（行単位マージができるのは GeoPackage だけ）。web は geodiff が無いので何もしない。
// 設計: docs/technical/drive-geodiff-sync.md
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
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

  static Future<void> removeBase(String localPath, String relativePath) async {
    final path = basePath(localPath, relativePath);
    try {
      if (await fs.exists(path)) await fs.delete(path);
    } catch (e) {
      AppLogger.debug('[SyncBase] base の削除に失敗: $relativePath - $e');
    }
  }
}
