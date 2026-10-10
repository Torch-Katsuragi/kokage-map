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
// Root Maps: グローバルフォルダノードクラス
// どのプロジェクトを開いても表示される共有フォルダ
// 実体はアプリケーションのDocumentsディレクトリに存在
//
// NOTE: 将来的にはFolderNode + GlobalPathResolverで代替予定
// 現在はPathResolverを注入してisGlobalNodeを自動判定

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/path_resolver.dart';
import '../../services/geotiff_service.dart';
import '../../services/google_drive/sync_base_store.dart';
import '../../utils/exif_parser.dart';
import '../geopackage/geopackage_file.dart';
import '../kmeta.dart';
import 'external_overlay_image_node.dart';
import 'folder_node.dart';
import 'geopackage_node.dart';
import 'image_node.dart';
import 'layer_tree_node.dart';
import 'overlay_image_node.dart';

/// [node] から上へ、グローバルフォルダの手前までの名前（上から順）と、そのグローバルフォルダ。
/// グローバルフォルダが無ければ根までの名前と null
(GlobalFolderNode?, List<String>) segmentsBelowGlobalFolder(LayerTreeNode node) {
  final segments = <String>[];
  LayerTreeNode? current = node;
  while (current != null && current is! GlobalFolderNode) {
    segments.insert(0, current.name);
    current = current.parent;
  }
  return (current as GlobalFolderNode?, segments);
}

/// グローバルフォルダとその下のサブフォルダの子の作り方（どちらも [_globalBase] 起点の絶対パスで作る）
///
/// 通常のフォルダとの違い: 点で始まるフォルダも見せる・画像は .gif/.webp も読む・
/// 子は Global* のノードにする・ファイルシステムに無い子は全部外す
mixin _GlobalChildren on FolderNode {
  /// グローバルフォルダの実体パス
  String get _globalBase;

  @override
  bool keepsChild(LayerTreeNode child) => false;

  @override
  Future<List<LayerTreeNode>> loadFolderNodes(List<KFileEntry> entries) async {
    final nodes = <LayerTreeNode>[];
    final directories = entries
        .where((e) => e.isDirectory && e.name != SyncBaseStore.dirName) // 3-way マージの base 置き場は見せない
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in directories) {
      // フォルダ設定（`.qgs`）にDrive連携情報があればDriveFolderNodeとして作成
      nodes.add(
        await FolderNode.tryCreateDriveFolderNode(entity.path, entity.name, this) ??
            GlobalSubFolderNode(
              entity.name,
              basePath: _globalBase,
              visible: true,
              parent: this,
              children: [],
            ),
      );
    }
    return nodes;
  }

  @override
  Future<List<LayerTreeNode>> loadGeoPackageNodes(List<KFileEntry> entries) async {
    final gpkgFiles = entries
        .where((e) => !e.isDirectory && e.path.endsWith('.gpkg'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return [
      for (final entity in gpkgFiles)
        // 絶対パスモードでGeoPackageFileを作成
        GlobalGeoPackageNode(
          GeoPackageFile([entity.name], absolutePath: entity.path),
          parent: this,
        ),
    ];
  }

  @override
  Future<List<LayerTreeNode>> loadImageNodes(List<KFileEntry> entries) async {
    final nodes = <LayerTreeNode>[];
    const supportedExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.tiff', '.tif', '.jp2', '.vrt'];
    final siblingNames = {for (final e in entries) if (!e.isDirectory) e.name.toLowerCase()};
    final imageFiles = entries
        .where((e) =>
            !e.isDirectory &&
            supportedExtensions.contains(p.extension(e.path).toLowerCase()))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in imageFiles) {
      final ext = p.extension(entity.path).toLowerCase();
      final isTiff = ext == '.tif' || ext == '.tiff';

      // GeoTIFFタグの判定（.tifファイルのみ）
      KMetaImageOverlay? overlayParams;
      if (isTiff) {
        final bytes = await fs.readAsBytes(entity.path);
        overlayParams = GeoTiffService.readGeoTiffParams(bytes);
      }

      if (overlayParams != null) {
        nodes.add(await GlobalOverlayImageNode._fromGeoTiff(
          entity.path, overlayParams, parent: this,
        ));
        continue;
      }
      // QGIS / GDAL で作ったラスタ（読み取り専用のオーバーレイ）
      final external = await ExternalOverlayImageNode.tryCreate(entity.path, siblingNames, parent: this);
      if (external != null) {
        nodes.add(external);
      } else if (ext != '.jp2' && ext != '.vrt') {
        final node = await GlobalImageNode.fromPath(entity.path, parent: this);
        if (node != null) nodes.add(node);
      }
    }
    return nodes;
  }
}

