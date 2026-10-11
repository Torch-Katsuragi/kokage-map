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
// 読み取り専用レイヤを gpkg へ変換する（置き換え）／自分のフォルダへ gpkg として複製する
// 設計は docs/technical/external-formats.md#変換（ExternalLayerConverter）

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/geopackage/geopackage_connection.dart';
import '../../models/geopackage/geopackage_file.dart';
import '../../models/nodes/external_layer_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import '../layer_drawer_service.dart';
import 'external_layer_cache.dart';
import 'external_source.dart';

/// 変換の結果
enum ExternalConvertOutcome {
  /// gpkg を書いて元を消した
  converted,

  /// 別のフォルダへ gpkg を書いた（元は残す）
  copied,

  /// 読み取り専用の Drive フォルダなので変換しない（複製を勧める）
  readOnlyFolder,

  /// 元のファイルを消せなかった。書いた gpkg は消して元のまま（複製を勧める）
  deleteFailed,
}

class ExternalConvertResult {
  const ExternalConvertResult(this.outcome, {this.gpkgPath, this.leftovers = const []});

  final ExternalConvertOutcome outcome;

  /// 書いた gpkg（[ExternalConvertOutcome.converted] / [ExternalConvertOutcome.copied]）
  final String? gpkgPath;

  /// 消せずに残った付属ファイル（元の本体は消えている）
  final List<String> leftovers;
}

/// 書いた gpkg が元と食い違った（書いた gpkg は消してある）
class ExternalConvertVerifyException implements Exception {
  const ExternalConvertVerifyException(this.detail);
  final String detail;
  @override
  String toString() => 'ExternalConvertVerifyException: $detail';
}

class ExternalLayerConverter {
  ExternalLayerConverter._();

  /// [dir] に `<stem>.gpkg` が無ければそれ、あれば `<stem>_1.gpkg` …（既存の gpkg には混ぜない）
  static Future<String> uniqueGpkgPath(String dir, String stem) async {
    var candidate = p.join(dir, '$stem.gpkg');
    for (var i = 1; await fs.exists(candidate); i++) {
      candidate = p.join(dir, '${stem}_$i.gpkg');
    }
    return candidate;
  }

  /// 置き換えの変換ができない場所か（読み取り専用の Drive フォルダ）
  static bool isInReadOnlyFolder(ExternalLayerNode node) => LayerDrawerService.findDriveRoot(node)?.isReadOnly ?? false;

  /// [node] を同じ dir の gpkg に置き換える。
  ///
  /// 1. キャッシュ gpkg を `<元の名前>.gpkg` に複製し、印の表を落とす
  /// 2. 開き直して、件数（元と書いた gpkg の両方を GDAL で数える）・ジオメトリ型・列名が一致するか確かめる（違えば書いた gpkg を消して
  ///    [ExternalConvertVerifyException]）
  /// 3. 元のファイル一式を消す（本体を消せなければ書いた gpkg を消して [ExternalConvertOutcome.deleteFailed]）
  /// 4. フォルダ設定の鍵（可視性・スタイル・View）を新しい gpkg へ移し、親を読み直す
  static Future<ExternalConvertResult> convert(ExternalLayerNode node) async {
    if (isInReadOnlyFolder(node)) return const ExternalConvertResult(ExternalConvertOutcome.readOnlyFolder);

    final source = node.sourcePath;
    final target = await uniqueGpkgPath(p.dirname(source), p.basenameWithoutExtension(source));
    await _writeVerified(node, target);

    // 本体を先に消す。消せなければ何も消さずに戻す（両方見えるだけの状態も作らない）
    final files = await node.sourceFiles();
    try {
      await fs.delete(files.first);
    } catch (e) {
      AppLogger.debug('[ExternalLayerConverter] 元を消せない: ${files.first} - $e');
      await _deleteQuietly(target);
      return const ExternalConvertResult(ExternalConvertOutcome.deleteFailed);
    }
    final leftovers = <String>[];
    for (final sidecar in files.skip(1)) {
      try {
        await fs.delete(sidecar);
      } catch (e) {
        AppLogger.debug('[ExternalLayerConverter] 付属ファイルを消せない: $sidecar - $e');
        leftovers.add(sidecar);
      }
    }

    final folder = node.parent;
    if (folder is FolderNode) {
      final folderPath = folder.getAbsoluteFilePath();
      if (folderPath != null) {
        await KMetaService.instance.renameGeoPackageKeys(folderPath, oldName: node.name, newName: p.basename(target));
        folder.invalidateMetaCache();
      }
    }
    await ExternalLayerCache.discard(node.geoPackageFile.getAbsolutePath()!);
    if (folder is FolderNode) await folder.updateChildren();
    return ExternalConvertResult(ExternalConvertOutcome.converted, gpkgPath: target, leftovers: leftovers);
  }

