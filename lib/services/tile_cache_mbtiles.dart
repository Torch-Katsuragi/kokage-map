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
/// MapLibre の mbtiles:// プロトコルで直接オフライン読み込み可能
library;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:root_maps/utils/app_logger.dart';
import 'package:sqflite/sqflite.dart';

/// 保存待ちタイル
class _PendingTile {
  final String providerId;
  final int z;
  final int x;
  final int y;
  final Uint8List data;
  final int tileRow;

  _PendingTile({
    required this.providerId,
    required this.z,
    required this.x,
    required this.y,
    required this.data,
    required this.tileRow,
  });
}

/// プロバイダー単位のMBTilesデータベース接続管理
class _ProviderDB {
  final String providerId;
  final Database database;
  final String filePath;

  _ProviderDB({
    required this.providerId,
    required this.database,
    required this.filePath,
  });
}

/// MBTiles タイルキャッシュ管理
/// プロバイダーごとに独立した .mbtiles ファイルを管理
class TileCacheMBTiles {
  String? _cacheDirectory;

  // プロバイダーID → DB接続のマップ
  final Map<String, _ProviderDB> _databases = {};

  // バッチ書き込み用
  final List<_PendingTile> _writeQueue = [];
  Timer? _batchTimer;
  bool _isFlushing = false;

