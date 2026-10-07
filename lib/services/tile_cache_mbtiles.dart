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
/// MBTilesを使用したタイルキャッシュ管理
/// プロバイダーごとに独立したMBTilesファイルを管理
/// 圏外でも [BaseMapService] がここから読む（QGIS などでもそのまま開ける形式）
library;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:root_maps/utils/app_logger.dart';
import 'package:sqflite/sqflite.dart';

/// 保存待ちタイル
typedef _PendingTile = ({String providerId, int z, int x, int tileRow, Uint8List data});

/// MBTiles タイルキャッシュ管理
/// プロバイダーごとに独立した .mbtiles ファイルを管理
class TileCacheMBTiles {
  /// これより小さいタイルは壊れているとみなす（保存しない・読んだら消す）
  static const int minTileBytes = 100;

  /// 壊れていない（小さすぎない）タイルか
  static bool isPlausibleTile(Uint8List data) => data.length >= minTileBytes;

  static const _whereTile = 'zoom_level = ? AND tile_column = ? AND tile_row = ?';
  static final _mbtilesName = RegExp(r'\.mbtiles(-wal|-shm|-journal)?$');

  String? _cacheDirectory;

  /// プロバイダーID → DB接続。開いている途中のものも同じ Future を返す（同時に来た要求で二重に開かない）
  final Map<String, Future<Database>> _databases = {};

  /// `.mbtiles` があるプロバイダ。初期化で 1 回だけ一覧を取り、作る・消すときに足し引きする
  /// （キャッシュの無いプロバイダを引くたびに、UI isolate で同期のファイル確認をしていた）
  final Set<String> _existing = {};

  // バッチ書き込み用。キーは [_key]（同じタイルは後から来たもので上書き）
  Map<String, _PendingTile> _writeQueue = {};

  /// 書き込み中のバッチ。書き終わるまでは読み出しもここから返す（書いている間に引くと DB に無く、取り直しに行っていた）
  Map<String, _PendingTile> _flushing = const {};
  Timer? _batchTimer;
  bool _isFlushing = false;

  static String _key(String providerId, int z, int x, int y) => '$providerId/$z/$x/$y';

  /// MBTiles のタイル座標は TMS 方式（左下原点）。Web 地図の XYZ 方式（左上原点）から変換
  static int _tmsRow(int z, int y) => (1 << z) - 1 - y;

  String _filePath(String providerId, [String suffix = '']) =>
      path.join(_cacheDirectory!, '$providerId.mbtiles$suffix');

  /// 初期化（キャッシュディレクトリの設定）
  Future<void> initialize(String cacheDirectory) async {
    _cacheDirectory = cacheDirectory;
    final dir = Directory(cacheDirectory);
    if (!await dir.exists()) await dir.create(recursive: true);
    _existing
      ..clear()
      ..addAll([
        await for (final e in dir.list())
          if (e is File && e.path.endsWith('.mbtiles')) path.basenameWithoutExtension(e.path),
      ]);
  }

  /// 指定プロバイダーのDB接続を取得（なければ作成）
  Future<Database> _db(String providerId) {
    final opened = _databases[providerId];
    if (opened != null) return opened;
    _existing.add(providerId);
    final future = openDatabase(
      _filePath(providerId),
      version: 1,
      onCreate: (db, version) async => _onCreateMBTiles(db, providerId),
      onOpen: _onOpenMBTiles,
    );
    _databases[providerId] = future;
    // 開けなかったら次の要求で開き直す
    unawaited(future.then<void>((_) {}, onError: (Object _) {
      if (identical(_databases[providerId], future)) _databases.remove(providerId);
    }));
    return future;
  }

