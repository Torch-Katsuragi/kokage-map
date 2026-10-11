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
// 読み取り専用レイヤ（shp・GeoJSON など）の編集の門番と、gpkg への変換・複製の UI
// 設計は docs/technical/external-formats.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:path/path.dart' as p;

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/external_layer_node.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/folder_node.dart';
import '../models/nodes/geopackage_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/sys_node.dart';
import '../presentation/node_presenter.dart';
import '../providers/notification_providers.dart';
import '../providers/selection_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/external/external_layer_converter.dart';
import '../services/layer_drawer_service.dart';
import '../utils/app_logger.dart';
import '../utils/app_navigator.dart';
import 'layer_drawer/drawer_row.dart';

/// [node]（レイヤ・View・地物・gpkg）を含む読み取り専用レイヤ。無ければ null
ExternalLayerNode? readOnlyLayerOf(LayerTreeNode? node) =>
    node is ExternalLayerNode ? node : node?.ancestorOf<ExternalLayerNode>();

/// 変換・複製のあと、元の地物・レイヤ・gpkg に当たる新しいノードを受け取って編集の続きをする
typedef ReadOnlyConverted = FutureOr<void> Function(LayerTreeNode converted);

/// [node] が読み取り専用レイヤの中なら true（呼び手は編集をやめる）。
///
/// 画面があれば「gpkg に変換して編集しますか？」を出し（読み取り専用の Drive フォルダなら「自分のフォルダに複製」）、
/// 変換・複製できたら [onConverted] に新しい gpkg の中の同じもの（地物・レイヤ・gpkg）を渡す。
/// 画面が無ければ（テストなど）「gpkg に変換して編集」つきで通知する。
///
/// [onChanged] は変換・複製でツリーが変わったあとに呼ぶ（地図とツリーの描き直し）
bool refuseReadOnlyEdit(
  NotificationCenter center,
  LayerTreeNode? node, {
  VoidCallback? onChanged,
  ReadOnlyConverted? onConverted,
}) {
  final external = readOnlyLayerOf(node);
  if (external == null) return false;
  // 元のノードは変換でツリーから外れるので、新しい gpkg で探すための手がかりを先に取っておく
  final address = _ReadOnlyAddress.of(node!);
  Future<void> carryOn(GeoPackageNode? gpkg) async {
    if (gpkg == null || onConverted == null) return;
    await onConverted(await address.resolveIn(gpkg));
  }

  final context = appDialogContext;
  if (context == null) {
    center.add(
      title: t.externalLayer.readOnly(name: external.name),
      detail: t.externalLayer.readOnlyDetail,
      level: NotificationLevel.warning,
      actionLabel: t.externalLayer.convertAction,
      onAction: () async => carryOn(await convertExternalLayer(center, external, onChanged: onChanged)),
    );
    return true;
  }
  // 確かめている・変換しているあいだに別の口から来ても重ねて出さない（GPS の記録と描画の確定が続けて来るなど）
  if (_prompting) return true;
  _prompting = true;
  unawaited(() async {
    try {
      final GeoPackageNode? gpkg;
      if (ExternalLayerConverter.isInReadOnlyFolder(external)) {
        if (!await _confirmCopyExternalLayer(context, external) || !context.mounted) return;
        gpkg = await copyExternalLayer(center, external, context: context, onChanged: onChanged);
      } else {
        if (!await confirmConvertExternalLayer(context, external, title: t.externalLayer.editPrompt) ||
            !context.mounted) {
          return;
        }
        gpkg = await convertExternalLayer(center, external, onChanged: onChanged, context: context);
      }
      await carryOn(gpkg);
    } finally {
      _prompting = false;
    }
  }());
  return true;
}

/// [refuseReadOnlyEdit] の確認ダイアログを出している最中か
bool _prompting = false;

/// [refuseReadOnlyEdit] の ref 版（`ref.read` を渡す。WidgetRef でも Ref でもよい）。変換したら地図を描き直す。
///
/// [onConverted] を渡さなければ、変換・複製したレイヤを選ぶ（地物なら選択も移す）。そのまま描き足し・記録・属性の編集に戻れる
bool refuseReadOnlyEditBy(
  T Function<T>(ProviderListenable<T> provider) read,
  LayerTreeNode? node, {
  ReadOnlyConverted? onConverted,
}) {
  if (readOnlyLayerOf(node) == null) return false;
  // 変換を待つあいだに呼び手のウィジェットが消えても動くよう、先に取っておく（どれも keepAlive）
  final refresh = read(featureRefreshTriggerProvider.notifier);
  return refuseReadOnlyEdit(
    read(notificationCenterProvider.notifier),
    node,
    onChanged: refresh.trigger,
    onConverted: onConverted ?? selectConvertedBy(read),
  );
}

