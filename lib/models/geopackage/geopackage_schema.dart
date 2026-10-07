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
import 'sql_identifier.dart';

/// GeoPackage スキーマを管理するクラス
/// 責務: PRIMARY KEY検出、カラム追加・取得、テーブル構造操作
///
/// `PRAGMA table_info` と主キー名は [GeoPackageConnection.schemaCache] に控える
/// （同じファイルを開いている接続で共有）。列・テーブルを変えたら [invalidate] する。
class GeoPackageSchema {
  /// DB接続への参照
  final GeoPackageConnection connection;

  /// 属性テーブルで表示するカラム（getAll でないときの [getColumnNames] の対象）
  static const List<String> supportedAttributes = [
    'id', // 内部的にPRIMARY KEYを正規化したもの
    'geom',
  ];

  /// コンストラクタ
  GeoPackageSchema(this.connection);

  GpkgSchemaCache get _cache => connection.schemaCache;

  /// `PRAGMA table_info` の行（控えがあればそれ）。テーブルが無ければ空（空は控えない）
  Future<List<Map<String, Object?>>> tableInfo(String tableName) async {
    final cached = _cache.tableInfo[tableName];
    if (cached != null) return cached;
    final db = await connection.getDatabase();
    final rows = await db.rawQuery('PRAGMA table_info(${quoteIdent(tableName)});');
    if (rows.isNotEmpty) _cache.tableInfo[tableName] = rows;
    return rows;
  }

  /// テーブルの列名（並びは table_info のまま）
  Future<List<String>> _columnNames(String tableName) async =>
      [for (final row in await tableInfo(tableName)) row['name'] as String];

  /// 列・テーブルを変えたあとに呼ぶ（控えた table_info と主キー名を捨てる）
  void invalidate() => _cache.clear();

  /// PRIMARY KEYカラム名を動的に取得（キャッシュ機能付き）
  ///
  /// Root Maps標準形式（新規作成）: fid INTEGER PRIMARY KEY AUTOINCREMENT（QGIS互換）
  /// 旧Root Maps形式: id INTEGER PRIMARY KEY AUTOINCREMENT（後方互換性のため対応）
  /// PRIMARY KEYがない外部ファイル: fid を自動追加、または rowid フォールバック
  Future<String> getPrimaryKeyColumn(String tableName) async {
    final cached = _cache.primaryKey[tableName];
    if (cached != null) return cached;
    final pk = await _detectPrimaryKey(tableName);
    _cache.primaryKey[tableName] = pk;
    return pk;
  }

  Future<String> _detectPrimaryKey(String tableName) async {
    final columns = await tableInfo(tableName);

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
      return primaryKeyColumn;
    }

    // PRIMARY KEYがない場合の処理
    AppLogger.debug(
      '[GeoPackageSchema] ⚠️ 警告: テーブル "$tableName" にPRIMARY KEYが見つかりません！',
    );
    AppLogger.debug('[GeoPackageSchema] ⚠️ データが破損している可能性があります。');

    final hasFidColumn = columns.any((col) => col['name'] == 'fid');
    final hasIdColumn = columns.any((col) => col['name'] == 'id');
    try {
      final db = await connection.getDatabase();
      // テーブルのレコード数をチェック
      final countResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM ${quoteIdent(tableName)};',
      );
      final rowCount = countResult.first['count'] as int? ?? 0;

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
        await db.execute('ALTER TABLE ${quoteIdent(tableName)} ADD COLUMN fid INTEGER;');
        _cache.tableInfo.remove(tableName); // 列が増えた

        // rowidから値をコピー
        await db.execute('UPDATE ${quoteIdent(tableName)} SET fid = rowid;');

