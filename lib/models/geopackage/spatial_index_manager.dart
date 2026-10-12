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
// Root Maps: 空間インデックス管理クラス
// R-Tree操作、エンベロープ更新を担当（SpatiaLiteトリガーは gdal_trigger_guard.dart）
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../utils/app_logger.dart';
import '../../utils/wkb_utils.dart';
import 'gdal_trigger_guard.dart';
import 'geopackage_connection.dart';
import 'gpkg_rtree.dart';
import 'qgis_interop.dart';
import 'sql_identifier.dart';

/// 空間インデックスを管理するクラス
/// 責務: R-Tree空間インデックス、レイヤエンベロープ、SpatiaLiteトリガー対応
class SpatialIndexManager {
  /// DB接続への参照
  final GeoPackageConnection connection;

  /// QGIS相互運用（落としたトリガーを控えて、クローズ時・外へ出す前に戻す）。同じファイルの接続で共有する
  QgisInterop get qgisInterop => connection.qgisInterop;

  /// テスト用: Android 本体の SQLite と同じく rtree モジュールが無いものとして振る舞う
  /// （rtree への書き込みが `no such module: rtree` で落ちる）
  @visibleForTesting
  static bool debugWithoutRtreeModule = false;

  static void _failIfNoRtreeModule() {
    if (debugWithoutRtreeModule) throw StateError('no such module: rtree（debugWithoutRtreeModule）');
  }

  /// コンストラクタ
  SpatialIndexManager(this.connection);

  /// 空間インデックス作成（GeoPackageの空間インデックス機能を利用）
  Future<void> createSpatialIndex(String tableName) async {
    try {
      final db = await connection.getDatabase();

      // SpatiaLiteスタイルの空間インデックス作成
      await db.execute('''
        CREATE INDEX IF NOT EXISTS ${quoteIdent('idx_${tableName}_geom')}
        ON ${quoteIdent(tableName)} (geom)
      ''');
    } catch (e) {
      AppLogger.debug('[ERROR] SpatialIndexManager.createSpatialIndex: $e');
    }
  }

  /// 書いた行の形（GeoPackage のバイナリ）から範囲を取り、R-Tree とレイヤの範囲
  /// （gpkg_contents）に入れる。範囲はレイヤの CRS のまま（WGS84 に直さない）。
  ///
  /// QGIS 製の gpkg は R-Tree を保つトリガーを SpatiaLite 関数ごと落としているので
  /// （[GdalTriggerGuard]）、追加・更新のたびにここで入れ直す
  Future<void> indexRows(String tableName, Map<int, Uint8List> geoms) async {
    if (geoms.isEmpty) return;
    try {
      final db = await connection.getDatabase();
      // 形の列が geom とは限らない（rtree_<表>_<列>）
      final rtreeTable = await gpkgRtreeTable(db, tableName);
      if (rtreeTable != null) _failIfNoRtreeModule();

      double? minX, minY, maxX, maxY;
      final batch = db.batch();
      for (final MapEntry(key: id, value: blob) in geoms.entries) {
        final env = gpkgEnvelope(blob);
        if (env == null) {
          // 空の形は索引に載せない（GDAL の更新トリガーと同じく、前の範囲を消す）
          if (rtreeTable != null) batch.execute('DELETE FROM ${quoteIdent(rtreeTable)} WHERE id = ?', [id]);
          continue;
        }
        if (rtreeTable != null) {
          batch.execute(
            'INSERT OR REPLACE INTO ${quoteIdent(rtreeTable)} (id, minx, maxx, miny, maxy) VALUES (?, ?, ?, ?, ?)',
            [id, env.minX, env.maxX, env.minY, env.maxY],
          );
        }
        minX = minX == null || env.minX < minX ? env.minX : minX;
        minY = minY == null || env.minY < minY ? env.minY : minY;
        maxX = maxX == null || env.maxX > maxX ? env.maxX : maxX;
        maxY = maxY == null || env.maxY > maxY ? env.maxY : maxY;
      }
      if (minX == null) {
        await batch.commit(noResult: true);
        return;
      }
      // レイヤの範囲は広げるだけ（縮めるのは GpkgIndexRepair）
      batch.execute(
        'UPDATE gpkg_contents SET '
        'min_x = min(coalesce(min_x, ?1), ?1), min_y = min(coalesce(min_y, ?2), ?2), '
        'max_x = max(coalesce(max_x, ?3), ?3), max_y = max(coalesce(max_y, ?4), ?4) '
        'WHERE table_name = ?5',
        [minX, minY, maxX, maxY, tableName],
      );
      await batch.commit(noResult: true);
    } catch (e) {
      // 索引の更新に失敗しても書き込みは成り立つ（GpkgIndexRepair で直せる）
      AppLogger.debug('[WARNING] SpatialIndexManager.indexRows: $e');
    }
  }

  /// R-Tree空間インデックスからエントリを削除（フィーチャ削除時に呼び出す）
  Future<void> removeFromRTreeIndex(String tableName, int rowId) async {
    try {
      final db = await connection.getDatabase();
      final rtreeTable = await gpkgRtreeTable(db, tableName);
      if (rtreeTable != null) {
        _failIfNoRtreeModule();
        await db.execute('DELETE FROM ${quoteIdent(rtreeTable)} WHERE id = ?', [rowId]);
      }
    } catch (e) {
      AppLogger.debug('[WARNING] SpatialIndexManager.removeFromRTreeIndex: $e');
    }
  }

  /// SpatiaLite 関数・rtree のトリガーを見回り直して落とす（落とし済みの印に頼らない）。落とした数を返す。
  ///
  /// ふだんは接続（[GuardedDatabase]）が書く前に落とすので呼ばなくてよい。保存が落ちたあとに
  /// 落とし直してやり直すとき（`BackgroundSaveManager`）に使う
  Future<int> dropGdalTriggers() async {
    try {
      final db = await connection.getDatabase();
      return await GdalTriggerGuard.drop(db, qgisInterop);
    } catch (e) {
      AppLogger.debug('[ERROR] SpatialIndexManager.dropGdalTriggers: $e');
      return 0;
    }
  }
}
