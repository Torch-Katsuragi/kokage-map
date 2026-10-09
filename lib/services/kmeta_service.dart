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

import 'dart:async';

import 'package:path/path.dart' as p;

import '../models/kmeta.dart';
import '../utils/app_logger.dart';
import 'qgis/qgs_meta_store.dart';
import 'sync_ledger.dart';

/// フォルダメタデータサービス
/// フォルダ設定の読み書きとキャッシュ。フォルダ設定は自己完結（親からの継承は無い）
///
/// > [!IMPORTANT] 置き場所は `<dir名>.qgs`（2026-09-29〜）
/// > `.kmeta.json` をやめ、`.qgs` の `kokage/meta` に書く（[QgsMetaStore]）。
/// > 旧 `.kmeta.json` は読んだときに移して `.kmeta.json.migrated` に改名する。
class KMetaService {
  // シングルトン
  static final KMetaService instance = KMetaService._internal();
  factory KMetaService() => instance;
  KMetaService._internal();

  /// メタデータキャッシュ（フォルダパス → メタデータ）
  final Map<String, KMeta> _rawCache = {};

  /// 設定を持たないと分かっている dir（ツリーを開くたびに dir を列挙し直さない）
  final Set<String> _noMeta = {};

  /// キャッシュをクリア
  void clearCache() {
    _rawCache.clear();
    _noMeta.clear();
    AppLogger.debug('[KMetaService] Cache cleared');
  }

  /// 特定フォルダのキャッシュをクリア（変更時に使用）
  void invalidateCache(String folderPath) {
    _rawCache.remove(folderPath);
    _noMeta.remove(folderPath);
  }