  /// MBTilesデータベース作成時の処理
  Future<void> _onCreateMBTiles(Database db, String providerId) async {
    // MBTiles仕様: metadataテーブル
    await db.execute('''
      CREATE TABLE metadata (
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        UNIQUE (name)
      )
    ''');

    // MBTiles仕様: tilesテーブル
    await db.execute('''
      CREATE TABLE tiles (
        zoom_level INTEGER NOT NULL,
        tile_column INTEGER NOT NULL,
        tile_row INTEGER NOT NULL,
        tile_data BLOB NOT NULL,
        PRIMARY KEY (zoom_level, tile_column, tile_row)
      )
    ''');

    // インデックス（検索高速化）
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_tiles
      ON tiles(zoom_level, tile_column, tile_row)
    ''');

    // メタデータ登録（MBTiles仕様必須項目）
    const metadata = {
      'format': 'png',
      'type': 'overlay',
      'bounds': '-180,-85.051129,180,85.051129',
      'minzoom': '0',
      'maxzoom': '22',
    };
    await db.insert('metadata', {'name': 'name', 'value': providerId});
    for (final MapEntry(:key, :value) in metadata.entries) {
      await db.insert('metadata', {'name': key, 'value': value});
    }
    await db.insert('metadata', {'name': 'description', 'value': 'Cached tiles for $providerId'});
  }

  /// MBTilesデータベースオープン時の処理
  Future<void> _onOpenMBTiles(Database db) async {
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.rawQuery('PRAGMA synchronous = NORMAL');
  }

  /// タイルを保存（バッチキューに追加）
  Future<void> saveTile({
    required String providerId,
    required int z,
    required int x,
    required int y,
    required Uint8List data,
  }) async {
    if (_cacheDirectory == null) return;

    _writeQueue[_key(providerId, z, x, y)] =
        (providerId: providerId, z: z, x: x, tileRow: _tmsRow(z, y), data: data);

    _batchTimer?.cancel();
    // 上限チェック: 一定数溜まったら即フラッシュ（飢餓状態防止）
    if (_writeQueue.length >= 50) {
      await _flushBatch();
      return;
    }
    // 少量ならDebounceで待つ（100ms後にまとめて書き込み）
    _batchTimer = Timer(const Duration(milliseconds: 100), _flushBatch);
  }

  /// バッチ書き込み実行（キューに溜まったタイルを一括保存）
  Future<void> _flushBatch() async {
    if (_isFlushing || _writeQueue.isEmpty || _cacheDirectory == null) return;

    _isFlushing = true;
    final batch = _flushing = _writeQueue;
    _writeQueue = {};

    try {
      // プロバイダーごとにグループ化
      final grouped = <String, List<_PendingTile>>{};
      for (final tile in batch.values) {
        (grouped[tile.providerId] ??= []).add(tile);
      }

      // プロバイダーごとにトランザクション書き込み
      for (final MapEntry(key: providerId, value: tiles) in grouped.entries) {
        final db = await _db(providerId);
        await db.transaction((txn) async {
          for (final tile in tiles) {
            await txn.insert(
              'tiles',
              {
                'zoom_level': tile.z,
                'tile_column': tile.x,
                'tile_row': tile.tileRow,
                'tile_data': tile.data,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        });
      }
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Batch save failed: $e');
    } finally {
      _flushing = const {};
      _isFlushing = false;
      // フラッシュ中に新たに溜まったタイルがあれば再フラッシュ
      if (_writeQueue.isNotEmpty) {
        _batchTimer?.cancel();
        _batchTimer = Timer(const Duration(milliseconds: 50), _flushBatch);
      }
    }
  }

  /// タイルを取得
  Future<Uint8List?> getTile({
    required String providerId,
    required int z,
    required int x,
    required int y,
  }) async {
    // 書き込みキュー内のタイルもヒットさせる（未フラッシュデータ対応）
    final key = _key(providerId, z, x, y);
    final pending = _writeQueue[key] ?? _flushing[key];
    if (pending != null) return pending.data;

    // MBTilesファイルが無ければ null
    if (_cacheDirectory == null || !_existing.contains(providerId)) return null;

    final tileRow = _tmsRow(z, y);
    try {
      final db = await _db(providerId);
      final results = await db.query(
        'tiles',
        columns: ['tile_data'],
        where: _whereTile,
        whereArgs: [z, x, tileRow],
        limit: 1,
      );
      if (results.isEmpty) return null;

      final data = results.first['tile_data'] as Uint8List;
      // データサイズチェック（破損検出）
      if (!isPlausibleTile(data)) {
        await db.delete('tiles', where: _whereTile, whereArgs: [z, x, tileRow]);
        AppLogger.debug('[TILE-CACHE] 🗑️ Deleted corrupted tile (too small)');
        return null;
      }
      return data;
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Get tile error: $e');
      return null;
    }
  }

  /// キャッシュがあるプロバイダー（`.mbtiles` のファイル名）。本体が無く -wal などの残骸だけのものも含む
  Future<List<String>> cachedProviderIds() async {
    if (_cacheDirectory == null) return const [];
    try {
      return {
        await for (final e in Directory(_cacheDirectory!).list())
          if (e is File && _mbtilesName.hasMatch(path.basename(e.path)))
            path.basename(e.path).replaceFirst(_mbtilesName, ''),
      }.toList();
    } catch (_) {
      return const [];
    }
  }

  /// プロバイダー別のタイル数を取得
  Future<Map<String, int>> getStatistics() async {
    if (_cacheDirectory == null) return {};

    final stats = <String, int>{};
    for (final providerId in _existing.toList()) {
      try {
        final db = await _db(providerId);
        stats[providerId] = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM tiles')) ?? 0;
      } catch (e) {
        AppLogger.debug('[TILE-CACHE] ❌ Stats error for $providerId: $e');
      }
    }
    return stats;
  }

  /// キャッシュサイズを取得（バイト）
  Future<int> getCacheSize() async {
    if (_cacheDirectory == null) return 0;

    try {
      var totalSize = 0;
      for (final providerId in _existing.toList()) {
        final file = File(_filePath(providerId));
        if (await file.exists()) totalSize += await file.length();
      }
      return totalSize;
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Size error: $e');
      return 0;
    }
  }

  /// キャッシュをクリア（プロバイダー指定可能）
  Future<void> clearCache({String? providerId}) async {
    if (_cacheDirectory == null) return;

    try {
      final ids = providerId != null ? [providerId] : {...await cachedProviderIds(), ..._databases.keys};
      for (final id in ids) {
        final db = _databases.remove(id);
        if (db != null) await (await db).close();
        _existing.remove(id);
        // WAL の相方（-wal / -shm / -journal）も一緒に消す（本体だけ消すと残骸が溜まる）
        for (final suffix in const ['', '-wal', '-shm', '-journal']) {
          final file = File(_filePath(id, suffix));
          if (await file.exists()) await file.delete();
        }
      }
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Clear error: $e');
      rethrow;
    }
  }

  /// 破損タイル（[minTileBytes] 未満）の検証・削除。タイルの中身は読み出さず SQL で数えて消す
  Future<Map<String, dynamic>> validateAndRepair() async {
    var total = 0;
    var removed = 0;
    if (_cacheDirectory != null) {
      try {
        for (final providerId in _existing.toList()) {
          final db = await _db(providerId);
          total += Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM tiles')) ?? 0;
          final n = await db.delete('tiles', where: 'length(tile_data) < ?', whereArgs: [minTileBytes]);
          if (n > 0) {
            removed += n;
            await db.rawQuery('VACUUM');
          }
        }
      } catch (e) {
        AppLogger.debug('[TILE-CACHE] ❌ Validation error: $e');
      }
    }
    return {
      'totalTiles': total,
      'validTiles': total - removed,
      'invalidTiles': removed,
      'removedTiles': removed,
    };
  }

  /// データベースを閉じる
  Future<void> close() async {
    // 残りのバッチを保存
    _batchTimer?.cancel();
    await _flushBatch();

    final dbs = _databases.values.toList();
    _databases.clear();
    for (final db in dbs) {
      await (await db).close();
    }
  }
}