/// グローバルフォルダノード
/// - どのプロジェクトを開いても「System」（`SysNode`）の下に表示される（2026-09-25 まではルート直下）
/// - 実体の置き場所は GlobalFolderLocator が決める
///   （Android: 共有ストレージ `Documents/KokageMap/Global`。旧: アプリ内部の k_maps_global）
/// - 青色アイコンで通常フォルダと差別化（NodePresenter経由）
class GlobalFolderNode extends FolderNode with _GlobalChildren {
  /// グローバルフォルダの実体パス
  final String globalPath;

  GlobalFolderNode(
    super.name, {
    required this.globalPath,
    super.visible,
    super.parent,
    super.children,
  }) {
    // GlobalPathResolverを注入（isGlobalNodeが自動的にtrueになる）
    pathResolver = GlobalPathResolver.instance;
  }

  @override
  String get _globalBase => globalPath;

  // isGlobalNodeはPathResolverベースで判断される（pathResolver.isGlobal）
  // UI関連（baseIconColor）はNodePresenterに移動

  /// グローバルフォルダ自体の絶対パスを返す
  @override
  String? getAbsoluteFilePath() {
    return globalPath;
  }

  /// ディレクトリが存在しなければ作成
  @override
  Future<bool> prepareDirectory() async {
    if (!await fs.isDirectory(globalPath)) {
      await fs.createDirectory(globalPath);
      AppLogger.debug('[GlobalFolderNode] Created global folder: $globalPath');
    }
    return true;
  }
}

/// グローバルフォルダ内のサブフォルダノード
/// 青色アイコン＆グローバルフォルダベースのパス解決
class GlobalSubFolderNode extends FolderNode with _GlobalChildren {
  /// グローバルフォルダのベースパス
  final String basePath;

  GlobalSubFolderNode(
    super.name, {
    required this.basePath,
    super.visible,
    super.parent,
    super.children,
  });

  @override
  String get _globalBase => basePath;

  // isGlobalNodeはPathResolverベースで判断されるため、オーバーライド不要
  // UI関連（baseIconColor）はNodePresenterに移動

  /// グローバルフォルダベースの絶対パスを返す
  @override
  String? getAbsoluteFilePath() =>
      p.joinAll([basePath, ...segmentsBelowGlobalFolder(this).$2]);

  /// フォルダが無ければ子を作り直さない
  @override
  Future<bool> prepareDirectory() async {
    final absPath = getAbsoluteFilePath();
    return absPath != null && await fs.isDirectory(absPath);
  }
}

/// グローバルフォルダ用のGeoPackageノード
class GlobalGeoPackageNode extends GeoPackageNode {
  GlobalGeoPackageNode(
    super.geoPackageFile, {
    super.visible,
    super.parent,
  });

  // isGlobalNodeはPathResolverベースで判断されるため、オーバーライド不要
  // UI関連（baseIconColor）はNodePresenterに移動
}

/// グローバルフォルダ用の画像ノード
/// ExifParserを使用してEXIF解析を行う
class GlobalImageNode extends ImageNode {
  GlobalImageNode._(
    super.filePath,
    super.location,
    super.metadata, {
    super.takenAt,
    super.direction,
    super.visible,
    super.parent,
  });

  // isGlobalNodeはPathResolverベースで判断されるため、オーバーライド不要
  // UI関連（baseIconColor）はNodePresenterに移動

  /// 絶対パスからGlobalImageNodeを作成
  /// ExifParserを使用してEXIF情報を抽出
  static Future<GlobalImageNode?> fromPath(
    String absolutePath, {
    LayerTreeNode? parent,
  }) async {
    if (!await fs.exists(absolutePath)) return null;

    try {
      final exifData = await ExifParser.extractFromFile(absolutePath);
      return GlobalImageNode._(
        absolutePath,
        exifData?.location,
        exifData?.metadata ??
            ImageMetadata(fileSize: await fs.length(absolutePath) ?? 0),
        takenAt: exifData?.takenAt,
        direction: exifData?.direction,
        visible: true,
        parent: parent,
      );
    } catch (e) {
      AppLogger.debug('[GlobalImageNode] Error loading image: $e');
      return null;
    }
  }
}

/// グローバルフォルダ用のオーバーレイ画像ノード
/// GeoTIFFタグから直接パラメータを読み取って構築
class GlobalOverlayImageNode extends OverlayImageNode {
  GlobalOverlayImageNode._(
    super.filePath,
    super.location,
    super.metadata, {
    required super.overlayParams,
    super.visible,
    super.parent,
  });

  /// GeoTIFFタグから読み取ったパラメータでGlobalOverlayImageNodeを作成
  static Future<GlobalOverlayImageNode> _fromGeoTiff(
    String absolutePath,
    KMetaImageOverlay overlayParams, {
    LayerTreeNode? parent,
  }) async {
    return GlobalOverlayImageNode._(
      absolutePath,
      LatLng(overlayParams.centerLat, overlayParams.centerLng),
      ImageMetadata(fileSize: await fs.length(absolutePath) ?? 0),
      overlayParams: overlayParams,
      visible: true,
      parent: parent,
    );
  }
}
