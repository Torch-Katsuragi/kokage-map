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
/// アプリの接続で書く前に、GDAL（QGIS）の rtree トリガーを落とす関所。
///
/// QGIS 製の gpkg は rtree を保つトリガーを持ち、`ST_IsEmpty` / `ST_MinX` などの SpatiaLite 関数を呼ぶ。
/// Android 本体の SQLite にはその関数も rtree モジュールも無く、トリガーの付いた表に書く文は
/// **準備（compile）の時点で** `no such function: ST_IsEmpty` で落ちる。GDAL の組の update5・update4 は
/// `AFTER UPDATE ON <表>`（列を問わない）なので、属性だけの UPDATE も落ちる。
///
/// > [!WARNING] 属性の変更が保存されなかった（2026-10-12 Pixel 9）
/// > 以前はトリガーを落とすのが地物の追加・形の更新・削除の経路だけで、属性の UPDATE などは
/// > 「どこかで先に落としてある」ことに頼っていた。外へ出す前にトリガーを戻す
/// > （`GeoPackageFile.prepareForHandOff`）ようにしたら、戻したあとの属性の保存が毎回落ち、
/// > 書き直しも落ち続けて、アプリを閉じると失われた。
///
/// そこで経路ごとに落とすのをやめ、[GeoPackageConnection.getDatabase] が返す [GuardedDatabase] が
/// 書く文（INSERT / UPDATE / DELETE / REPLACE / ALTER と、それを含むバッチ・トランザクション）の前に
/// ファイル全体の該当トリガーを落とす（[GdalTriggerGuard.drop]）。落としたかどうかは
/// [QgisInterop.triggersDropped]（パスごと）に持ち、トリガーを戻したとき・開き直したときに倒す。
/// それでも ST_ 関数・rtree が無くて落ちたら、見回り直して 1 度だけやり直す（別の SQLite がトリガーを作った等）。
library;

import 'package:sqflite/sqflite.dart';

import '../../utils/app_logger.dart';
import 'qgis_interop.dart';
import 'sql_identifier.dart';

abstract final class GdalTriggerGuard {
  /// sqflite に無い関数（SpatiaLite と GeoPackage の拡張）
  static const _functions = [
    'ST_IsEmpty', 'ST_MinX', 'ST_MaxX', 'ST_MinY', 'ST_MaxY', 'ST_MinZ', 'ST_MaxZ', 'ST_MinM', 'ST_MaxM', //
    'ST_GeometryType', 'ST_SRID', 'IsValidGPB', 'gpkgMakePoint',
  ];

  /// 落とすトリガーか: sqflite に無い関数を使うもの、rtree の表を保つもの（`rtree_` で始まる。DELETE のように
  /// ST_ 関数を使わないものも rtree モジュールが無いと落ちる）
  static bool shouldDrop(String name, String sql) {
    if (name.toLowerCase().startsWith('rtree_')) return true;
    final upper = sql.toUpperCase();
    return _functions.any((f) => upper.contains(f.toUpperCase()));
  }

  /// ファイル全体の落とすトリガー（[shouldDrop]）を、定義を [interop] に控えてから落とす。落とした数を返す。
  ///
  /// [executor] はトランザクションの中ならそのトランザクション（外の Database で書くと待ち合って止まる）
  static Future<int> drop(DatabaseExecutor executor, QgisInterop interop) async {
    final triggers = await executor.rawQuery("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
    final dropped = <String>[];
    for (final t in triggers) {
      final name = t['name'] as String?;
      final sql = t['sql'] as String? ?? '';
      if (name == null || !shouldDrop(name, sql)) continue;
      // ⚠ 落とす前に定義を控える（外へ出す前に逐語で戻す）
      interop.rememberTrigger(name, sql);
      await executor.execute('DROP TRIGGER IF EXISTS ${quoteIdent(name)}');
      dropped.add(name);
    }
    interop.triggersDropped = true;
    if (dropped.isNotEmpty) {
      AppLogger.debug('[GdalTriggerGuard] SpatiaLiteトリガーを除去: ${dropped.length} 個 (${dropped.join(', ')})');
    }
    return dropped.length;
  }

  /// トリガーが呼ぶ関数・モジュールが無くて落ちたか
  static bool isMissingSpatialSupport(Object error) {
    final s = '$error';
    return RegExp('no such function: (ST_|gpkg|IsValidGPB)', caseSensitive: false).hasMatch(s) ||
        s.contains('no such module: rtree');
  }

  static final _writeSql = RegExp(
    r'^\s*(?:WITH\b[\s\S]*?\b)?(?:INSERT|UPDATE|DELETE|REPLACE|ALTER)\b',
    caseSensitive: false,
  );

  /// 書く文か（トリガーが付いていると落ちうる文。ALTER は表の改名などで SQLite がトリガーを読み直す）
  static bool isWriteSql(String sql) => _writeSql.hasMatch(sql);

  /// [op] の前にトリガーを落とす（済んでいれば落とさない）。ST_ 関数・rtree が無くて落ちたら、
  /// 見回り直して落とすものがあれば 1 度だけやり直す
  static Future<T> guard<T>(DatabaseExecutor executor, QgisInterop interop, Future<T> Function() op) async {
    if (!interop.triggersDropped) await drop(executor, interop);
    try {
      return await op();
    } on Object catch (e) {
      if (!isMissingSpatialSupport(e)) rethrow;
      if (await drop(executor, interop) == 0) rethrow;
      AppLogger.debug('[GdalTriggerGuard] トリガーが戻っていたので落としてやり直す: $e');
      return await op();
    }
  }
}

/// 書く文の前に [GdalTriggerGuard] を通す。[GuardedDatabase] と [_GuardedTransaction] の共通部分
mixin _GuardedExecutor implements DatabaseExecutor {
  DatabaseExecutor get _inner;
  QgisInterop get _interop;

  Future<T> _write<T>(Future<T> Function() op) => GdalTriggerGuard.guard(_inner, _interop, op);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) => GdalTriggerGuard.isWriteSql(sql)
      ? _write(() => _inner.execute(sql, arguments))
      : _inner.execute(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) => _write(() => _inner.rawInsert(sql, arguments));

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _write(() => _inner.insert(table, values, nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm));

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) => _write(() => _inner.rawUpdate(sql, arguments));

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _write(() => _inner.update(table, values, where: where, whereArgs: whereArgs, conflictAlgorithm: conflictAlgorithm));

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) => _write(() => _inner.rawDelete(sql, arguments));

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _write(() => _inner.delete(table, where: where, whereArgs: whereArgs));

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _inner.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) => _inner.rawQuery(sql, arguments);

  @override
  Future<QueryCursor> rawQueryCursor(String sql, List<Object?>? arguments, {int? bufferSize}) =>
      _inner.rawQueryCursor(sql, arguments, bufferSize: bufferSize);

  @override
  Future<QueryCursor> queryCursor(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
    int? bufferSize,
  }) =>
      _inner.queryCursor(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
        bufferSize: bufferSize,
      );

  @override
  Batch batch() => _GuardedBatch(_inner.batch(), this);
}