/// 変換・複製したものを選び直す（レイヤを選び、地物なら地物の選択も移す）。[refuseReadOnlyEditBy] の既定の続き
ReadOnlyConverted selectConvertedBy(T Function<T>(ProviderListenable<T> provider) read) {
  final selectedLayer = read(selectedLayerNodeProvider.notifier);
  final selectedFeatures = read(selectedFeaturesProvider.notifier);
  return (converted) {
    final layer = converted is LayerNode ? converted : converted.ancestorOf<LayerNode>();
    if (layer != null) selectedLayer.select(layer);
    if (converted is FeatureNode) selectedFeatures.set([converted]);
  };
}

/// 読み取り専用レイヤの中のノードの在りか（レイヤ名・地物の rowId）。
/// 変換・複製した gpkg はキャッシュ gpkg をそのまま写すので、レイヤ名も rowId も変わらない
class _ReadOnlyAddress {
  const _ReadOnlyAddress(this.layerName, this.rowId);

  factory _ReadOnlyAddress.of(LayerTreeNode node) {
    final layer = node is LayerNode ? node : node.ancestorOf<LayerNode>();
    return _ReadOnlyAddress(layer?.layerName, node is FeatureNode ? node.rowId : null);
  }

  final String? layerName;
  final int? rowId;

  /// [gpkg] の中で同じ地物・レイヤ。見つからなければ一段上（レイヤ、gpkg）
  Future<LayerTreeNode> resolveIn(GeoPackageNode gpkg) async {
    final layer = gpkg.children.whereType<LayerNode>().where((l) => l.layerName == layerName).firstOrNull;
    if (layer == null) return gpkg;
    if (rowId == null) return layer;
    if (layer.children.isEmpty) await layer.updateChildren();
    return layer.children.whereType<FeatureNode>().where((f) => f.rowId == rowId).firstOrNull ?? layer;
  }
}

/// 読み取り専用の Drive フォルダで編集しようとしたときの確認（置き換えられないので複製を勧める）。やめたら false
Future<bool> _confirmCopyExternalLayer(BuildContext context, ExternalLayerNode node) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.externalLayer.editPromptCopy),
      content: Text(t.externalLayer.editPromptCopyDetail(name: node.name)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.externalLayer.copyAction)),
      ],
    ),
  );
  return ok ?? false;
}

/// 変換の確認ダイアログ（何を作り何を消すかを見せる）。やめたら false。
/// [title] は見出し（既定は「gpkg に変換」。編集しようとしたときは「読み取り専用です。gpkg に変換して編集しますか？」）
Future<bool> confirmConvertExternalLayer(BuildContext context, ExternalLayerNode node, {String? title}) async {
  final files = (await node.sourceFiles()).map(p.basename).join('、');
  final target = await ExternalLayerConverter.uniqueGpkgPath(
    p.dirname(node.sourcePath),
    p.basenameWithoutExtension(node.sourcePath),
  );
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title ?? t.externalLayer.convertTitle),
      content: Text(t.externalLayer.convertConfirm(name: node.name, target: p.basename(target), files: files)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.externalLayer.convertTitle)),
      ],
    ),
  );
  return ok ?? false;
}

