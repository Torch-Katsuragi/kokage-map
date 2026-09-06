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
// Root Maps: フォルダメタデータサービス
// 継承チェーン解決・保存処理を担当

import '../core/fs/k_file_system.dart';
import '../models/kmeta.dart';
import '../models/nodes/layer_tree_node.dart';
import '../utils/app_logger.dart';
import 'sync_ledger.dart';

/// フォルダメタデータサービス
/// 継承チェーンを解決し、マージ済みメタデータを提供
class KMetaService {
  // シングルトン
  static final KMetaService instance = KMetaService._internal();
  factory KMetaService() => instance;
  KMetaService._internal();

  /// メタデータキャッシュ（フォルダパス → 生メタデータ）
  final Map<String, KMeta> _rawCache = {};

  /// マージ済みメタデータキャッシュ（フォルダパス → マージ済みメタデータ）
  final Map<String, KMeta> _mergedCache = {};

  /// キャッシュをクリア
  void clearCache() {
    _rawCache.clear();
    _mergedCache.clear();
    AppLogger.debug('[KMetaService] Cache cleared');
  }

  /// 特定フォルダのキャッシュをクリア（変更時に使用）
  void invalidateCache(String folderPath) {
    _rawCache.remove(folderPath);
    // マージ済みキャッシュは子フォルダも影響を受けるのでクリア
    _mergedCache.removeWhere((key, _) => key.startsWith(folderPath));
  }

  /// フォルダの生メタデータを取得（キャッシュ対応・バージョンゲート付き）
  Future<KMeta?> getRawMeta(String folderPath) async {
    if (_rawCache.containsKey(folderPath)) {
      return _rawCache[folderPath];
    }

    final loaded = await KMeta.loadFromFile(folderPath);
    if (loaded == null) return null;

    // バージョンゲート: 旧バージョンはsyncのみ保持して再保存
    if (loaded.version < kMetaSchemaVersion) {
      AppLogger.debug(
        '[KMetaService] 旧バージョン(v${loaded.version})検出、マイグレーション実行: $folderPath',
      );
      final migrated = KMeta(sync: loaded.sync);
      await saveMeta(folderPath, migrated);
      _rawCache[folderPath] = migrated;
      return migrated;
    }

    // 帳簿（端末ごとの同期状態）はアプリ私有領域から重ねる。
    // 旧版が共有ファイルに書いた帳簿が残っていれば、それを引き取って共有ファイルから剥がす
    final key = SyncLedger.keyFor(driveId: loaded.sync.driveId, folderPath: folderPath);
    var ledger = await SyncLedger.instance.read(key);
    var needsStrip = false;
    if (ledger == null && loaded.sync.hasBookkeeping) {
      ledger = SyncLedgerEntry.fromSync(loaded.sync);
      await SyncLedger.instance.write(key, ledger);
      needsStrip = true;
    }
    final meta = ledger == null
        ? loaded.copyWith(sync: loaded.sync.linkOnly())
        : loaded.copyWith(sync: ledger.applyTo(loaded.sync));

    _rawCache[folderPath] = meta;
    if (needsStrip) {
      AppLogger.debug('[KMetaService] 共有ファイルから同期帳簿を剥がす: $folderPath');
      await saveMeta(folderPath, meta);
    }
    return meta;
  }

  /// フォルダのメタデータを取得。
  ///
  /// > [!IMPORTANT] 継承チェーンは 2026-09-06 に廃止した
  /// > 以前は root からこの dir までの親の `visibility` / `styles.defaultStyle` / `layout` を
  /// > マージしていた。子 dir の見た目が親のファイルに依存すると、サブ dir 単体を持ち出した
  /// > ときに QGIS で見え方が変わる（`.qgs` 正典化と正面から矛盾する）。
  /// > いまは自フォルダの生メタデータそのもの。[projectRootDir] は互換のため残してある。
  Future<KMeta> getMergedMeta(String folderPath, {String? projectRootDir}) async {
    if (_mergedCache.containsKey(folderPath)) {
      return _mergedCache[folderPath]!;
    }

    final meta = await getRawMeta(folderPath) ?? KMeta.empty;
    _mergedCache[folderPath] = meta;
    return meta;
  }

  /// LayerTreeNodeからマージ済みメタデータを取得
  Future<KMeta> getMergedMetaForNode(LayerTreeNode node, {String? projectRootDir}) async {
    final folderPath = node.getAbsoluteFilePath();
    if (folderPath == null) {
      return KMeta.empty;
    }
    return getMergedMeta(folderPath, projectRootDir: projectRootDir);
  }

  /// 保存後に呼ばれる（`.qgs` の自動更新など）。アプリ起動時に配線する
  void Function(String folderPath)? onSaved;

