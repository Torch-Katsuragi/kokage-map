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
// Root Maps: GeoPackage DB接続管理クラス
// DB接続の初期化、クローズ、バリデーションを担当
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/fs/k_file_system.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';

/// GeoPackage DB接続を管理するクラス
/// 責務: DB接続の初期化、クローズ、構造検証
class GeoPackageConnection {
  /// ルートからのパスリスト
  final List<String> pathList;

  /// 絶対パス（指定時はpathListを無視）
  /// グローバルフォルダ内のGeoPackageで使用
  final String? absolutePath;

  /// プロジェクトルートディレクトリ（相対パスモード時に使用）
  final String? projectRootDir;

  /// データベース接続インスタンス
  Database? _database;

  /// 初期化の排他制御用Completer（進行中のみ非null）
  Completer<void>? _initCompleter;

  /// データベース初期化完了フラグ
  bool _isInitialized = false;

  /// 初期化完了かどうか
  bool get isInitialized => _isInitialized;

  /// 開いている接続（正規化した絶対パス → 接続）。
  ///
  /// geodiff（sqlite を静的リンク）が同じファイルを読み書きする前に、こちらの接続を閉じるため。
  /// ⚠ 同じプロセスで別々の SQLite が同じファイルを開いていると、片方が閉じた瞬間に
  /// もう片方のロックも外れる（https://sqlite.org/howtocorrupt.html 2.2.1）。
  static final Map<String, Set<GeoPackageConnection>> _openConnections = {};

  /// 台帳に載せたときのキー（dispose で外すため）
  String? _registeredKey;

  static String _registryKey(String path) => p.canonicalize(path);

  /// [absPath] を開いている接続をすべて閉じる。閉じた数を返す。
  ///
  /// 閉じた接続は、次に [getDatabase] を呼んだときに開き直る（呼び手の作り直しは要らない）。
  /// geodiff の rebase / 写し取り、Drive からの上書きダウンロードの前に呼ぶ。
  static Future<int> closeAllFor(String absPath) async {
    final set = _openConnections.remove(_registryKey(absPath));
    if (set == null || set.isEmpty) return 0;
    var closed = 0;
    for (final c in set.toList()) {
      try {
        await c.dispose();
        closed++;
      } catch (e) {
        AppLogger.debug('[GeoPackageConnection] closeAllFor: 閉じられなかった $absPath - $e');
      }
    }
    AppLogger.debug('[GeoPackageConnection] closeAllFor: $closed 本を閉じた $absPath');
    return closed;
  }

  /// いま [absPath] を開いている接続の数（別の SQLite で書く前に、誰も開いていないことを確かめる）
  static int openCountFor(String absPath) => _openConnections[_registryKey(absPath)]?.length ?? 0;

  /// コンストラクタ
  GeoPackageConnection(this.pathList, {this.absolutePath, this.projectRootDir});

  /// データベース接続取得（初期化を含む）
  Future<Database> getDatabase() async {
    await _initializeDatabase();
    if (_database == null) {
      throw Exception(t.services.dbInitFailed);
    }
    return _database!;
  }