/// [node] を gpkg に変換し、結果を通知する。置き換えられない場所なら「自分のフォルダに gpkg として複製」を勧める。
/// 変換できたらできた gpkg のノード、それ以外は null
Future<GeoPackageNode?> convertExternalLayer(
  NotificationCenter center,
  ExternalLayerNode node, {
  VoidCallback? onChanged,
  BuildContext? context,
}) async {
  try {
    final result = await ExternalLayerConverter.convert(node);
    switch (result.outcome) {
      case ExternalConvertOutcome.converted:
        center.add(
          title: t.externalLayer.converted(name: node.name, target: p.basename(result.gpkgPath!)),
          level: NotificationLevel.success,
        );
        if (result.leftovers.isNotEmpty) {
          center.add(
            title: t.externalLayer.leftovers(files: result.leftovers.map(p.basename).join('、')),
            level: NotificationLevel.warning,
          );
        }
        onChanged?.call();
        return result.node;
      case ExternalConvertOutcome.readOnlyFolder || ExternalConvertOutcome.deleteFailed:
        center.add(
          title: result.outcome == ExternalConvertOutcome.readOnlyFolder
              ? t.externalLayer.readOnlyFolder
              : t.externalLayer.deleteFailed,
          level: NotificationLevel.warning,
          actionLabel: t.externalLayer.copyAction,
          onAction: () async {
            final ctx = context;
            await copyExternalLayer(center, node, context: ctx != null && ctx.mounted ? ctx : null, onChanged: onChanged);
          },
        );
      case ExternalConvertOutcome.copied:
        onChanged?.call();
        return result.node;
    }
  } on ExternalConvertVerifyException catch (e) {
    AppLogger.debug('[ExternalLayer] 変換をやめた: $e');
    center.add(title: t.externalLayer.verifyFailed, detail: e.detail, level: NotificationLevel.error);
  } catch (e) {
    AppLogger.debug('[ExternalLayer] 変換に失敗: $e');
    center.add(title: t.externalLayer.convertFailed(error: e.toString()), level: NotificationLevel.error);
  }
  return null;
}

/// 複製先にできるフォルダ（読み取り専用の Drive フォルダと「System」以外）
bool _isWritableFolder(LayerTreeNode n) =>
    n is FolderNode && n is! SysNode && !(LayerDrawerService.findDriveRoot(n)?.isReadOnly ?? false);

/// [node] を自分のフォルダへ gpkg として複製する（元は残す）。
/// [context] があれば複製先を選ばせ、無ければプロジェクトのルートへ。複製できたらできた gpkg のノード、それ以外は null
Future<GeoPackageNode?> copyExternalLayer(
  NotificationCenter center,
  ExternalLayerNode node, {
  BuildContext? context,
  VoidCallback? onChanged,
}) async {
  LayerTreeNode root = node;
  while (root.parent != null) {
    root = root.parent!;
  }
  FolderNode? target;
  if (context != null && context.mounted) {
    target = await _pickWritableFolder(context, node, root);
    if (target == null) return null; // やめた
  } else if (_isWritableFolder(root)) {
    target = root as FolderNode;
  }
  if (target == null) {
    center.add(title: t.externalLayer.noWritableFolder, level: NotificationLevel.warning);
    return null;
  }
  try {
    final result = await ExternalLayerConverter.copyAsGeoPackage(node, target);
    center.add(
      title: t.externalLayer.copied(name: node.name, target: p.basename(result.gpkgPath!)),
      level: NotificationLevel.success,
    );
    onChanged?.call();
    return result.node;
  } on ExternalConvertVerifyException catch (e) {
    center.add(title: t.externalLayer.verifyFailed, detail: e.detail, level: NotificationLevel.error);
  } catch (e) {
    center.add(title: t.externalLayer.convertFailed(error: e.toString()), level: NotificationLevel.error);
  }
  return null;
}

Future<FolderNode?> _pickWritableFolder(BuildContext context, ExternalLayerNode node, LayerTreeNode root) {
  final targets = <(FolderNode, int)>[];
  void walk(LayerTreeNode n, int depth) {
    if (n is SysNode) return;
    if (n is FolderNode) {
      if (_isWritableFolder(n)) targets.add((n, depth));
      for (final c in n.children) {
        walk(c, depth + 1);
      }
    }
  }

  walk(root, 0);
  return showDialog<FolderNode>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.externalLayer.copyTitle(name: node.name)),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: 360,
        height: 420,
        child: targets.isEmpty
            ? Center(child: Text(t.externalLayer.noWritableFolder))
            : ListView(
                children: [
                  for (final (n, depth) in targets)
                    DrawerRow(
                      depth: depth,
                      height: 44,
                      leading: Icon(NodePresenter.getIcon(n), size: 20, color: NodePresenter.getColor(n)),
                      title: NodePresenter.getDisplayName(n),
                      onTap: () => Navigator.pop(context, n),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel))],
    ),
  );
}
