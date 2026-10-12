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
// Root Maps: バックグラウンド保存管理クラス（シングルトン）
// 複数のGeoPackageFileインスタンスのバックグラウンド保存を一元管理
import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';

import '../models/geopackage/geopackage_file.dart';
import '../models/geopackage/sql_identifier.dart';

/// 保留中の 1 セル
typedef _CellKey = ({String table, int rowId, String column});

/// 書けなかった変更（[failed] だけをキューに戻す）
class _SaveFailure implements Exception {
  _SaveFailure(this.failed);
  final Map<_CellKey, dynamic> failed;

  @override
  String toString() => 'Failed to save ${failed.length} attribute changes';
}

/// バックグラウンド保存を一元管理するシングルトンクラス
class BackgroundSaveManager {
  static final BackgroundSaveManager _instance =
      BackgroundSaveManager._internal();
  factory BackgroundSaveManager() => _instance;
  static BackgroundSaveManager get instance => _instance;

  BackgroundSaveManager._internal();

  /// 保存対象のGeoPackageFileとその変更キュー
  /// Key: GeoPackageFileインスタンス, Value: 変更キュー（(テーブル, 行ID, 列) → 値）
  final Map<GeoPackageFile, Map<_CellKey, dynamic>> _pendingChanges = {};

  /// バックグラウンド保存用のタイマー
  Timer? _saveTimer;

  /// 属性値の遅延保存間隔（ミリ秒）
  static const int _saveDelayMs = 1000;

  /// 書けなかった変更を書き直すまでの間（2 秒から倍々、最長 1 分）
  static const Duration _retryBase = Duration(seconds: 2);
  static const Duration _retryMax = Duration(minutes: 1);

  /// 続けて書けなかった回数（書けたら 0 に戻す）
  int _failedRounds = 0;

  /// この回数続けて書けなかったら [onPersistentFailure] で知らせる（2 + 4 + 8 秒、最初の失敗から 15 秒ほど）
  static const int _notifyAfterRounds = 3;

  /// 書き直しても保存できない状態が続いたとき（[_notifyAfterRounds] 回。続くあいだ 1 回だけ）と、
  /// 閉じるときに書けない変更を捨てたとき（[discarded]）に呼ぶ。通知センターに残す（main.dart で繋ぐ）。
  /// [pending] は書けていない変更の数、[files] はそのファイル名。
  ///
  /// > [!WARNING] 黙って失われていた（2026-10-12 Pixel 9）
  /// > QGIS 製の gpkg で属性の保存が ST_ 関数の無いトリガーで落ち続け、画面には新しい値が出たまま、
  /// > ファイルは変わらず、閉じると捨てていた。ログにしか出ていなかった
  void Function(int pending, List<String> files, {required bool discarded})? onPersistentFailure;

  /// 書けていない変更の数とファイル名
  (int, List<String>) _pendingSummary() {
    var count = 0;
    final files = <String>{};
    for (final MapEntry(key: gpkg, value: changes) in _pendingChanges.entries) {
      if (changes.isEmpty) continue;
      count += changes.length;
      final path = gpkg.getAbsolutePath();
      files.add(path == null ? '?' : p.basename(path));
    }
    return (count, files.toList()..sort());
  }

  /// 単一の属性値の遅延更新をキューに追加
  void queueAttributeUpdate(
    GeoPackageFile geoPackageFile,
    String tableName,
    int rowId,
    String attributeName,
    dynamic value,
  ) => queueAttributeUpdates(geoPackageFile, tableName, rowId, {
    attributeName: value,
  });

  /// 複数の属性値を一括で遅延更新キューに追加
  void queueAttributeUpdates(
    GeoPackageFile geoPackageFile,
    String tableName,
    int rowId,
    Map<String, dynamic> attributes,
  ) {
    final queue = _pendingChanges.putIfAbsent(geoPackageFile, () => {});
    for (final entry in attributes.entries) {
      queue[(table: tableName, rowId: rowId, column: entry.key)] = entry.value;
    }
    AppLogger.debug(
      '[DEBUG] BackgroundSaveManager: キューに追加 - テーブル:$tableName, 行ID:$rowId, 属性数:${attributes.length}, キュー:${queue.length}',
    );
    _scheduleSave();
  }