        AppLogger.debug('[GeoPackageSchema] ✓ fidカラムを追加し、rowidから値をコピーしました。');
        return 'fid';
      } else if (hasFidColumn) {
        AppLogger.debug(
          '[GeoPackageSchema] ℹ️ fidカラムは存在しますが、PRIMARY KEYとして定義されていません。',
        );
        return 'fid';
      } else {
        AppLogger.debug(
          '[GeoPackageSchema] ℹ️ idカラムは存在しますが、PRIMARY KEYとして定義されていません。',
        );
        return 'id';
      }
    } catch (e, stackTrace) {
      AppLogger.debug('[GeoPackageSchema] ❌ エラー: PRIMARY KEY処理中に問題が発生しました: $e');
      AppLogger.debug('[GeoPackageSchema] スタックトレース: $stackTrace');

      // フォールバック: fid > id > rowid の優先順位
      if (hasFidColumn) return 'fid';
      if (hasIdColumn) return 'id';
      AppLogger.debug(
        '[GeoPackageSchema] ⚠️ 緊急フォールバック: rowidを使用します。このファイルは読み込み専用としてのみ使用してください。',
      );
      return 'rowid';
    }
  }

  /// 主キーで 1 行を選ぶ WHERE 句（値は `?`）
  Future<String> buildWhereClause(String tableName) async =>
      pkEquals(await getPrimaryKeyColumn(tableName));

  /// 指定テーブルのカラム名一覧を返す
  /// [skipPrimaryKey] trueの場合、PRIMARY KEYカラムを除外（属性テーブル表示用）
  Future<List<String>> getColumnNames(
    String tableName, {
    bool getAll = false,
    bool skipPrimaryKey = false,
  }) async {
    try {
      // geom は属性データではないため常に除外
      var filteredColumns =
          (await _columnNames(tableName)).where((c) => c != 'geom').toList();

      // PRIMARY KEYをスキップ（属性テーブル表示用）
      if (skipPrimaryKey) {
        final pkColumn = await getPrimaryKeyColumn(tableName);
        filteredColumns = filteredColumns.where((c) => c != pkColumn).toList();
      }

      if (getAll) return filteredColumns;
      return filteredColumns.where(supportedAttributes.contains).toList();
    } catch (e) {
      AppLogger.debug('[GeoPackageSchema] getColumnNames: エラー発生 - $e');
      return [];
    }
  }

  /// テーブルのカラム名リストを取得
  Future<List<String>> getTableColumns(String tableName) async {
    try {
      return await _columnNames(tableName);
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
      // カラム名の安全性チェック（QGIS準拠）
      final sanitizedName = sanitizeColumnName(columnName);
      if (sanitizedName.isEmpty) {
        throw Exception(t.services.invalidColumnName(name: columnName));
      }

      // 既存カラムのチェック
      if (!(await _columnNames(tableName)).contains(sanitizedName)) {
        final db = await connection.getDatabase();
        await db.execute(
          'ALTER TABLE ${quoteIdent(tableName)} ADD COLUMN ${quoteIdent(sanitizedName)} $columnType;',
        );
        invalidate();
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
      for (final MapEntry(key: columnName, value: columnType)
          in attributeSchema.entries) {
        await addAttributeColumn(tableName, columnName, columnType);
      }
    } catch (e) {
      AppLogger.debug('[GeoPackageSchema] addAttributeColumns エラー発生 - $e');
      rethrow;
    }
  }

  /// カラム名を変える（新しい名前は [sanitizeColumnName] を通す）
  Future<void> renameColumn(String tableName, String oldName, String newName) async {
    final sanitizedNew = sanitizeColumnName(newName);
    if (sanitizedNew.isEmpty) {
      throw Exception(t.services.invalidColumnName(name: newName));
    }
    final db = await connection.getDatabase();
    await db.execute(
      'ALTER TABLE ${quoteIdent(tableName)} RENAME COLUMN ${quoteIdent(oldName)} TO ${quoteIdent(sanitizedNew)}',
    );
    invalidate();
  }

  /// カラムを消す
  Future<void> dropColumn(String tableName, String columnName) async {
    final db = await connection.getDatabase();
    await db.execute('ALTER TABLE ${quoteIdent(tableName)} DROP COLUMN ${quoteIdent(columnName)}');
    invalidate();
  }

  /// レイヤの全属性カラム情報を取得（詳細）
  Future<List<Map<String, dynamic>>> getAttributeColumnInfo(
    String tableName, {
    bool includeBuiltIn = false,
  }) async {
    try {
      const builtInColumns = {'id', 'geom'};
      return [
        for (final row in await tableInfo(tableName))
          if (includeBuiltIn || !builtInColumns.contains(row['name']))
            {
              'name': row['name'] as String,
              'type': row['type'] as String,
              'notNull': (row['notnull'] as int) == 1,
              'defaultValue': row['dflt_value'],
              'primaryKey': (row['pk'] as int) == 1,
            },
      ];
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
}