  /// フォルダの生メタデータを取得（キャッシュ対応・バージョンゲート付き）
  Future<KMeta?> getRawMeta(String folderPath) async {
    if (_rawCache.containsKey(folderPath)) {
      return _rawCache[folderPath];
    }
    if (_noMeta.contains(folderPath)) return null;

    final loaded = await QgsMetaStore.read(folderPath, onMigrated: () => onSaved?.call(folderPath));
    if (loaded == null) {
      _noMeta.add(folderPath);
      return null;
    }
    // 旧版（v1）の設定も捨てずにそのまま読む（以前は sync 以外を捨てて保存し直していた）

    // 帳簿（端末ごとの同期状態）はアプリ私有領域から重ねる。
    // 旧版が共有ファイルに書いた帳簿が残っていれば、それを引き取って共有ファイルから剥がす
    final key = await SyncLedger.instance.resolveKey(driveId: loaded.sync.driveId, folderPath: folderPath);
    var ledger = await SyncLedger.instance.read(key);
    var needsStrip = false;
    if (ledger == null && loaded.sync.hasBookkeeping) {
      ledger = SyncLedgerEntry.fromSync(loaded.sync).withOwner(folderPath);
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

  /// フォルダのメタデータを取得（無ければ [KMeta.empty]）。
  ///
  /// > [!IMPORTANT] 親からの継承チェーンは 2026-09-06 に廃止した
  /// > 以前は root からこの dir までの親の `visibility` / `styles.defaultStyle` / `layout` を
  /// > マージしていた。子 dir の見た目が親のファイルに依存すると、サブ dir 単体を持ち出した
  /// > ときに QGIS で見え方が変わる（`.qgs` 正典化と正面から矛盾する）。
  Future<KMeta> getMeta(String folderPath) async =>
      await getRawMeta(folderPath) ?? KMeta.empty;

  /// 保存後に呼ばれる（`.qgs` の自動更新など）。アプリ起動時に配線する
  void Function(String folderPath)? onSaved;

  /// 同じ dir の設定の「読んで直して書く」を 1 本ずつにする（並行すると片方の変更が消える）
  final Map<String, Future<void>> _serialTails = {};

  Future<T> _serial<T>(String folderPath, Future<T> Function() body) async {
    final previous = _serialTails[folderPath] ?? Future<void>.value();
    final done = Completer<void>();
    _serialTails[folderPath] = done.future;
    try {
      await previous;
    } on Object {
      // 前の変更の失敗は持ち込まない
    }
    try {
      return await body();
    } finally {
      done.complete();
      if (identical(_serialTails[folderPath], done.future)) unawaited(_serialTails.remove(folderPath));
    }
  }

  /// メタデータを保存
  /// キャッシュを先に更新し、並行 read-modify-write の変更消失を防止
  ///
  /// 共有ファイルにはリンク情報だけを書き、帳簿（`files` / `lastSynced` /
  /// `driveRevisionId` / `deviceId`）は [SyncLedger] に書く。
  Future<bool> saveMeta(String folderPath, KMeta meta) async {
    final prevRaw = _rawCache[folderPath];
    _rawCache[folderPath] = meta;
    _noMeta.remove(folderPath);

    final key = await SyncLedger.instance.resolveKey(driveId: meta.sync.driveId, folderPath: folderPath);
    await SyncLedger.instance.write(key, SyncLedgerEntry.fromSync(meta.sync).withOwner(folderPath));

    final success = await QgsMetaStore.write(folderPath, meta.copyWith(sync: meta.sync.linkOnly()));
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
    return _serial(folderPath, () async {
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
    });
  }

  /// GeoPackageの可視状態を更新
  Future<bool> setGeoPackageVisibility(
    String folderPath,
    String gpkgName,
    bool visible,
  ) async {
    return _serial(folderPath, () async {
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
    });
  }

  /// 消した gpkg（[gpkgName]）の設定を落とす（可視状態・中のレイヤと View の可視状態・スタイル・View）。
  /// 何も持っていなければ書かない
  Future<bool> forgetGeoPackage(String folderPath, String gpkgName) {
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath);
      if (rawMeta == null) return true;
      final prefix = '$gpkgName/';
      bool keep(String key) => !key.startsWith(prefix);
      final v = rawMeta.visibility;
      final s = rawMeta.styles;
      final touched = v.geopackages.containsKey(gpkgName) ||
          !v.layers.keys.every(keep) ||
          !v.views.keys.every(keep) ||
          !s.layers.keys.every(keep) ||
          !rawMeta.views.keys.every(keep);
      if (!touched) return true;
      final updatedMeta = rawMeta.copyWith(
        visibility: KMetaVisibility(
          layers: {for (final e in v.layers.entries) if (keep(e.key)) e.key: e.value},
          geopackages: {...v.geopackages}..remove(gpkgName),
          folders: v.folders,
          images: v.images,
          views: {for (final e in v.views.entries) if (keep(e.key)) e.key: e.value},
        ),
        styles: KMetaStyles(
          defaultStyle: s.defaultStyle,
          layers: {for (final e in s.layers.entries) if (keep(e.key)) e.key: e.value},
        ),
        views: {for (final e in rawMeta.views.entries) if (keep(e.key)) e.key: e.value},
      );
      return saveMeta(folderPath, updatedMeta);
    });
  }

  /// フォルダの可視状態を更新
  Future<bool> setFolderVisibility(
    String folderPath,
    String folderName,
    bool visible,
  ) async {
    return _serial(folderPath, () async {
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
    });
  }

  /// 画像の可視状態を更新
  Future<bool> setImageVisibility(
    String folderPath,
    String imageName,
    bool visible,
  ) async {
    return _serial(folderPath, () async {
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
    });
  }

  /// Viewの可視状態を更新
  /// [viewKey] は `gpkgName/layerName/viewName` 形式
  Future<bool> setViewVisibility(
    String folderPath,
    String viewKey,
    bool visible,
  ) async {
    return _serial(folderPath, () async {
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
    });
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
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
      final updated = Map<String, List<KMetaView>>.from(rawMeta.views);
      if (views.isEmpty) {
        updated.remove(layerKey);
      } else {
        updated[layerKey] = views;
      }
      return saveMeta(folderPath, rawMeta.copyWith(views: updated));
    });
  }

  /// レイヤースタイルを更新
  /// [layerKey] はgpkgName/layerName形式（例: "survey.gpkg/points"）
  Future<bool> setLayerStyle(
    String folderPath,
    String layerKey,
    KMetaLayerStyle style,
  ) async {
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
      final updatedStyles = KMetaStyles(
        defaultStyle: rawMeta.styles.defaultStyle,
        layers: {...rawMeta.styles.layers, layerKey: style},
      );
      final updatedMeta = rawMeta.copyWith(styles: updatedStyles);
      return saveMeta(folderPath, updatedMeta);
    });
  }

  /// gpkg（相当のノード）の名前が変わったとき、その下のレイヤ・View の鍵を新しい名前へ移す。
  ///
  /// 可視性（gpkg・レイヤ・View）・スタイル・View 定義・並び順の鍵を `<旧>/…` から `<新>/…` へ。
  /// [layerNames] にあるレイヤは名前も替える（読み取り専用レイヤの改名で、中のレイヤ名が変わるとき）。
  /// 移す先に既に鍵があれば上書きする。何も無ければ書かない
  Future<bool> renameGeoPackageKeys(
    String folderPath, {
    required String oldName,
    required String newName,
    Map<String, String> layerNames = const {},
  }) async {
    if (oldName == newName && layerNames.isEmpty) return true;
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath);
      if (rawMeta == null) return true;
      final prefix = '$oldName/';
      var changed = false;

      // `<旧>/<レイヤ>[/<残り>]` → `<新>/<新レイヤ>[/<残り>]`。対象でなければ null
      String? moveKey(String key) {
        if (!key.startsWith(prefix)) return null;
        final rest = key.substring(prefix.length);
        for (final MapEntry(key: from, value: to) in layerNames.entries) {
          if (rest == from) return '$newName/$to';
          if (rest.startsWith('$from/')) return '$newName/$to${rest.substring(from.length)}';
        }
        return '$newName/$rest';
      }

      Map<String, T> moveAll<T>(Map<String, T> source) {
        final out = <String, T>{};
        final moved = <String, T>{};
        for (final MapEntry(:key, :value) in source.entries) {
          final to = moveKey(key);
          if (to == null) {
            out[key] = value;
          } else {
            moved[to] = value;
            changed = true;
          }
        }
        return {...out, ...moved};
      }

      final v = rawMeta.visibility;
      final geopackages = {...v.geopackages};
      if (geopackages.containsKey(oldName)) {
        geopackages[newName] = geopackages.remove(oldName)!;
        changed = true;
      }
      final sortOrder = rawMeta.layout.sortOrder;
      final newSortOrder = sortOrder?.map((n) => n == oldName ? newName : n).toList();
      if (sortOrder != null && sortOrder.contains(oldName)) changed = true;

      final updated = rawMeta.copyWith(
        visibility: KMetaVisibility(
          layers: moveAll(v.layers),
          geopackages: geopackages,
          folders: v.folders,
          images: v.images,
          views: moveAll(v.views),
        ),
        styles: KMetaStyles(defaultStyle: rawMeta.styles.defaultStyle, layers: moveAll(rawMeta.styles.layers)),
        views: moveAll(rawMeta.views),
        layout: KMetaLayout(sortOrder: newSortOrder, expanded: rawMeta.layout.expanded),
      );
      if (!changed) return true;
      return saveMeta(folderPath, updated);
    });
  }

  /// 展開状態を更新
  Future<bool> setExpanded(String folderPath, bool expanded) async {
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
      final updatedLayout = KMetaLayout(
        sortOrder: rawMeta.layout.sortOrder,
        expanded: expanded,
      );
      final updatedMeta = rawMeta.copyWith(layout: updatedLayout);
      return saveMeta(folderPath, updatedMeta);
    });
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
    return _serial(folderPath, () async {
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
    });
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
      // 元のパスを残す（まだ Drive に反映していない移動。何度動かしても最初の場所）
      final moved = entry.value.copyWith(movedFrom: entry.value.movedFrom ?? entry.key);
      if (entry.key == oldPrefix) {
        removals.add(entry.key);
        updates[newPrefix] = moved;
        changed = true;
      } else if (entry.key.startsWith('$oldPrefix/')) {
        final newKey = newPrefix + entry.key.substring(oldPrefix.length);
        removals.add(entry.key);
        updates[newKey] = moved;
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
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
      // deviceIdは維持し、Drive関連フィールドのみクリア
      final updatedSync = KMetaSync(deviceId: rawMeta.sync.deviceId);
      final updatedMeta = rawMeta.copyWith(sync: updatedSync);
      return saveMeta(folderPath, updatedMeta);
    });
  }

  /// フォルダが自分の設定（`.qgs`、または移す前の `.kmeta.json`）を持っているか
  ///
  /// 読んだ結果はキャッシュに載るので、ツリーを読み込んだあとは dir を列挙し直さない
  Future<bool> hasMetaFile(String folderPath) async => await getRawMeta(folderPath) != null;

  /// 同期で `.qgs` を上書きダウンロードする前に呼ぶ。この端末のリンク情報を返す。
  ///
  /// リンク情報（driveId・読み取り専用か…）は端末ごとに違いうるので、ダウンロードした
  /// `.qgs` のもので上書きしない。[absPath] がどこかの dir の `.qgs` でなければ null。
  Future<KMetaSync?> linkBeforeReplace(String absPath) async {
    if (!absPath.toLowerCase().endsWith('.qgs')) return null;
    final dir = p.dirname(absPath);
    final meta = await getRawMeta(dir);
    if (meta == null || p.basename(absPath) != p.basename(QgsProjectFile.pathFor(dir, meta))) return null;
    return meta.sync;
  }

  /// 同期で `.qgs` を上書きダウンロードした直後に呼ぶ（同期済みと記録する前に）。
  ///
  /// キャッシュを捨てて読み直し、この端末のリンク情報 [keep] を戻す。
  /// ダウンロードしたものと同じなら書かない（書くと次の同期でまた上がる）。
  Future<void> afterReplace(String absPath, KMetaSync? keep) async {
    if (!absPath.toLowerCase().endsWith('.qgs')) return;
    final dir = p.dirname(absPath);
    invalidateCache(dir);
    if (keep == null || !keep.isLinked) return;
    final meta = await getRawMeta(dir) ?? KMeta.empty;
    final s = meta.sync;
    if (s.driveId == keep.driveId &&
        s.driveUrl == keep.driveUrl &&
        s.driveFolderName == keep.driveFolderName &&
        s.isReadOnly == keep.isReadOnly) {
      return;
    }
    await saveMeta(
      dir,
      meta.copyWith(
        sync: KMetaSync(
          driveId: keep.driveId,
          driveFolderName: keep.driveFolderName,
          driveUrl: keep.driveUrl,
          isReadOnly: keep.isReadOnly,
          lastSynced: s.lastSynced,
          driveRevisionId: s.driveRevisionId,
          deviceId: s.deviceId,
          files: s.files,
        ),
      ),
    );
  }

  /// 画像オーバーレイ設定を保存
  Future<bool> setImageOverlay(
    String folderPath,
    String imageName,
    KMetaImageOverlay overlay,
  ) async {
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
      final updatedOverlays = Map<String, KMetaImageOverlay>.from(rawMeta.imageOverlays);
      updatedOverlays[imageName] = overlay;
      final updatedMeta = rawMeta.copyWith(imageOverlays: updatedOverlays);
      return saveMeta(folderPath, updatedMeta);
    });
  }

  /// 画像オーバーレイ設定を削除（通常のImageNodeに戻す）
  Future<bool> removeImageOverlay(
    String folderPath,
    String imageName,
  ) async {
    return _serial(folderPath, () async {
      final rawMeta = await getRawMeta(folderPath) ?? KMeta.empty;
      final updatedOverlays = Map<String, KMetaImageOverlay>.from(rawMeta.imageOverlays);
      updatedOverlays.remove(imageName);
      final updatedMeta = rawMeta.copyWith(imageOverlays: updatedOverlays);
      return saveMeta(folderPath, updatedMeta);
    });
  }
}
