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
/// 共有フォルダセットの入れ子展開・循環参照ガード・重複排除・読み取り専用伝播ロジック
library;

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'drive_folder_set_manifest.dart';
import 'drive_transfer_registry.dart';

/// 子セットの最大ネスト深さ（ルートセット = 0、最大 5 階層の子セットまで許可）
const int kFolderSetMaxDepth = 5;

/// 1つのルートセットツリー全体で展開するアイテム（子セット＋フォルダ）の最大総数
const int kFolderSetMaxTotalItems = 100;

/// ツリー展開全体で共有する走査コンテキスト（循環遮断・重複排除・総件数制限）
class FolderSetReconcileContext {
  final Set<String> visitedDriveIds;
  final String rootSetPath;
  final List<String> searchRoots;
  int processedItemCount = 0;

  FolderSetReconcileContext({
    Set<String>? initialVisitedIds,
    required this.rootSetPath,
    required this.searchRoots,
  }) : visitedDriveIds = {...?initialVisitedIds};
}

/// 途中の子セットから `reconcileSet` が呼ばれた場合も含めた初期状態
typedef FolderSetInitialState = ({
  Set<String> visitedIds,
  bool forceReadOnly,
  int depth,
  String rootSetPath,
});

/// マニフェスト項目の循環・重複・上限フィルタ結果
typedef FolderSetFilteredManifest = ({
  List<DriveFolderSetItem> desiredItems,
  Map<String, DriveFolderSetItem> desiredById,
  List<String> skippedCycleOrDuplicateItems,
});

/// 共有フォルダセットの階層解決・安全ガードの純粋/補助ロジック
class FolderSetHierarchy {
  const FolderSetHierarchy._();

  /// マニフェスト項目から循環参照・ダイヤモンド重複・総件数超過をフィルタする（First-Win）
  static FolderSetFilteredManifest filterManifestItems(
    DriveFolderSetManifest manifest,
    FolderSetReconcileContext context, {
    String? logSetPath,
    int maxTotalItems = kFolderSetMaxTotalItems,
  }) {
    final skipped = <String>[];
    final desiredItems = <DriveFolderSetItem>[];
    final desiredById = <String, DriveFolderSetItem>{};

    for (final item in manifest.items) {
      if (!context.visitedDriveIds.add(item.driveId)) {
        AppLogger.debug(
          '[DriveFolderSet] 循環参照または同一ツリー内の重複のためスキップ: ${item.driveId}'
          '${logSetPath != null ? ' (in $logSetPath)' : ''}',
        );
        skipped.add(item.driveId);
        continue;
      }
      if (context.processedItemCount >= maxTotalItems) {
        AppLogger.debug(
          '[DriveFolderSet] 最大アイテム総数 ($maxTotalItems) を超えたためスキップ: ${item.driveId}',
        );
        skipped.add(item.driveId);
        continue;
      }
      context.processedItemCount++;
      desiredItems.add(item);
      desiredById[item.driveId] = item;
    }

    return (
      desiredItems: desiredItems,
      desiredById: desiredById,
      skippedCycleOrDuplicateItems: skipped,
    );
  }

  /// JSONにパース不能な項目が混じっている場合や、既存フォルダがあるのにJSONが空配列になった場合は
  /// 記載ミスによる全消去事故を防ぐため削除フェーズをスキップする
  static bool shouldAllowDeletion({
    required DriveFolderSetManifest manifest,
    required bool hasExistingEntries,
  }) =>
      manifest.invalidEntryCount == 0 &&
      (manifest.items.isNotEmpty || !hasExistingEntries);