  /// メタデータを保存
  /// キャッシュを先に更新し、並行 read-modify-write の変更消失を防止
  ///
  /// 共有ファイルにはリンク情報だけを書き、帳簿（`files` / `lastSynced` /
  /// `driveRevisionId` / `deviceId`）は [SyncLedger] に書く。
  Future<bool> saveMeta(String folderPath, KMeta meta) async {
    final prevRaw = _rawCache[folderPath];
    _rawCache[folderPath] = meta;
    _mergedCache.removeWhere((key, _) => key.startsWith(folderPath));

    final key = SyncLedger.keyFor(driveId: meta.sync.driveId, folderPath: folderPath);
    await SyncLedger.instance.write(key, SyncLedgerEntry.fromSync(meta.sync));

    final success = await meta.copyWith(sync: meta.sync.linkOnly()).saveToFile(folderPath);
    if (!success) {
      if (prevRaw != null) {
        _rawCache[folderPath] = prevRaw;
      } else {
        _rawCache.remove(folderPath);
      }
    } else {
      onSaved?.call(folderPath);
    }
    return success;
  }

  /// レイヤーの可視状態を更新
  /// [layerKey] はgpkgName/layerName形式（例: "survey.gpkg/points"）
  Future<bool> setLayerVisibility(
    String folderPath,
    String layerKey,
    bool visible,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final v = rawMeta.visibility;
    final updatedMeta = rawMeta.copyWith(
      visibility: KMetaVisibility(
        layers: {...v.layers, layerKey: visible},
        geopackages: v.geopackages,
        folders: v.folders,
        images: v.images,
        views: v.views,
      ),
    );
    return saveMeta(folderPath, updatedMeta);
  }

  /// GeoPackageの可視状態を更新
  Future<bool> setGeoPackageVisibility(
    String folderPath,
    String gpkgName,
    bool visible,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final v = rawMeta.visibility;
    final updatedMeta = rawMeta.copyWith(
      visibility: KMetaVisibility(
        layers: v.layers,
        geopackages: {...v.geopackages, gpkgName: visible},
        folders: v.folders,
        images: v.images,
        views: v.views,
      ),
    );
    return saveMeta(folderPath, updatedMeta);
  }

  /// フォルダの可視状態を更新
  Future<bool> setFolderVisibility(
    String folderPath,
    String folderName,
    bool visible,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final v = rawMeta.visibility;
    final updatedMeta = rawMeta.copyWith(
      visibility: KMetaVisibility(
        layers: v.layers,
        geopackages: v.geopackages,
        folders: {...v.folders, folderName: visible},
        images: v.images,
        views: v.views,
      ),
    );
    return saveMeta(folderPath, updatedMeta);
  }

  /// 画像の可視状態を更新
  Future<bool> setImageVisibility(
    String folderPath,
    String imageName,
    bool visible,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final v = rawMeta.visibility;
    final updatedMeta = rawMeta.copyWith(
      visibility: KMetaVisibility(
        layers: v.layers,
        geopackages: v.geopackages,
        folders: v.folders,
        images: {...v.images, imageName: visible},
        views: v.views,
      ),
    );
    return saveMeta(folderPath, updatedMeta);
  }

  /// Viewの可視状態を更新
  /// [viewKey] は `gpkgName/layerName/viewName` 形式
  Future<bool> setViewVisibility(
    String folderPath,
    String viewKey,
    bool visible,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final v = rawMeta.visibility;
    final updatedMeta = rawMeta.copyWith(
      visibility: KMetaVisibility(
        layers: v.layers,
        geopackages: v.geopackages,
        folders: v.folders,
        images: v.images,
        views: {...v.views, viewKey: visible},
      ),
    );
    return saveMeta(folderPath, updatedMeta);
  }

  /// レイヤのView定義をまるごと差し替える。
  ///
  /// **順序に意味がある**（同一レイヤ内の z順）ので、リストごと渡すこと。
  /// 空リストを渡すとキーごと消える＝「既定のView1枚」に戻る。
  Future<bool> setViews(
    String folderPath,
    String layerKey,
    List<KMetaView> views,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updated = Map<String, List<KMetaView>>.from(rawMeta.views);
    if (views.isEmpty) {
      updated.remove(layerKey);
    } else {
      updated[layerKey] = views;
    }
    return saveMeta(folderPath, rawMeta.copyWith(views: updated));
  }

  /// レイヤースタイルを更新
  /// [layerKey] はgpkgName/layerName形式（例: "survey.gpkg/points"）
  Future<bool> setLayerStyle(
    String folderPath,
    String layerKey,
    KMetaLayerStyle style,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updatedStyles = KMetaStyles(
      defaultStyle: rawMeta.styles.defaultStyle,
      layers: {...rawMeta.styles.layers, layerKey: style},
    );
    final updatedMeta = rawMeta.copyWith(styles: updatedStyles);
    return saveMeta(folderPath, updatedMeta);
  }