/// アプリの接続（[GeoPackageConnection.getDatabase]）。書く前に GDAL の rtree トリガーを落とす
class GuardedDatabase with _GuardedExecutor implements Database {
  GuardedDatabase(this.inner, this.interop);

  /// 包んでいる sqflite の Database
  final Database inner;

  /// このファイルの控え（落としたトリガー・落としたか）
  final QgisInterop interop;

  @override
  DatabaseExecutor get _inner => inner;
  @override
  QgisInterop get _interop => interop;

  @override
  Database get database => this;

  @override
  String get path => inner.path;

  @override
  bool get isOpen => inner.isOpen;

  @override
  Future<void> close() => inner.close();

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) =>
      inner.transaction((txn) => action(_GuardedTransaction(txn, this)), exclusive: exclusive);

  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction txn) action) =>
      inner.readTransaction((txn) => action(_GuardedTransaction(txn, this)));

  @override
  // ignore: deprecated_member_use
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) => inner.devInvokeMethod(method, arguments);

  @override
  // ignore: deprecated_member_use
  Future<T> devInvokeSqlMethod<T>(String method, String sql, [List<Object?>? arguments]) =>
      // ignore: deprecated_member_use
      inner.devInvokeSqlMethod(method, sql, arguments);
}

/// トランザクションの中で書く文も、そのトランザクションでトリガーを落としてから書く
class _GuardedTransaction with _GuardedExecutor implements Transaction {
  _GuardedTransaction(this._txn, this._db);

  final Transaction _txn;
  final GuardedDatabase _db;

  @override
  DatabaseExecutor get _inner => _txn;
  @override
  QgisInterop get _interop => _db.interop;

  @override
  Database get database => _db;
}

/// 書く文を積んだバッチは、流す前にトリガーを落とす
class _GuardedBatch implements Batch {
  _GuardedBatch(this._inner, this._owner);

  final Batch _inner;
  final _GuardedExecutor _owner;
  bool _writes = false;

  Future<List<Object?>> _run(Future<List<Object?>> Function() op) =>
      _writes ? GdalTriggerGuard.guard(_owner._inner, _owner._interop, op) : op();

  @override
  Future<List<Object?>> commit({bool? exclusive, bool? noResult, bool? continueOnError}) =>
      _run(() => _inner.commit(exclusive: exclusive, noResult: noResult, continueOnError: continueOnError));

  @override
  Future<List<Object?>> apply({bool? noResult, bool? continueOnError}) =>
      _run(() => _inner.apply(noResult: noResult, continueOnError: continueOnError));

  @override
  void rawInsert(String sql, [List<Object?>? arguments]) {
    _writes = true;
    _inner.rawInsert(sql, arguments);
  }

  @override
  void insert(String table, Map<String, Object?> values, {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) {
    _writes = true;
    _inner.insert(table, values, nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  }

  @override
  void rawUpdate(String sql, [List<Object?>? arguments]) {
    _writes = true;
    _inner.rawUpdate(sql, arguments);
  }

  @override
  void update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _writes = true;
    _inner.update(table, values, where: where, whereArgs: whereArgs, conflictAlgorithm: conflictAlgorithm);
  }

  @override
  void rawDelete(String sql, [List<Object?>? arguments]) {
    _writes = true;
    _inner.rawDelete(sql, arguments);
  }

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    _writes = true;
    _inner.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  void execute(String sql, [List<Object?>? arguments]) {
    if (GdalTriggerGuard.isWriteSql(sql)) _writes = true;
    _inner.execute(sql, arguments);
  }

  @override
  void query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _inner.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

  @override
  void rawQuery(String sql, [List<Object?>? arguments]) => _inner.rawQuery(sql, arguments);

  @override
  int get length => _inner.length;
}