  /// データベース初期化（遅延初期化・Completerで二重実行防止）
  Future<void> _initializeDatabase() async {
    if (_isInitialized && _database != null) {
      return;
    }

    // 別の呼び出しが初期化中なら、その完了を待つ
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    try {
      await _initializeDatabaseImpl();
      _initCompleter!.complete();
    } catch (e, stack) {
      _initCompleter!.completeError(e, stack);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  /// 元ファイル → sqlite3 WASM（チェックアウト）
  ///
  /// web には「ファイルパスを渡して sqlite に開かせる」経路が無いので、
  /// 中身をバイト列で渡して sqflite 側のストレージに置いてから開く。
  /// native は sqflite が実ファイルを直接開くので何もしない。
  ///
  /// ⚠ 新規作成（元ファイルがまだ無い）ときは何も流し込まない。
  /// 空のDBとして開かれ、`onCreate` が走る。
  Future<void> _checkOut(String absPath) async {
    if (fs.hasRealPaths) return;
    final bytes = await fs.readAsBytes(absPath).catchError((_) => Uint8List(0));
    if (bytes.isEmpty) return;
    await databaseFactory.writeDatabaseBytes(_databaseKey(absPath), bytes);
    AppLogger.debug(
      '[GeoPackageConnection] チェックアウト: $absPath (${bytes.length}バイト)',
    );
  }

  /// 書き戻し監視タイマー（web のみ）
  Timer? _checkInTimer;

  /// 最後にチェックインした時点の `total_changes()`
  int _checkedInChanges = 0;

  /// 書き込みを検知して自動で書き戻す監視を始める（web のみ）。
  ///
  /// > [!IMPORTANT] なぜポーリングなのか
  /// > 書き込み経路が一箇所ではないため。フィーチャ追加は
  /// > `PointFeatureNode` が直接DBへ書き、属性編集は `BackgroundSaveManager`
  /// > 経由、レイヤ作成やQGIS整合処理はまた別。個別にフックを刺すと**必ず取りこぼす**
  /// > （実際 BackgroundSaveManager だけに刺して、フィーチャ追加を取りこぼした）。
  /// >
  /// > `total_changes()` は接続を開いてからの INSERT/UPDATE/DELETE 累計なので、
  /// > これを見ていれば経路によらず「書かれた」ことが分かる。
  void _startCheckInWatcher() {
    if (fs.hasRealPaths) return;
    _checkInTimer?.cancel();
    _checkInTimer = Timer.periodic(_checkInInterval, (_) => _checkInIfDirty());
  }

  static const _checkInInterval = Duration(seconds: 2);

  bool _checkInInProgress = false;

  Future<void> _checkInIfDirty() async {
    if (_checkInInProgress) return;
    final db = _database;
    if (db == null || !_isInitialized) return;
    _checkInInProgress = true;
    try {
      final rows = await db.rawQuery('SELECT total_changes() AS c');
      final changes = (rows.first['c'] as num).toInt();
      if (changes == _checkedInChanges) return;
      await checkIn();
      _checkedInChanges = changes;
    } catch (e) {
      AppLogger.debug('[GeoPackageConnection] 自動チェックイン失敗: $e');
    } finally {
      _checkInInProgress = false;
    }
  }

  /// sqlite3 WASM → 元ファイル（チェックイン）
  ///
  /// web で加えた変更を、ユーザーが選んだフォルダの `.gpkg` に書き戻す。
  /// native は sqflite が実ファイルを直接更新しているので何もしない。
  ///
  /// 呼ぶのは `BackgroundSaveManager` の保存後。
  /// ⚠ ここを呼ばないと、web の編集はタブを閉じた時点で消える。
  Future<void> checkIn() async {
    if (fs.hasRealPaths) return;
    if (!_isInitialized || _database == null) return;
    final absPath = _resolveAbsolutePath();
    if (absPath == null) return;
    try {
      final bytes = await databaseFactory.readDatabaseBytes(_databaseKey(absPath));
      await fs.writeAsBytes(absPath, bytes);
      AppLogger.debug(
        '[GeoPackageConnection] チェックイン: $absPath (${bytes.length}バイト)',
      );
    } catch (e) {
      AppLogger.debug('[GeoPackageConnection] チェックイン失敗: $absPath - $e');
      rethrow;
    }
  }

  /// sqflite に渡すデータベース識別子。
  ///
  /// native は**実ファイルのパスそのもの**（sqflite が直接そのファイルを開く）。
  /// web は実パスが無く、これは sqlite3 WASM 側ストレージ上の名前でしかないので、
  /// 仮想パス（`/フォルダ名/林小班.gpkg`）をそのまま渡さず、
  /// スラッシュも非ASCIIも含まない安全な名前に潰す。
  String _databaseKey(String absPath) {
    if (fs.hasRealPaths) return absPath;
    final digest = sha1.convert(utf8.encode(absPath)).toString();
    return 'gpkg_$digest.db';
  }

  /// このGeoPackageの絶対パス（未設定なら null）
  String? _resolveAbsolutePath() {
    if (absolutePath != null) return absolutePath;
    if (projectRootDir == null) return null;
    return p.joinAll([projectRootDir!, ...pathList]);
  }

  /// データベース初期化の実体
  Future<void> _initializeDatabaseImpl() async {
    // 絶対パスが指定されている場合はそれを使用（グローバルフォルダ用）
    final absPath = _resolveAbsolutePath();
    if (absPath == null) {
      AppLogger.debug('[GeoPackageConnection] 初期化失敗: projectRootDirが未設定');
      return;
    }

    final dirPath = p.dirname(absPath);

    if (!await fs.isDirectory(dirPath)) {
      AppLogger.debug('[GeoPackageConnection] 親ディレクトリを作成: $dirPath');
      try {
        await fs.createDirectory(dirPath);
      } catch (e) {
        AppLogger.debug('[GeoPackageConnection] 初期化失敗: 親ディレクトリ作成エラー - $e');
        return;
      }
    }

    // 実パスを持たないプラットフォーム（web）は、sqflite にパスを渡して
    // 開かせることができない。代わりに**チェックアウト**する
    // （元ファイルの中身を sqlite3 WASM 側へ流し込んでから開く）。
    await _checkOut(absPath);

    try {
      WidgetsFlutterBinding.ensureInitialized();

      // ⚠ sqflite の `version:` は使わない。あれは `PRAGMA user_version` を
      //    自分の版数で上書きする仕組みで、GeoPackage では user_version が
      //    規格の版（10200=1.2, 10300=1.3, 10301=1.3.1, 10400=1.4）を表す。
      //    以前は `version: 1` にしていたため、QGIS が作った .gpkg を開くだけで
      //    版が 1 に書き換わり、GDAL が「unrecognized user_version=0x00000001」
      //    と警告していた（2026-09-12 QGIS 4.2.0 で確認）
      _database = await openDatabase(_databaseKey(absPath));
      if (!await _hasGeoPackageCore(_database!)) {
        await _createDatabase(_database!);
      }

      // GeoPackageファイルの基本構造をチェック
      await _validateGeoPackageStructure();

      _isInitialized = true;
      _registeredKey = _registryKey(absPath);
      (_openConnections[_registeredKey!] ??= <GeoPackageConnection>{}).add(this);

      // web: 以降の書き込みを監視して元ファイルへ書き戻す
      _startCheckInWatcher();
    } catch (e, stack) {
      AppLogger.debug('[GeoPackageConnection] 初期化時にエラー発生:');
      AppLogger.debug('  パス: $absPath');
      AppLogger.debug('  エラー: $e');
      AppLogger.debug('  スタックトレース: $stack');

      try {
        AppLogger.debug(
          '  親ディレクトリ: $dirPath (存在: ${await fs.isDirectory(dirPath)})',
        );
      } catch (dirError) {
        AppLogger.debug('  親ディレクトリアクセスエラー: $dirError');
      }
    }
  }

  /// gpkg_contents があるか（無ければ新規の .gpkg として基本テーブルを作る）
  Future<bool> _hasGeoPackageCore(Database db) async {
    final rows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='gpkg_contents'",
    );
    return rows.isNotEmpty;
  }

  /// 新規 .gpkg の基本テーブルと版マーカー（OGC GeoPackage 1.3.1）
  Future<void> _createDatabase(Database db) async {
    // 'GPKG' と 1.3.1。GDAL/QGIS はこれを見て GeoPackage と認識する
    await db.execute('PRAGMA application_id = 0x47504B47');
    await db.execute('PRAGMA user_version = 10301');

    // 空間参照系テーブル
    await db.execute('''
      CREATE TABLE gpkg_spatial_ref_sys (
        srs_name TEXT NOT NULL,
        srs_id INTEGER NOT NULL PRIMARY KEY,
        organization TEXT NOT NULL,
        organization_coordsys_id INTEGER NOT NULL,
        definition TEXT NOT NULL,
        description TEXT
      );
    ''');

    // コンテンツテーブル
    await db.execute('''
      CREATE TABLE gpkg_contents (
        table_name TEXT NOT NULL PRIMARY KEY,
        data_type TEXT NOT NULL,
        identifier TEXT UNIQUE,
        description TEXT DEFAULT '',
        last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
        min_x DOUBLE,
        min_y DOUBLE,
        max_x DOUBLE,
        max_y DOUBLE,
        srs_id INTEGER,
        CONSTRAINT fk_gc_r_srs_id FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id)
      );
    ''');

    // ジオメトリカラムテーブル
    await db.execute('''
      CREATE TABLE gpkg_geometry_columns (
        table_name TEXT NOT NULL,
        column_name TEXT NOT NULL,
        geometry_type_name TEXT NOT NULL,
        srs_id INTEGER NOT NULL,
        z TINYINT NOT NULL,
        m TINYINT NOT NULL,
        CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name),
        CONSTRAINT uk_gc_table_name UNIQUE (table_name),
        CONSTRAINT fk_gc_tn FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name),
        CONSTRAINT fk_gc_srs FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys (srs_id)
      );
    ''');

    // 必須SRSレコード（WGS84, undefined geographic, undefined cartesian）
    await db.insert('gpkg_spatial_ref_sys', {
      'srs_name': 'WGS 84 geodetic',
      'srs_id': 4326,
      'organization': 'EPSG',
      'organization_coordsys_id': 4326,
      'definition':
          'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]]',
      'description':
          'longitude/latitude coordinates in decimal degrees on the WGS 84 spheroid',
    });

    await db.insert('gpkg_spatial_ref_sys', {
      'srs_name': 'Undefined geographic SRS',
      'srs_id': 0,
      'organization': 'NONE',
      'organization_coordsys_id': 0,
      'definition': 'undefined',
      'description': 'undefined geographic coordinate reference system',
    });

    await db.insert('gpkg_spatial_ref_sys', {
      'srs_name': 'Undefined cartesian SRS',
      'srs_id': -1,
      'organization': 'NONE',
      'organization_coordsys_id': -1,
      'definition': 'undefined',
      'description': 'undefined cartesian coordinate reference system',
    });
  }

  /// GeoPackageファイルの基本構造を検証
  Future<void> _validateGeoPackageStructure() async {
    if (_database == null) return;

    try {
      // 必須テーブルの存在チェック
      final tables = await _database!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table';",
      );
      final tableNames = tables.map((row) => row['name'] as String).toSet();

      // GeoPackage標準の必須テーブル
      final requiredTables = {
        'gpkg_contents',
        'gpkg_spatial_ref_sys',
        'gpkg_geometry_columns',
      };

      final missingTables = requiredTables.difference(tableNames);

      if (missingTables.isNotEmpty) {
        AppLogger.debug(
          '[GeoPackageConnection] ⚠️ 警告: GeoPackage標準テーブルが不足しています: $missingTables',
        );
        AppLogger.debug(
          '[GeoPackageConnection] ⚠️ これはRoot Maps標準形式ではない可能性があります。',
        );
        return;
      }

      // gpkg_contentsテーブルの構造チェック
      final contentsColumns = await _database!.rawQuery(
        'PRAGMA table_info("gpkg_contents");',
      );
      final contentsColumnNames =
          contentsColumns.map((row) => row['name'] as String).toSet();

      final requiredContentsColumns = {
        'table_name',
        'data_type',
        'identifier',
        'srs_id',
      };

      final missingContentsColumns = requiredContentsColumns.difference(
        contentsColumnNames,
      );

      if (missingContentsColumns.isNotEmpty) {
        AppLogger.debug(
          '[GeoPackageConnection] ⚠️ 警告: gpkg_contentsテーブルの構造が不正です。不足カラム: $missingContentsColumns',
        );
        AppLogger.debug('[GeoPackageConnection] ⚠️ このファイルは破損している可能性があります。');
      }

      // CRS情報のログ出力（非WGS84レイヤの検出）
      try {
        final srsRows = await _database!.rawQuery(
          'SELECT DISTINCT gc.srs_id, srs.srs_name, srs.organization, srs.organization_coordsys_id '
          'FROM gpkg_geometry_columns gc '
          'LEFT JOIN gpkg_spatial_ref_sys srs ON gc.srs_id = srs.srs_id',
        );
        for (final row in srsRows) {
          final srsId = row['srs_id'] as int?;
          if (srsId != null &&
              srsId != 4326 &&
              srsId != 0 &&
              srsId != -1 &&
              srsId != 6668) {
            final name = row['srs_name'] ?? 'Unknown';
            final org = row['organization'] ?? '';
            final orgId = row['organization_coordsys_id'] ?? srsId;
            AppLogger.debug(
              '[GeoPackageConnection] 🌍 非WGS84レイヤ検出: $org:$orgId ($name) - 読み込み時にWGS84にre-projection',
            );
          }
        }
      } catch (_) {
        // CRS検出はオプショナル - 失敗してもDB初期化には影響しない
      }
    } catch (e) {
      AppLogger.debug(
        '[GeoPackageConnection] ⚠️ 警告: GeoPackage構造の検証中にエラーが発生しました: $e',
      );
      AppLogger.debug(
        '[GeoPackageConnection] ⚠️ このファイルは標準的なGeoPackage形式ではない可能性があります。',
      );
    }
  }