  /// 途中の子セットから直接 `reconcileSet` が呼ばれた場合でも、
  /// 祖先との循環参照・兄弟枝との重複・親からの `readOnly` 継承・現在の深さを正確に復元する
  static Future<FolderSetInitialState> buildInitialState({
    required String localSetPath,
    required DriveFolderSetNode? setNode,
    required bool forceReadOnly,
  }) async {
    final visitedIds = <String>{};
    var effectiveReadOnly = forceReadOnly || (setNode?.isReadOnly ?? false);

    // 1. メモリ上の親ノードチェーンから祖先 DriveFolderSetNode を辿る
    var memDepth = 0;
    for (var pNode = setNode?.parent; pNode != null; pNode = pNode.parent) {
      if (pNode is DriveFolderSetNode) {
        memDepth++;
        visitedIds.add(pNode.manifestFileId);
        if (pNode.isReadOnly) effectiveReadOnly = true;
      }
    }

    // 2. ディスク上の親ディレクトリチェーンから祖先フォルダセットを辿る
    final ancestorPaths = <String>[];
    var curr = p.dirname(localSetPath);
    while (curr != p.dirname(curr)) {
      try {
        final raw = await KMetaService.instance.getRawMeta(curr);
        if (raw == null || raw.sync.isFolderSet != true) break;
        ancestorPaths.add(curr);
        final id = raw.sync.driveId;
        if (id != null && id.isNotEmpty) {
          visitedIds.add(id);
        }
        curr = p.dirname(curr);
      } catch (_) {
        break;
      }
    }

    final rootSetPath =
        ancestorPaths.isNotEmpty ? ancestorPaths.last : localSetPath;
    if (ancestorPaths.isNotEmpty) {
      // 自身が子セットなら自身の KMetaSync.isReadOnly も反映
      try {
        final selfRaw = await KMetaService.instance.getRawMeta(localSetPath);
        if (selfRaw?.sync.isReadOnly == true) {
          effectiveReadOnly = true;
        }
      } catch (_) {}
      // ルート以外の途中祖先セットに isReadOnly == true があれば継承
      for (var i = 0; i < ancestorPaths.length - 1; i++) {
        try {
          final ancRaw =
              await KMetaService.instance.getRawMeta(ancestorPaths[i]);
          if (ancRaw?.sync.isReadOnly == true) {
            effectiveReadOnly = true;
          }
        } catch (_) {}
      }
      // ルートセット配下のうち、今回の localSetPath サブツリー外の既存 driveId を収集
      final topSetPath = ancestorPaths.last;
      await collectDriveIdsOutsideSubtree(
        currentDir: topSetPath,
        excludedSubtreePath: localSetPath,
        outIds: visitedIds,
      );
    }

    final depth =
        ancestorPaths.length > memDepth ? ancestorPaths.length : memDepth;
    return (
      visitedIds: visitedIds,
      forceReadOnly: effectiveReadOnly,
      depth: depth,
      rootSetPath: rootSetPath,
    );
  }

  /// [currentDir] 配下のうち、[excludedSubtreePath] サブツリー外の既存 `driveId` を [outIds] へ収集する
  static Future<void> collectDriveIdsOutsideSubtree({
    required String currentDir,
    required String excludedSubtreePath,
    required Set<String> outIds,
  }) async {
    if (DriveTransferRegistry.sameNormalizedPath(
      currentDir,
      excludedSubtreePath,
    )) {
      return;
    }

    try {
      final raw = await KMetaService.instance.getRawMeta(currentDir);
      final id = raw?.sync.driveId;
      if (id != null && id.isNotEmpty) {
        outIds.add(id);
      }
      if (raw != null && raw.sync.isLinked && raw.sync.isFolderSet != true) {
        // 通常の DriveFolderNode の内部には入らない
        return;
      }
      for (final member
          in raw?.sync.setMembers ?? const <KMetaFolderSetMember>[]) {
        if (member.driveId.isNotEmpty) {
          outIds.add(member.driveId);
        }
      }
      for (final entry in await fs.list(currentDir)) {
        if (!entry.isDirectory || entry.name.startsWith('.')) continue;
        await collectDriveIdsOutsideSubtree(
          currentDir: entry.path,
          excludedSubtreePath: excludedSubtreePath,
          outIds: outIds,
        );
      }
    } catch (_) {}
  }
}