  /// デフォルトスタイルを更新
  Future<bool> setDefaultStyle(String folderPath, KMetaLayerStyle style) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updatedStyles = KMetaStyles(
      defaultStyle: style,
      layers: rawMeta.styles.layers,
    );
    final updatedMeta = rawMeta.copyWith(styles: updatedStyles);
    return saveMeta(folderPath, updatedMeta);
  }

  /// レイアウトの並び順を更新
  Future<bool> setSortOrder(String folderPath, List<String> sortOrder) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updatedLayout = KMetaLayout(
      sortOrder: sortOrder,
      expanded: rawMeta.layout.expanded,
    );
    final updatedMeta = rawMeta.copyWith(layout: updatedLayout);
    return saveMeta(folderPath, updatedMeta);
  }

  /// 展開状態を更新
  Future<bool> setExpanded(String folderPath, bool expanded) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updatedLayout = KMetaLayout(
      sortOrder: rawMeta.layout.sortOrder,
      expanded: expanded,
    );
    final updatedMeta = rawMeta.copyWith(layout: updatedLayout);
    return saveMeta(folderPath, updatedMeta);
  }

  /// Google Drive同期情報を更新
  Future<bool> setDriveSync(
    String folderPath, {
    String? driveId,
    String? driveFolderName,
    String? driveUrl,
    bool? isReadOnly,
    DateTime? lastSynced,
    String? driveRevisionId,
    String? deviceId,
    Map<String, KMetaSyncFile>? files,
  }) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updatedSync = KMetaSync(
      driveId: driveId ?? rawMeta.sync.driveId,
      driveFolderName: driveFolderName ?? rawMeta.sync.driveFolderName,
      driveUrl: driveUrl ?? rawMeta.sync.driveUrl,
      isReadOnly: isReadOnly ?? rawMeta.sync.isReadOnly,
      lastSynced: lastSynced ?? rawMeta.sync.lastSynced,
      driveRevisionId: driveRevisionId ?? rawMeta.sync.driveRevisionId,
      deviceId: deviceId ?? rawMeta.sync.deviceId,
      files: files ?? rawMeta.sync.files,
    );
    final updatedMeta = rawMeta.copyWith(sync: updatedSync);
    return saveMeta(folderPath, updatedMeta);
  }

  /// syncedFiles内のファイルパスを更新（ローカル移動/リネーム対応）
  ///
  /// [oldPrefix] に完全一致またはプレフィックス一致するキーを
  /// [newPrefix] に付け替える。driveFileId は維持される。
  Future<bool> renameSyncedFiles(
    String folderPath,
    String oldPrefix,
    String newPrefix,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final files = Map<String, KMetaSyncFile>.from(rawMeta.sync.files);
    if (files.isEmpty) return true;

    bool changed = false;
    final updates = <String, KMetaSyncFile>{};
    final removals = <String>[];

    for (final entry in files.entries) {
      if (entry.key == oldPrefix) {
        removals.add(entry.key);
        updates[newPrefix] = entry.value;
        changed = true;
      } else if (entry.key.startsWith('$oldPrefix/')) {
        final newKey = newPrefix + entry.key.substring(oldPrefix.length);
        removals.add(entry.key);
        updates[newKey] = entry.value;
        changed = true;
      }
    }

    if (!changed) return true;

    for (final key in removals) {
      files.remove(key);
    }
    files.addAll(updates);

    return setDriveSync(folderPath, files: files);
  }

  /// Drive連携を解除
  Future<bool> unlinkDrive(String folderPath) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    // deviceIdは維持し、Drive関連フィールドのみクリア
    final updatedSync = KMetaSync(deviceId: rawMeta.sync.deviceId);
    final updatedMeta = rawMeta.copyWith(sync: updatedSync);
    return saveMeta(folderPath, updatedMeta);
  }

  /// フォルダが.kmeta.jsonを持っているか確認
  Future<bool> hasMetaFile(String folderPath) =>
      fs.exists('$folderPath/$kMetaFileName');

  /// 新しい.kmeta.jsonを初期化（存在しない場合のみ）
  Future<KMeta?> initializeMetaIfNeeded(String folderPath) async {
    if (await hasMetaFile(folderPath)) {
      return getRawMeta(folderPath);
    }
    const newMeta = KMeta();
    if (await saveMeta(folderPath, newMeta)) {
      return newMeta;
    }
    return null;
  }

  /// 画像オーバーレイ設定を保存
  Future<bool> setImageOverlay(
    String folderPath,
    String imageName,
    KMetaImageOverlay overlay,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updatedOverlays = Map<String, KMetaImageOverlay>.from(rawMeta.imageOverlays);
    updatedOverlays[imageName] = overlay;
    final updatedMeta = rawMeta.copyWith(imageOverlays: updatedOverlays);
    return saveMeta(folderPath, updatedMeta);
  }

  /// 画像オーバーレイ設定を削除（通常のImageNodeに戻す）
  Future<bool> removeImageOverlay(
    String folderPath,
    String imageName,
  ) async {
    final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
    final updatedOverlays = Map<String, KMetaImageOverlay>.from(rawMeta.imageOverlays);
    updatedOverlays.remove(imageName);
    final updatedMeta = rawMeta.copyWith(imageOverlays: updatedOverlays);
    return saveMeta(folderPath, updatedMeta);
  }
}