  /// 空のGeoPackageファイルを明示的に作成（即座に初期化）
  Future<bool> createEmptyDatabase() async {
    try {
      await _initializeDatabase();
      if (_database != null && _isInitialized) {
        return true;
      } else {
        AppLogger.debug('[GeoPackageConnection] 空のGeoPackageファイル作成失敗: 初期化未完了');
        return false;
      }
    } catch (e) {
      AppLogger.debug('[GeoPackageConnection] 空のGeoPackageファイル作成エラー: $e');
      return false;
    }
  }

  /// データベースのクローズ処理
  Future<void> dispose() async {
    final key = _registeredKey;
    if (key != null) {
      final set = _openConnections[key];
      set?.remove(this);
      if (set != null && set.isEmpty) _openConnections.remove(key);
      _registeredKey = null;
    }
    if (_database != null) {
      final db = _database!;
      _database = null;
      // sqflite の singleInstance で同じパスの接続は1つの Database を共有している。
      // 先に誰かが閉じていれば、ここは閉じ済みのものを閉じるだけ
      if (db.isOpen) await db.close();
    }
    _checkInTimer?.cancel();
    _checkInTimer = null;
    _isInitialized = false;
    _initCompleter = null;
  }

  /// ファイル自体を削除（物理削除）
  Future<bool> deleteFile() async {
    try {
      // まずデータベース接続を閉じる
      await dispose();

      // 絶対パスが指定されている場合はそれを使用（グローバルフォルダ用）
      final String absPath;
      if (absolutePath != null) {
        absPath = absolutePath!;
      } else {
        if (projectRootDir == null) {
          AppLogger.debug(
            '[GeoPackageConnection] deleteFile: projectRootDirが未設定',
          );
          return false;
        }
        absPath = p.joinAll([projectRootDir!, ...pathList]);
      }
      if (!await fs.exists(absPath)) {
        AppLogger.debug(
          '[GeoPackageConnection] deleteFile: ファイルが存在しません - $absPath',
        );
        return true; // 既に存在しないので成功とみなす
      }

      await fs.delete(absPath);
      AppLogger.debug('[GeoPackageConnection] deleteFile: ファイル削除完了 - $absPath');
      return true;
    } catch (e, stack) {
      AppLogger.debug('[GeoPackageConnection] deleteFile: ファイル削除エラー - $e');
      AppLogger.debug('スタックトレース: $stack');
      return false;
    }
  }
}
