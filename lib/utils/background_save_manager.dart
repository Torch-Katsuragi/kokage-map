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

import 'package:root_maps/utils/app_logger.dart';

import '../models/geopackage/geopackage_file.dart';

/// 保留中の 1 セル
typedef _CellKey = ({String table, int rowId, String column});

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

    for (final MapEntry(key: geoPackageFile, value: changes)
        in changesToSave.entries) {
      try {
        await _saveChangesForGeoPackage(geoPackageFile, changes);
      } catch (e) {
        AppLogger.debug(
          '[ERROR] BackgroundSaveManager: Failed to save changes for GeoPackage: $e',
        );
        _requeue(geoPackageFile, changes);
      }
    }

    AppLogger.debug('[DEBUG] BackgroundSaveManager: Background save completed');
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

    for (final MapEntry(key: (tableName, rowId), value: attributes)
        in rows.entries) {
      final success = await geoPackageFile.updateFeatureAttributes(
        tableName,
        rowId,
        attributes,
      );
      if (!success) {
        AppLogger.debug(
          '[ERROR] BackgroundSaveManager: Failed to save attributes for $tableName:$rowId',
        );
        throw Exception('Failed to save attributes for $tableName:$rowId');
      }
    }
  }

  /// 指定されたGeoPackageFileの即座に全ての変更をDBに保存。
  /// 他のファイルの保留分はタイマーに任せる（ここでタイマーを止めると取り残される）
  Future<void> flushChanges(GeoPackageFile geoPackageFile) async {
    final changes = _pendingChanges.remove(geoPackageFile);
    if (changes == null || changes.isEmpty) return;
    try {
      await _saveChangesForGeoPackage(geoPackageFile, changes);
    } catch (e) {
      AppLogger.debug(
        '[ERROR] BackgroundSaveManager: Failed to flush changes: $e',
      );
      _requeue(geoPackageFile, changes);
    }
  }

  /// 全てのGeoPackageFileの変更を即座に保存
  Future<void> flushAllChanges() async {
    _saveTimer?.cancel();
    await _saveChangesToDB();
  }

  /// 指定されたGeoPackageFileの変更キューをクリア（dispose時）
  void clearPendingChanges(GeoPackageFile geoPackageFile) {
    _pendingChanges.remove(geoPackageFile);
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
    _pendingChanges.clear(); // 保存できなかった分は捨てる
    AppLogger.debug('[DEBUG] BackgroundSaveManager: Disposed');
  }
}
