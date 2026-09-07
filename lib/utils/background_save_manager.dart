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

/// バックグラウンド保存を一元管理するシングルトンクラス
class BackgroundSaveManager {
  static final BackgroundSaveManager _instance =
      BackgroundSaveManager._internal();
  factory BackgroundSaveManager() => _instance;
  static BackgroundSaveManager get instance => _instance;

  BackgroundSaveManager._internal();

  /// 保存対象のGeoPackageFileとその変更キュー
  /// Key: GeoPackageFileインスタンス, Value: 変更キュー
  final Map<GeoPackageFile, Map<String, dynamic>> _pendingChanges = {};

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
  ) {
    final key = '$tableName:$rowId:$attributeName';

    // GeoPackageFileごとの変更キューを取得または作成
    _pendingChanges.putIfAbsent(geoPackageFile, () => {});
    _pendingChanges[geoPackageFile]![key] = value;

    _scheduleSave();
  }

  /// 複数の属性値を一括で遅延更新キューに追加
  void queueAttributeUpdates(
    GeoPackageFile geoPackageFile,
    String tableName,
    int rowId,
    Map<String, dynamic> attributes,
  ) {
    AppLogger.debug('[DEBUG] BackgroundSaveManager: キューに追加 - テーブル:$tableName, 行ID:$rowId, 属性数:${attributes.length}');
    
    // GeoPackageFileごとの変更キューを取得または作成
    _pendingChanges.putIfAbsent(geoPackageFile, () => {});

    for (final entry in attributes.entries) {
      final key = '$tableName:$rowId:${entry.key}';
      _pendingChanges[geoPackageFile]![key] = entry.value;
      AppLogger.debug('[DEBUG] BackgroundSaveManager: キューエントリ追加 - $key = ${entry.value}');
    }
    
    AppLogger.debug('[DEBUG] BackgroundSaveManager: 現在のキューサイズ: ${_pendingChanges[geoPackageFile]?.length ?? 0}');
    _scheduleSave();
  }

  /// 遅延保存のスケジュール
  void _scheduleSave() {
    AppLogger.debug('[DEBUG] BackgroundSaveManager: 保存タイマーをスケジュール ($_saveDelayMs ms後)');
    
    // 既存のタイマーをキャンセル
    _saveTimer?.cancel();

    // 新しいタイマーを設定
    _saveTimer = Timer(const Duration(milliseconds: _saveDelayMs), () {
      AppLogger.debug('[DEBUG] BackgroundSaveManager: タイマー満了 - 保存処理開始');
      // 非同期関数を呼び出し（戻り値は無視）
      _saveChangesToDB();
    });
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

    // 変更を一時的に保存
    final changesToSave = Map<GeoPackageFile, Map<String, dynamic>>.from(
      _pendingChanges.map(
        (gpkg, changes) => MapEntry(gpkg, Map<String, dynamic>.from(changes)),
      ),
    );
    _pendingChanges.clear();

    // GeoPackageFileごとに変更を保存
    for (final entry in changesToSave.entries) {
      final geoPackageFile = entry.key;
      final changes = entry.value;

      try {
        await _saveChangesForGeoPackage(geoPackageFile, changes);
      } catch (e) {
        AppLogger.debug(
          '[ERROR] BackgroundSaveManager: Failed to save changes for GeoPackage: $e',
        );
        // 失敗した場合は変更キューに戻す
        _pendingChanges.putIfAbsent(geoPackageFile, () => {});
        _pendingChanges[geoPackageFile]!.addAll(changes);
      }
    }

    AppLogger.debug('[DEBUG] BackgroundSaveManager: Background save completed');
  }

  /// 特定のGeoPackageFileの変更を保存
  Future<void> _saveChangesForGeoPackage(
    GeoPackageFile geoPackageFile,
    Map<String, dynamic> changes,
  ) async {
    if (changes.isEmpty) return;

    try {
      AppLogger.debug(
        '[DEBUG] BackgroundSaveManager: Saving ${changes.length} changes for GeoPackage',
      );

      // テーブル別にグループ化して効率的に保存
      final Map<String, Map<int, Map<String, dynamic>>> groupedChanges = {};

      for (final entry in changes.entries) {
        final keyParts = entry.key.split(':');
        if (keyParts.length != 3) continue;

        final tableName = keyParts[0];
        final rowId = int.tryParse(keyParts[1]);
        final columnName = keyParts[2];

        if (rowId == null) continue;

        groupedChanges.putIfAbsent(tableName, () => {});
        groupedChanges[tableName]!.putIfAbsent(rowId, () => {});
        groupedChanges[tableName]![rowId]![columnName] = entry.value;
      }

      // テーブル別・行別に一括更新
      for (final tableEntry in groupedChanges.entries) {
        final tableName = tableEntry.key;
        for (final rowEntry in tableEntry.value.entries) {
          final rowId = rowEntry.key;
          final attributes = rowEntry.value;

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

      AppLogger.debug(
        '[DEBUG] BackgroundSaveManager: Successfully saved changes for GeoPackage',
      );
    } catch (e) {
      AppLogger.debug(
        '[ERROR] BackgroundSaveManager: _saveChangesForGeoPackage failed: $e',
      );
      rethrow;
    }
  }

  /// 指定されたGeoPackageFileの即座に全ての変更をDBに保存
  Future<void> flushChanges(GeoPackageFile geoPackageFile) async {
    _saveTimer?.cancel();

    final changes = _pendingChanges[geoPackageFile];
    if (changes != null && changes.isNotEmpty) {
      final changesToSave = Map<String, dynamic>.from(changes);
      _pendingChanges[geoPackageFile]!.clear();

      try {
        await _saveChangesForGeoPackage(geoPackageFile, changesToSave);
      } catch (e) {
        AppLogger.debug('[ERROR] BackgroundSaveManager: Failed to flush changes: $e');
        // 失敗した場合は変更キューに戻す
        _pendingChanges[geoPackageFile]!.addAll(changesToSave);
      }
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
    // タイマーをキャンセル
    _saveTimer?.cancel();
    _saveTimer = null;

    // 保留中の変更を保存
    if (_pendingChanges.isNotEmpty) {
      try {
        await _saveChangesToDB();
      } catch (e) {
        AppLogger.debug('[ERROR] BackgroundSaveManager.dispose: $e');
      }
    }

    // キューをクリア
    _pendingChanges.clear();
    AppLogger.debug('[DEBUG] BackgroundSaveManager: Disposed');
  }
}