  /// 初期化（キャッシュディレクトリの設定）
  Future<void> initialize(String cacheDirectory) async {
    _cacheDirectory = cacheDirectory;

    final dir = Directory(cacheDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// 指定プロバイダーのMBTilesファイルパスを取得
  String? getMBTilesPath(String providerId) {
    if (_cacheDirectory == null) return null;
    final filePath = path.join(_cacheDirectory!, '$providerId.mbtiles');
    final file = File(filePath);
    if (file.existsSync()) return filePath;
    return null;
  }

  /// 指定プロバイダーのDB接続を取得（なければ作成）
  Future<_ProviderDB> _getOrCreateDB(String providerId) async {
    if (_databases.containsKey(providerId)) {
      return _databases[providerId]!;
    }

    final filePath = path.join(_cacheDirectory!, '$providerId.mbtiles');
    final database = await openDatabase(
      filePath,
      version: 1,
      onCreate: (db, version) async => _onCreateMBTiles(db, providerId),
      onOpen: _onOpenMBTiles,
    );

    final providerDB = _ProviderDB(
      providerId: providerId,
      database: database,
      filePath: filePath,
    );
    _databases[providerId] = providerDB;
    return providerDB;
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
    await db.insert('metadata', {'name': 'name', 'value': providerId});
    await db.insert('metadata', {'name': 'format', 'value': 'png'});
    await db.insert('metadata', {'name': 'type', 'value': 'overlay'});
    await db.insert(
      'metadata',
      {'name': 'bounds', 'value': '-180,-85.051129,180,85.051129'},
    );
    await db.insert('metadata', {'name': 'minzoom', 'value': '0'});
    await db.insert('metadata', {'name': 'maxzoom', 'value': '22'});
    await db.insert(
      'metadata',
      {'name': 'description', 'value': 'Cached tiles for $providerId'},
    );
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

    // MBTilesのタイル座標系はTMS方式（左下原点）
    // Web地図のXYZ方式（左上原点）から変換
    final tileRow = (1 << z) - 1 - y;

    // キューに追加
    _writeQueue.add(_PendingTile(
      providerId: providerId,
      z: z,
      x: x,
      y: y,
      data: data,
      tileRow: tileRow,
    ));

    // 上限チェック: 一定数溜まったら即フラッシュ（飢餓状態防止）
    if (_writeQueue.length >= 50) {
      _batchTimer?.cancel();
      await _flushBatch();
      return;
    }

    // 少量ならDebounceで待つ（100ms後にまとめて書き込み）
    _batchTimer?.cancel();
    _batchTimer = Timer(const Duration(milliseconds: 100), _flushBatch);
  }

  /// バッチ書き込み実行（キューに溜まったタイルを一括保存）
  Future<void> _flushBatch() async {
    if (_isFlushing || _writeQueue.isEmpty || _cacheDirectory == null) return;

    _isFlushing = true;
    final batch = _writeQueue.toList();
    _writeQueue.clear();

    try {
      // プロバイダーごとにグループ化
      final grouped = <String, List<_PendingTile>>{};
      for (final tile in batch) {
        (grouped[tile.providerId] ??= []).add(tile);
      }

      // プロバイダーごとにトランザクション書き込み
      for (final entry in grouped.entries) {
        final providerDB = await _getOrCreateDB(entry.key);
        await providerDB.database.transaction((txn) async {
          for (final tile in entry.value) {
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
    for (final pending in _writeQueue) {
      if (pending.providerId == providerId &&
          pending.z == z &&
          pending.x == x &&
          pending.y == y) {
        return pending.data;
      }
    }

    if (_cacheDirectory == null) return null;

    // MBTilesファイルが存在しない場合はnull
    final filePath = path.join(_cacheDirectory!, '$providerId.mbtiles');
    if (!File(filePath).existsSync()) return null;

    // XYZ → TMS 座標変換
    final tileRow = (1 << z) - 1 - y;

    try {
      final providerDB = await _getOrCreateDB(providerId);
      final results = await providerDB.database.query(
        'tiles',
        columns: ['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: [z, x, tileRow],
        limit: 1,
      );

      if (results.isNotEmpty) {
        final data = results.first['tile_data'] as Uint8List;

        // データサイズチェック（破損検出）
        if (data.length < 100) {
          await providerDB.database.delete(
            'tiles',
            where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
            whereArgs: [z, x, tileRow],
          );
          AppLogger.debug('[TILE-CACHE] 🗑️ Deleted corrupted tile (too small)');
          return null;
        }

        return data;
      }

      return null;
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Get tile error: $e');
      return null;
    }
  }

  /// プロバイダー別のタイル数を取得
  Future<Map<String, int>> getStatistics() async {
    if (_cacheDirectory == null) return {};

    final stats = <String, int>{};

    try {
      final dir = Directory(_cacheDirectory!);
      final mbtilesFiles =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.mbtiles'));

      for (final file in mbtilesFiles) {
        final providerId = path.basenameWithoutExtension(file.path);
        try {
          final providerDB = await _getOrCreateDB(providerId);
          final result = await providerDB.database.rawQuery(
            'SELECT COUNT(*) as count FROM tiles',
          );
          stats[providerId] = Sqflite.firstIntValue(result) ?? 0;
        } catch (e) {
          AppLogger.debug(
            '[TILE-CACHE] ❌ Stats error for $providerId: $e',
          );
        }
      }
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Statistics error: $e');
    }

    return stats;
  }

  /// 総タイル数を取得
  Future<int> getTotalTileCount() async {
    final stats = await getStatistics();
    return stats.values.fold<int>(0, (sum, count) => sum + count);
  }

  /// キャッシュサイズを取得（バイト）
  Future<int> getCacheSize() async {
    if (_cacheDirectory == null) return 0;

    try {
      final dir = Directory(_cacheDirectory!);
      int totalSize = 0;
      final mbtilesFiles =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.mbtiles'));

      for (final file in mbtilesFiles) {
        totalSize += await file.length();
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
      if (providerId != null) {
        // 特定プロバイダーのキャッシュをクリア
        if (_databases.containsKey(providerId)) {
          await _databases[providerId]!.database.close();
          _databases.remove(providerId);
        }
        final filePath = path.join(_cacheDirectory!, '$providerId.mbtiles');
        final file = File(filePath);
        if (file.existsSync()) {
          await file.delete();
        }
      } else {
        // 全プロバイダーのキャッシュをクリア
        for (final db in _databases.values) {
          await db.database.close();
        }
        _databases.clear();

        final dir = Directory(_cacheDirectory!);
        final mbtilesFiles =
            dir
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.mbtiles'));

        for (final file in mbtilesFiles) {
          await file.delete();
        }
      }
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Clear error: $e');
      rethrow;
    }
  }

  /// 破損タイル検証・修復
  Future<Map<String, dynamic>> validateAndRepair() async {
    if (_cacheDirectory == null) {
      return {
        'totalTiles': 0,
        'validTiles': 0,
        'invalidTiles': 0,
        'removedTiles': 0,
      };
    }

    final result = {
      'totalTiles': 0,
      'validTiles': 0,
      'invalidTiles': 0,
      'removedTiles': 0,
    };

    try {
      final dir = Directory(_cacheDirectory!);
      final mbtilesFiles =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.mbtiles'));

      for (final file in mbtilesFiles) {
        final providerId = path.basenameWithoutExtension(file.path);
        final providerDB = await _getOrCreateDB(providerId);

        final tiles = await providerDB.database.query('tiles');
        result['totalTiles'] = (result['totalTiles'] as int) + tiles.length;

        final rowsToDelete = <Map<String, int>>[];

        for (final tile in tiles) {
          final tileData = tile['tile_data'] as Uint8List;

          if (tileData.length < 100) {
            rowsToDelete.add({
              'zoom_level': tile['zoom_level'] as int,
              'tile_column': tile['tile_column'] as int,
              'tile_row': tile['tile_row'] as int,
            });
            result['invalidTiles'] = (result['invalidTiles'] as int) + 1;
            continue;
          }

          result['validTiles'] = (result['validTiles'] as int) + 1;
        }

        // 破損タイルを削除
        if (rowsToDelete.isNotEmpty) {
          for (final row in rowsToDelete) {
            await providerDB.database.delete(
              'tiles',
              where:
                  'zoom_level = ? AND tile_column = ? AND tile_row = ?',
              whereArgs: [
                row['zoom_level'],
                row['tile_column'],
                row['tile_row'],
              ],
            );
          }
          result['removedTiles'] =
              (result['removedTiles'] as int) + rowsToDelete.length;

          await providerDB.database.rawQuery('VACUUM');
        }
      }
    } catch (e) {
      AppLogger.debug('[TILE-CACHE] ❌ Validation error: $e');
    }

    return result;
  }

  /// データベースを閉じる
  Future<void> close() async {
    // 残りのバッチを保存
    _batchTimer?.cancel();
    await _flushBatch();

    for (final db in _databases.values) {
      await db.database.close();
    }
    _databases.clear();
  }
}
