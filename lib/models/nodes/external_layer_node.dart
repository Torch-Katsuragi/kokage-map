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
// gpkg 以外の形式のファイル（shp・GeoJSON・KML など。GDAL で読む）を読み取り専用で開くノード
// 設計は docs/technical/external-formats.md#ノード

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../services/external/external_layer_cache.dart';
import '../../services/external/external_source.dart';
import '../../services/kmeta_service.dart';
import '../../utils/app_logger.dart';
import '../geopackage/geopackage_file.dart';
import 'folder_node.dart';
import 'geopackage_node.dart';
import 'layer_tree_node.dart';

/// 外部形式のファイル 1 本（shp は付属一式）＝ 1 ノード。
///
/// 描画・属性表・ヒットテストは裏のキャッシュ gpkg（[ExternalLayerCache]）に任せる。
/// [name] は元のファイル名（`林班.shp`）、[getAbsoluteFilePath] は元のファイルのパス。
/// 編集の入口は [isReadOnly] を見て閉じる（[isInReadOnlyLayer]）
class ExternalLayerNode extends GeoPackageNode {
  ExternalLayerNode._(
    super.geoPackageFile, {
    required this.sourcePath,
    super.visible,
    super.parent,
  });

  factory ExternalLayerNode(
    String sourcePath, {
    bool visible = true,
    LayerTreeNode? parent,
  }) => ExternalLayerNode._(
    GeoPackageFile([p.basename(sourcePath)], absolutePath: ExternalLayerCache.cachePathFor(sourcePath)),
    sourcePath: sourcePath,
    visible: visible,
    parent: parent,
  );

  /// 元のファイル（shp なら `.shp`）
  final String sourcePath;

  /// キャッシュを作ったときのレイヤの割り当て（元の GDAL のレイヤ・型の分け方）。読めていなければ null
  ExternalSourcePlan? sourcePlan;

  /// 常に読み取り専用（編集は gpkg へ変換してから）
  bool get isReadOnly => true;

  /// 最後に読めなかった理由（読めていれば null）。ツリーに出す
  String? loadError;

  @override
  String? getAbsoluteFilePath() => sourcePath;

  /// 元のファイル一式（自分 + 実在する付属ファイル）
  Future<List<String>> sourceFiles() => ExternalSource.files(sourcePath);

  @override
  Future<void> updateChildren() async {
    var rebuilt = false;
    try {
      rebuilt = await ExternalLayerCache.ensure(geoPackageFile, sourcePath);
      sourcePlan = await ExternalLayerCache.storedPlan(geoPackageFile);
      loadError = null;
    } catch (e) {
      AppLogger.debug('[ExternalLayerNode] 読めない: $sourcePath - $e');
      loadError = e.toString();
      children.clear();
      return;
    }
    await super.updateChildren();
    // 元が書き換わって作り直したら、読み込み済みのレイヤの地物も読み直す
    if (rebuilt) await reloadLoadedLayers();
  }

  /// 改名は元のファイル一式の改名（拡張子は変えない）。中のレイヤ名も新しい名前になるので、
  /// フォルダ設定の鍵（可視性・スタイル・View）を移す
  @override
  Future<String> rename(String newName, {required String projectRootDir}) async {
    final ext = p.extension(sourcePath);
    final oldStem = p.basenameWithoutExtension(sourcePath);
    final newStem = newName.toLowerCase().endsWith(ext.toLowerCase())
        ? newName.substring(0, newName.length - ext.length)
        : newName;
    if (newStem.isEmpty || newStem == oldStem) return p.basename(sourcePath);

    final dir = p.dirname(sourcePath);
    final moves = <(String, String)>[
      for (final from in await sourceFiles())
        if (p.basename(from).toLowerCase().startsWith(oldStem.toLowerCase()))
          (from, p.join(dir, '$newStem${p.basename(from).substring(oldStem.length)}')),
    ];
    for (final (_, to) in moves) {
      if (await fs.exists(to)) throw StateError('${p.basename(to)} は既にあります');
    }
    final oldLayers = await geoPackageFile.getLayerNames();
    await ExternalLayerCache.discard(geoPackageFile.getAbsolutePath()!);
    for (final (from, to) in moves) {
      await fs.rename(from, to);
    }

    final newFileName = '$newStem$ext';
    final folder = parent;
    final folderPath = folder is FolderNode ? folder.getAbsoluteFilePath() : null;
    if (folder is FolderNode && folderPath != null) {
      await KMetaService.instance.renameGeoPackageKeys(
        folderPath,
        oldName: name,
        newName: newFileName,
        layerNames: {
          for (final l in oldLayers)
            if (l == oldStem || l.startsWith('${oldStem}_')) l: '$newStem${l.substring(oldStem.length)}',
        },
      );
      folder.invalidateMetaCache();
    }
    return newFileName;
  }

  /// 元のファイル一式を消す。消せなかったものを返す
  Future<List<String>> deleteSourceFiles() async {
    final failed = <String>[];
    for (final path in await sourceFiles()) {
      try {
        await fs.delete(path);
      } catch (e) {
        AppLogger.debug('[ExternalLayerNode] 消せない: $path - $e');
        failed.add(path);
      }
    }
    return failed;
  }

  /// 利用者が消したとき: 元のファイル一式とキャッシュを消す（gpkg の削除と同じ扱い）。
  ///
  /// ⚠ ツリーの読み直し（`syncChildren`）で外れるだけのときは呼ばれない（何も消さない）
  @override
  Future<void> dispose() async {
    await deleteSourceFiles();
    await super.dispose(); // キャッシュ gpkg を消して親から外れる
    await ExternalLayerCache.discard(geoPackageFile.getAbsolutePath()!);
  }

  /// [parent] 直下の外部形式のファイルのノード（名前順）。
  /// [entries] を渡すと列挙をやり直さない（[FolderNode.loadNodes] と同じ理由）
  static Future<List<LayerTreeNode>> loadNodes(LayerTreeNode? parent, {List<KFileEntry>? entries}) async {
    if (parent is! FolderNode) return const [];
    final absPath = parent.getAbsoluteFilePath();
    if (absPath == null) return const [];
    final files = (entries ?? await fs.list(absPath)).where((e) => !e.isDirectory).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final nodes = <LayerTreeNode>[];
    for (final entry in files) {
      if (!ExternalSource.isCandidate(entry.path)) continue; // 速い足切り（中身は読まない）
      if (!await ExternalSource.accepts(entry.path)) continue;
      nodes.add(ExternalLayerNode(entry.path, parent: parent));
    }
    return nodes;
  }
}

/// [node]（レイヤ・View・地物・gpkg）が読み取り専用レイヤの中か
bool isInReadOnlyLayer(LayerTreeNode? node) =>
    node != null && (node is ExternalLayerNode || node.ancestorOf<ExternalLayerNode>() != null);
