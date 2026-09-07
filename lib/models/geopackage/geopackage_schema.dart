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
// Root Maps: GeoPackage スキーマ管理クラス
// PRIMARY KEY検出、カラム追加・取得などのスキーマ操作を担当
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import 'geopackage_connection.dart';

/// GeoPackage スキーマを管理するクラス
/// 責務: PRIMARY KEY検出、カラム追加・取得、テーブル構造操作
class GeoPackageSchema {
  /// DB接続への参照
  final GeoPackageConnection connection;

  /// PRIMARY KEYカラム名のキャッシュ（テーブル名 → PRIMARY KEYカラム名）
  final Map<String, String> _primaryKeyCache = {};

  /// サポートする属性カラム名リスト（属性テーブルで表示するカラム）
  final List<String> supportedAttributes = [
    'id', // 内部的にPRIMARY KEYを正規化したもの
    'geom',
  ];

  /// コンストラクタ
  GeoPackageSchema(this.connection);

  /// PRIMARY KEYカラム名を動的に取得（キャッシュ機能付き）
  ///
  /// Root Maps標準形式（新規作成）: fid INTEGER PRIMARY KEY AUTOINCREMENT（QGIS互換）
  /// 旧Root Maps形式: id INTEGER PRIMARY KEY AUTOINCREMENT（後方互換性のため対応）
  /// PRIMARY KEYがない外部ファイル: fid を自動追加、または rowid フォールバック
  Future<String> getPrimaryKeyColumn(String tableName) async {
    // キャッシュをチェック
    if (_primaryKeyCache.containsKey(tableName)) {
      return _primaryKeyCache[tableName]!;
    }

    final db = await connection.getDatabase();

    // PRAGMA table_infoでカラム情報を取得
    final columns = await db.rawQuery('PRAGMA table_info("$tableName");');

    // PRIMARY KEYカラムを検索（pk列が1のもの）
    String? primaryKeyColumn;
    for (final column in columns) {
      final pk = column['pk'] as int?;
      if (pk != null && pk > 0) {
        primaryKeyColumn = column['name'] as String;
        break;
      }
    }

    // PRIMARY KEYが見つかった場合
    if (primaryKeyColumn != null) {
      if (primaryKeyColumn != 'fid') {
        if (primaryKeyColumn == 'id') {
          AppLogger.debug(
            '[GeoPackageSchema] ℹ️ 旧形式PRIMARY KEY検出: テーブル "$tableName" は "id" を使用（現在のRoot Maps標準は "fid"）',
          );
        } else {
          AppLogger.debug(
            '[GeoPackageSchema] ℹ️ 非標準PRIMARY KEY検出: テーブル "$tableName" は "$primaryKeyColumn" を使用',
          );
        }
      }
      _primaryKeyCache[tableName] = primaryKeyColumn;
      return primaryKeyColumn;
    }

    // PRIMARY KEYがない場合の処理
    AppLogger.debug(
      '[GeoPackageSchema] ⚠️ 警告: テーブル "$tableName" にPRIMARY KEYが見つかりません！',
    );
    AppLogger.debug('[GeoPackageSchema] ⚠️ データが破損している可能性があります。');

    try {
      // テーブルのレコード数をチェック
      final countResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM "$tableName";',
      );
      final rowCount = countResult.first['count'] as int? ?? 0;

      // fid または id カラムが既に存在するかチェック
      final hasFidColumn = columns.any((col) => col['name'] == 'fid');
      final hasIdColumn = columns.any((col) => col['name'] == 'id');

      // QGIS互換性のため、fid カラムを優先的に使用・追加
      if (!hasFidColumn && !hasIdColumn) {
        if (rowCount > 10000) {
          AppLogger.debug(
            '[GeoPackageSchema] 🔧 fidカラムを自動追加します（$rowCount行のデータ、処理に時間がかかる場合があります）...',
          );
        } else {
          AppLogger.debug(
            '[GeoPackageSchema] 🔧 fidカラムを自動追加します（$rowCount行のデータ）...',
          );
        }

        // fidカラムを追加（QGIS標準）
        await db.execute('ALTER TABLE "$tableName" ADD COLUMN fid INTEGER;');

        // rowidから値をコピー
        await db.execute('UPDATE "$tableName" SET fid = rowid;');

        AppLogger.debug('[GeoPackageSchema] ✓ fidカラムを追加し、rowidから値をコピーしました。');
        _primaryKeyCache[tableName] = 'fid';
        return 'fid';
      } else if (hasFidColumn) {
        AppLogger.debug(
          '[GeoPackageSchema] ℹ️ fidカラムは存在しますが、PRIMARY KEYとして定義されていません。',
        );
        _primaryKeyCache[tableName] = 'fid';
        return 'fid';
      } else {
        AppLogger.debug(
          '[GeoPackageSchema] ℹ️ idカラムは存在しますが、PRIMARY KEYとして定義されていません。',
        );
        _primaryKeyCache[tableName] = 'id';
        return 'id';
      }
    } catch (e, stackTrace) {
      AppLogger.debug('[GeoPackageSchema] ❌ エラー: PRIMARY KEY処理中に問題が発生しました: $e');
      AppLogger.debug('[GeoPackageSchema] スタックトレース: $stackTrace');

      // フォールバック: fid > id > rowid の優先順位
      final hasFidColumn = columns.any((col) => col['name'] == 'fid');
      final hasIdColumn = columns.any((col) => col['name'] == 'id');

      if (hasFidColumn) {
        _primaryKeyCache[tableName] = 'fid';
        return 'fid';
      } else if (hasIdColumn) {
        _primaryKeyCache[tableName] = 'id';
        return 'id';
      } else {
        AppLogger.debug(
          '[GeoPackageSchema] ⚠️ 緊急フォールバック: rowidを使用します。このファイルは読み込み専用としてのみ使用してください。',
        );
        _primaryKeyCache[tableName] = 'rowid';
        return 'rowid';
      }
    }
  }

  /// WHERE句を生成（PRIMARY KEYカラムに応じてクォート処理）
  Future<String> buildWhereClause(String tableName) async {
    final pkColumn = await getPrimaryKeyColumn(tableName);
    return pkColumn == 'rowid' ? 'rowid = ?' : '"$pkColumn" = ?';
  }

  /// 指定テーブルのカラム名一覧を返す
  /// [skipPrimaryKey] trueの場合、PRIMARY KEYカラムを除外（属性テーブル表示用）
  Future<List<String>> getColumnNames(
    String tableName, {
    bool getAll = false,
    bool skipPrimaryKey = false,
  }) async {
    try {
      final db = await connection.getDatabase();
      final result = await db.rawQuery('PRAGMA table_info("$tableName");');
      final columns = result.map((row) => row['name'] as String).toList();

      // geom は属性データではないため常に除外
      var filteredColumns = columns.where((c) => c != 'geom').toList();

      // PRIMARY KEYをスキップ（属性テーブル表示用）
      if (skipPrimaryKey) {
        final pkColumn = await getPrimaryKeyColumn(tableName);
        filteredColumns = filteredColumns.where((c) => c != pkColumn).toList();
      }

      if (getAll) return filteredColumns;
      return filteredColumns
          .where(supportedAttributes.contains)
          .toList();
    } catch (e) {
      AppLogger.debug('[GeoPackageSchema] getColumnNames: エラー発生 - $e');
      return [];
    }
  }

  /// テーブルのカラム名リストを取得
  Future<List<String>> getTableColumns(String tableName) async {
    try {
      final db = await connection.getDatabase();
      final result = await db.rawQuery('PRAGMA table_info("$tableName");');
      return result.map((row) => row['name'] as String).toList();
    } catch (e) {
      AppLogger.debug('[GeoPackageSchema] getTableColumns エラー: $e');
      return [];
    }
  }

  /// 属性カラムを動的に追加
  Future<void> addAttributeColumn(
    String tableName,
    String columnName,
    String columnType,
  ) async {
    try {
      final db = await connection.getDatabase();

      // カラム名の安全性チェック（QGIS準拠）
      final sanitizedName = sanitizeColumnName(columnName);
      if (sanitizedName.isEmpty) {
        throw Exception(t.services.invalidColumnName(name: columnName));
      }

      // 既存カラムのチェック
      final result = await db.rawQuery('PRAGMA table_info("$tableName");');
      final columns = result.map((row) => row['name'] as String).toList();

      if (!columns.contains(sanitizedName)) {
        await db.execute(
          'ALTER TABLE "$tableName" ADD COLUMN "$sanitizedName" $columnType;',
        );
      }
    } catch (e) {
      AppLogger.debug('[GeoPackageSchema] addAttributeColumn エラー発生 - $e');
      rethrow;
    }
  }

  /// 複数の属性カラムを一括追加
  Future<void> addAttributeColumns(
    String tableName,
    Map<String, String> attributeSchema,
  ) async {
    try {
      for (final entry in attributeSchema.entries) {
        final columnName = entry.key;
        final columnType = entry.value;
        await addAttributeColumn(tableName, columnName, columnType);
      }
    } catch (e) {
      AppLogger.debug('[GeoPackageSchema] addAttributeColumns エラー発生 - $e');
      rethrow;
    }
  }

  /// レイヤの全属性カラム情報を取得（詳細）
  Future<List<Map<String, dynamic>>> getAttributeColumnInfo(
    String tableName, {
    bool includeBuiltIn = false,
  }) async {
    try {
      final db = await connection.getDatabase();
      final result = await db.rawQuery('PRAGMA table_info("$tableName");');

      final columnInfo = <Map<String, dynamic>>[];
      final builtInColumns = {'id', 'geom'};

      for (final row in result) {
        final columnName = row['name'] as String;

        if (!includeBuiltIn && builtInColumns.contains(columnName)) {
          continue;
        }

        columnInfo.add({
          'name': columnName,
          'type': row['type'] as String,
          'notNull': (row['notnull'] as int) == 1,
          'defaultValue': row['dflt_value'],
          'primaryKey': (row['pk'] as int) == 1,
        });
      }

      return columnInfo;
    } catch (e) {
      AppLogger.debug('[GeoPackageSchema] getAttributeColumnInfo エラー発生 - $e');
      return [];
    }
  }

  /// カラム名をQGIS準拠でサニタイズ（SQLインジェクション対策）
  String sanitizeColumnName(String name) {
    if (name.isEmpty) return '';
    return name
        .replaceAll('"', '')
        .replaceAll("'", '')
        .replaceAll(';', '_')
        .replaceAll('--', '_')
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ')
        .trim();
  }

  /// PRIMARY KEYキャッシュをクリア
  void clearPrimaryKeyCache() {
    _primaryKeyCache.clear();
  }
}