  /// [node] を [targetFolder] に gpkg として複製する（元は残す。読み取り専用の場所から編集用に持ち出す）
  static Future<ExternalConvertResult> copyAsGeoPackage(ExternalLayerNode node, FolderNode targetFolder) async {
    final dir = targetFolder.getAbsoluteFilePath();
    if (dir == null) throw StateError('複製先のフォルダのパスが分かりません');
    final target = await uniqueGpkgPath(dir, p.basenameWithoutExtension(node.sourcePath));
    await _writeVerified(node, target);
    await targetFolder.updateChildren();
    return ExternalConvertResult(ExternalConvertOutcome.copied, gpkgPath: target);
  }

  /// キャッシュを [target] に複製して印の表を落とし、元と突き合わせる。食い違えば [target] を消して投げる
  static Future<void> _writeVerified(ExternalLayerNode node, String target) async {
    final cache = node.geoPackageFile;
    final cachePath = cache.getAbsolutePath()!;
    await ExternalLayerCache.ensure(cache, node.sourcePath);
    // 開いている接続を閉じてから写す（書きかけを残さない）
    await GeoPackageConnection.closeAllFor(cachePath);

    await fs.writeAsBytes(target, await fs.readAsBytes(cachePath));
    final out = GeoPackageFile([p.basename(target)], absolutePath: target);
    try {
      final db = await out.getDatabase();
      await db.execute('DROP TABLE IF EXISTS ${ExternalLayerCache.markerTable}');
      await out.dispose();
      await _verify(node, cache, target);
    } catch (e) {
      await out.dispose();
      await _deleteQuietly(target);
      rethrow;
    }
  }

  /// [target] を確かめる: 元を GDAL で読み直した件数（`ogrinfo`）と、書いた gpkg を GDAL で読んだ件数をレイヤごとに比べる。
  /// ジオメトリ型（アプリの 3 種）・列名（キャッシュと同じ）・印の表が無いことも見る
  static Future<void> _verify(ExternalLayerNode node, GeoPackageFile cache, String target) async {
    final plan = await ExternalSource.plan(node.sourcePath);
    final info = await ExternalGdal.instance.vectorInfo(target, args: const ['-so']);
    final counts = {
      for (final l in ((info['layers'] as List?) ?? const []).cast<Map<String, dynamic>>())
        l['name'] as String: (l['featureCount'] as num?)?.toInt() ?? -1,
    };
    counts.remove(ExternalLayerCache.markerTable);
    // Android の SQLite は開いた DB に `android_metadata` 表を足し、GDAL はそれも表として並べる（2026-10-11 Pixel 9 で
    // 変換が必ず照合で止まっていた）。アプリが開けばまた足されるので、消さずに数えないだけにする
    counts.remove('android_metadata');
    final expected = [for (final l in plan.layers) l.name];
    if (counts.length != expected.length || !counts.keys.toSet().containsAll(expected)) {
      throw ExternalConvertVerifyException('レイヤが違う: ${counts.keys.toList()} ≠ $expected');
    }
    final written = GeoPackageFile([p.basename(target)], absolutePath: target);
    try {
      final db = await written.getDatabase();
      final marker = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${ExternalLayerCache.markerTable}'",
      );
      if (marker.isNotEmpty) throw const ExternalConvertVerifyException('印の表が残っている');
      for (final layer in plan.layers) {
        final name = layer.name;
        if (counts[name] != layer.featureCount) {
          throw ExternalConvertVerifyException('$name の件数が違う: ${counts[name]} ≠ ${layer.featureCount}');
        }
        final type = await written.getGeometryType(name);
        if (type != layer.geometryType) {
          throw ExternalConvertVerifyException('$name の形の種類が違う: $type ≠ ${layer.geometryType}');
        }
        final columns = await written.getColumnNames(name, getAll: true, skipPrimaryKey: true);
        final cacheColumns = await cache.getColumnNames(name, getAll: true, skipPrimaryKey: true);
        if (columns.join('\u0000') != cacheColumns.join('\u0000')) {
          throw ExternalConvertVerifyException('$name の列が違う: $columns ≠ $cacheColumns');
        }
      }
    } finally {
      await written.dispose();
      await GeoPackageConnection.closeAllFor(cache.getAbsolutePath()!);
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    await GeoPackageConnection.closeAllFor(path);
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      try {
        if (await fs.exists('$path$suffix')) await fs.delete('$path$suffix');
      } catch (e) {
        AppLogger.debug('[ExternalLayerConverter] 消せない: $path$suffix - $e');
      }
    }
    await GeoPackageConnection.discardWebCopy(path);
  }
}