  /// 遅延保存のスケジュール（後から来た変更で 1 秒ずつ延びる）
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: _saveDelayMs),
      _saveChangesToDB,
    );
  }

  /// 保存に失敗した変更をキューに戻す（その間に積まれた新しい値は上書きしない）
  void _requeue(GeoPackageFile geoPackageFile, Map<_CellKey, dynamic> changes) {
    final queue = _pendingChanges.putIfAbsent(geoPackageFile, () => {});
    for (final e in changes.entries) {
      queue.putIfAbsent(e.key, () => e.value);
    }
  }

  /// 書けなかった変更の書き直しを予約する（間は倍々に延ばす）。
  /// ⚠ 以前は戻すだけでタイマーを掛け直さず、次の編集か閉じるまで書かれなかった（2026-10-12）。
  /// 新しい編集でタイマーが掛かっていればそれに任せる（書き直しのために編集の保存を遅らせない）
  void _scheduleRetry() {
    if (_pendingChanges.isEmpty) return;
    _failedRounds++;
    if (_failedRounds == _notifyAfterRounds) {
      final (count, files) = _pendingSummary();
      if (count > 0) onPersistentFailure?.call(count, files, discarded: false);
    }
    if (_saveTimer?.isActive ?? false) return;
    final ms = _retryBase.inMilliseconds << (_failedRounds - 1).clamp(0, 10);
    final delay = Duration(milliseconds: ms.clamp(0, _retryMax.inMilliseconds));
    AppLogger.debug('[DEBUG] BackgroundSaveManager: 書けなかった変更を ${delay.inSeconds} 秒後に書き直す');
    _saveTimer = Timer(delay, _saveChangesToDB);
  }

  /// 変更をDBに保存
  Future<void> _saveChangesToDB() async {
    if (_pendingChanges.isEmpty) return;

    final totalChanges = _pendingChanges.values.fold<int>(
      0,
      (sum, changes) => sum + changes.length,
    );

    AppLogger.debug(
      '[DEBUG] BackgroundSaveManager: Saving $totalChanges pending changes across ${_pendingChanges.length} GeoPackage files',
    );

    // キューごと取り出す（保存中に積まれた変更は新しい内側の Map に入る）
    final changesToSave = Map.of(_pendingChanges);
    _pendingChanges.clear();

    var failed = false;
    for (final MapEntry(key: geoPackageFile, value: changes)
        in changesToSave.entries) {
      if (!await _save(geoPackageFile, changes)) failed = true;
    }

    if (failed) {
      _scheduleRetry();
    } else {
      _failedRounds = 0;
    }
    AppLogger.debug('[DEBUG] BackgroundSaveManager: Background save completed');
  }

  /// [changes] を書く。書けなかった分はキューに戻して false
  Future<bool> _save(GeoPackageFile geoPackageFile, Map<_CellKey, dynamic> changes) async {
    try {
      await _saveChangesForGeoPackage(geoPackageFile, changes);
      return true;
    } on _SaveFailure catch (e) {
      AppLogger.debug('[ERROR] BackgroundSaveManager: $e');
      _requeue(geoPackageFile, e.failed);
    } catch (e) {
      AppLogger.debug(
        '[ERROR] BackgroundSaveManager: Failed to save changes for GeoPackage: $e',
      );
      _requeue(geoPackageFile, changes);
    }
    return false;
  }

  /// 特定のGeoPackageFileの変更を保存
  Future<void> _saveChangesForGeoPackage(
    GeoPackageFile geoPackageFile,
    Map<_CellKey, dynamic> changes,
  ) async {
    if (changes.isEmpty) return;
    AppLogger.debug(
      '[DEBUG] BackgroundSaveManager: Saving ${changes.length} changes for GeoPackage',
    );

    // テーブル・行ごとにまとめて 1 回で更新
    final rows = <(String, int), Map<String, dynamic>>{};
    for (final MapEntry(key: k, value: v) in changes.entries) {
      rows.putIfAbsent((k.table, k.rowId), () => {})[k.column] = v;
    }

    // 1 行書けなくてもほかの行は書く。以前は最初に失敗した行で止めて全部を戻していたので、
    // 保留中に消された地物が 1 つあると同じ gpkg のほかの変更がいつまでも書けず、閉じるときに捨てていた
    final failed = <_CellKey, dynamic>{};
    // 落としたトリガーが戻っていた（QGIS 向けに戻したあと・別の SQLite が作った）ときは、
    // 見回り直して落とし、すぐ 1 度だけ書き直す（書き直しの予約を待たない）
    var redropped = false;
    for (final MapEntry(key: (tableName, rowId), value: attributes)
        in rows.entries) {
      var success = await geoPackageFile.updateFeatureAttributes(
        tableName,
        rowId,
        attributes,
      );
      if (!success && !redropped) {
        redropped = true;
        if (await geoPackageFile.dropGdalTriggers() > 0) {
          AppLogger.debug('[DEBUG] BackgroundSaveManager: トリガーを落とし直して書き直す $tableName:$rowId');
          success = await geoPackageFile.updateFeatureAttributes(tableName, rowId, attributes);
        }
      }
      if (success) continue;
      if (await _rowGone(geoPackageFile, tableName, rowId)) {
        AppLogger.debug('[DEBUG] BackgroundSaveManager: 消えた地物の保留分を捨てる $tableName:$rowId');
        continue;
      }
      AppLogger.debug(
        '[ERROR] BackgroundSaveManager: Failed to save attributes for $tableName:$rowId',
      );
      for (final MapEntry(key: column, :value) in attributes.entries) {
        failed[(table: tableName, rowId: rowId, column: column)] = value;
      }
    }
    if (failed.isNotEmpty) throw _SaveFailure(failed);
  }

  /// 行がもう無いか（消された地物）。確かめられなければ false（変更は捨てずに戻す）
  Future<bool> _rowGone(GeoPackageFile geoPackageFile, String tableName, int rowId) async {
    try {
      final db = await geoPackageFile.getDatabase();
      final pk = await geoPackageFile.getPrimaryKeyColumn(tableName);
      final rows = await db.rawQuery(
        'SELECT 1 FROM ${quoteIdent(tableName)} WHERE ${pkEquals(pk)} LIMIT 1',
        [rowId],
      );
      return rows.isEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 指定されたGeoPackageFileの即座に全ての変更をDBに保存。
  /// 他のファイルの保留分はタイマーに任せる（ここでタイマーを止めると取り残される）
  Future<void> flushChanges(GeoPackageFile geoPackageFile) async {
    final changes = _pendingChanges.remove(geoPackageFile);
    if (changes == null || changes.isEmpty) return;
    if (!await _save(geoPackageFile, changes)) _scheduleRetry();
  }

  /// [absPath] を開いている GeoPackageFile の保留分をすぐ保存する（gpkg を外へ出す前）
  Future<void> flushChangesFor(String absPath) async {
    final key = p.canonicalize(absPath);
    for (final gpkg in _pendingChanges.keys.toList()) {
      final path = gpkg.getAbsolutePath();
      if (path != null && p.canonicalize(path) == key) await flushChanges(gpkg);
    }
  }

  /// 全てのGeoPackageFileの変更を即座に保存（アプリを裏に回したとき。書き直しの予約も前倒しする）
  Future<void> flushAllChanges() async {
    _saveTimer?.cancel();
    await _saveChangesToDB();
  }

  /// 指定されたGeoPackageFileの変更キューをクリア（dispose時）。
  /// 書けずに残っていた変更を捨てたら知らせる（[onPersistentFailure]）。ファイルごと消すとき（[reportDiscarded] が false）は知らせない
  void clearPendingChanges(GeoPackageFile geoPackageFile, {bool reportDiscarded = true}) {
    final dropped = _pendingChanges.remove(geoPackageFile);
    if (reportDiscarded && dropped != null && dropped.isNotEmpty) {
      final path = geoPackageFile.getAbsolutePath();
      onPersistentFailure?.call(dropped.length, [path == null ? '?' : p.basename(path)], discarded: true);
    }
    AppLogger.debug(
      '[DEBUG] BackgroundSaveManager: Cleared pending changes for GeoPackage',
    );
  }

  /// デバッグ用：現在の変更キューの状態を取得
  Map<GeoPackageFile, int> getPendingChangesStatus() {
    return _pendingChanges.map(
      (gpkg, changes) => MapEntry(gpkg, changes.length),
    );
  }

  /// アプリ終了時のクリーンアップ
  Future<void> dispose() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _saveChangesToDB(); // ファイルごとの失敗は中で拾う
    _saveTimer?.cancel(); // 書けなかった分の書き直しの予約も取り消す
    _saveTimer = null;
    _failedRounds = 0;
    final (count, files) = _pendingSummary();
    if (count > 0) onPersistentFailure?.call(count, files, discarded: true);
    _pendingChanges.clear(); // 保存できなかった分は捨てる（知らせてから）
    AppLogger.debug('[DEBUG] BackgroundSaveManager: Disposed');
  }
}
