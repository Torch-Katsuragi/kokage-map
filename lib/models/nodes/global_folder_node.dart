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
import 'folder_node.dart';
import 'geopackage_node.dart';
import 'image_node.dart';
import 'layer_tree_node.dart';
import 'overlay_image_node.dart';

/// グローバルフォルダ内サブフォルダのDrive連携チェック
/// .kmeta.jsonにDrive連携情報があればDriveFolderNodeを作成
Future<LayerTreeNode?> _tryCreateGlobalDriveNode(
  String folderPath,
  String folderName,
  String basePath,
  LayerTreeNode parent,
) async {
  return FolderNode.tryCreateDriveFolderNode(folderPath, folderName, parent);
}

/// グローバルフォルダノード
/// - どのプロジェクトを開いても「System」（`SysNode`）の下に表示される（2026-09-25 まではルート直下）
/// - 実体の置き場所は GlobalFolderLocator が決める
///   （Android: 共有ストレージ `Documents/KokageMap/Global`。旧: アプリ内部の k_maps_global）
/// - 青色アイコンで通常フォルダと差別化（NodePresenter経由）
class GlobalFolderNode extends FolderNode {
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
  
  // isGlobalNodeはPathResolverベースで判断される（pathResolver.isGlobal）
  // UI関連（baseIconColor）はNodePresenterに移動

  /// グローバルフォルダ自体の絶対パスを返す
  @override
  String? getAbsoluteFilePath() {
    return globalPath;
  }

  /// グローバルフォルダの子ノードを更新
  /// 通常のFolderNodeと同様だが、子フォルダはGlobalSubFolderNodeとして生成
  @override
  Future<void> updateChildren() async {
    // ディレクトリが存在しなければ作成
    if (!await fs.isDirectory(globalPath)) {
      await fs.createDirectory(globalPath);
      AppLogger.debug('[GlobalFolderNode] Created global folder: $globalPath');
    }

    // メタデータを読み込み（展開状態を復元）
    await loadMetaState();

    // 列挙は1回だけ（web はハンドル走査が高い。FolderNodeと同じ理由）
    final entries = await fs.list(globalPath);
    // サブフォルダを読み込み
    final folderNodes = await _loadGlobalSubFolders(entries);
    // GeoPackageを読み込み
    final gpkgNodes = await _loadGeoPackageNodes(entries);
    // 画像ファイルを読み込み
    final photoNodes = await _loadImageNodes(entries);

    // 現在のファイルシステムに存在するノード名のセットを作成
    final currentFolderNames = folderNodes.map((n) => n.name).toSet();
    final currentGpkgNames = gpkgNodes.map((n) => n.name).toSet();
    final currentPhotoNames = photoNodes.map((n) => n.name).toSet();
    final allCurrentNames = {
      ...currentFolderNames,
      ...currentGpkgNames,
      ...currentPhotoNames,
    };

    // 既存の子ノードで、ファイルシステムに存在しないものを削除
    children.removeWhere((child) {
      final shouldRemove = !allCurrentNames.contains(child.name);
      if (shouldRemove) {
        AppLogger.debug(
          '[GlobalFolderNode] Removing ${child.name} (no longer exists)',
        );
        child.parent = null;
      }
      return shouldRemove;
    });

    // 新しいノードを追加（既存ノードは再利用）
    for (final node in folderNodes) {
      addChildIfNotExists(node);
    }
    for (final node in gpkgNodes) {
      addChildIfNotExists(node);
    }
    for (final node in photoNodes) {
      addChildIfNotExists(node);
    }

    // KMetaの可視性設定を子ノードに適用
    await applyMetaVisibility();

    AppLogger.debug(
      '[GlobalFolderNode] ${children.length} children after update',
    );
  }

  /// グローバルフォルダ直下のサブフォルダを読み込み
  Future<List<LayerTreeNode>> _loadGlobalSubFolders(
    List<KFileEntry> entries,
  ) async {
    final nodes = <LayerTreeNode>[];
    final directories = entries
        .where((e) => e.isDirectory && e.name != SyncBaseStore.dirName) // 3-way マージの base 置き場は見せない
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in directories) {
      final name = entity.name;
      // .kmeta.jsonにDrive連携情報があればGlobalDriveFolderNodeとして作成
      final driveNode = await _tryCreateGlobalDriveNode(
        entity.path, name, globalPath, this,
      );
      if (driveNode != null) {
        nodes.add(driveNode);
      } else {
        nodes.add(
          GlobalSubFolderNode(
            name,
            basePath: globalPath,
            visible: true,
            parent: this,
            children: [],
          ),
        );
      }
    }
    return nodes;
  }

  /// グローバルフォルダ直下のGeoPackageノードを読み込み
  Future<List<LayerTreeNode>> _loadGeoPackageNodes(
    List<KFileEntry> entries,
  ) async {
    final nodes = <LayerTreeNode>[];
    final gpkgFiles = entries
        .where((e) => !e.isDirectory && e.path.endsWith('.gpkg'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in gpkgFiles) {
      final fileName = entity.name;
      // 絶対パスモードでGeoPackageFileを作成
      final gpkgFile = GeoPackageFile([fileName], absolutePath: entity.path);
      nodes.add(
        GlobalGeoPackageNode(gpkgFile, absolutePath: entity.path, parent: this),
      );
      AppLogger.debug('[GlobalFolderNode] Found GeoPackage: $fileName');
    }
    return nodes;
  }

  /// グローバルフォルダ直下の画像ノードを読み込み
  Future<List<LayerTreeNode>> _loadImageNodes(
    List<KFileEntry> entries,
  ) async {
    final nodes = <LayerTreeNode>[];
    const supportedExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.tiff', '.tif'];
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
        final node = await GlobalOverlayImageNode._fromGeoTiff(
          entity.path, overlayParams, parent: this,
        );
        nodes.add(node);
      } else {
        final node = await GlobalImageNode.fromPath(entity.path, parent: this);
        if (node != null) nodes.add(node);
      }
    }
    return nodes;
  }

  // 2026-08-25: createIn() を削除した。どこからも呼ばれておらず、
  // 同期I/O（existsSync/createSync）だったため web に持ち込めない。
  // 必要になったら `fs` 経由の非同期版として足すこと。
}

/// グローバルフォルダ内のサブフォルダノード
/// 青色アイコン＆グローバルフォルダベースのパス解決
class GlobalSubFolderNode extends FolderNode {
  /// グローバルフォルダのベースパス
  final String basePath;

  GlobalSubFolderNode(
    super.name, {
    required this.basePath,
    super.visible,
    super.parent,
    super.children,
  });

  // isGlobalNodeはPathResolverベースで判断されるため、オーバーライド不要
  // UI関連（baseIconColor）はNodePresenterに移動

  /// グローバルフォルダベースの絶対パスを返す
  @override
  String? getAbsoluteFilePath() {
    // 親をたどってパスセグメントを構築
    final segments = <String>[];
    LayerTreeNode? current = this;
    while (current != null && current is! GlobalFolderNode) {
      segments.insert(0, current.name);
      current = current.parent;
    }
    return p.joinAll([basePath, ...segments]);
  }

  /// 子ノードを更新（サブフォルダ・GeoPackage・画像）
  @override
  Future<void> updateChildren() async {
    final absPath = getAbsoluteFilePath();
    if (absPath == null) return;

    if (!await fs.isDirectory(absPath)) return;

    // メタデータを読み込み（展開状態を復元）
    await loadMetaState();

    // 列挙は1回だけ（web はハンドル走査が高い。FolderNodeと同じ理由）
    final entries = await fs.list(absPath);
    // サブフォルダを読み込み
    final folderNodes = await _loadSubFolders(entries);
    // GeoPackageを読み込み
    final gpkgNodes = await _loadGeoPackageNodes(entries);
    // 画像ファイルを読み込み
    final photoNodes = await _loadImageNodes(entries);

    // 現在のファイルシステムに存在するノード名のセットを作成
    final allCurrentNames = {
      ...folderNodes.map((n) => n.name),
      ...gpkgNodes.map((n) => n.name),
      ...photoNodes.map((n) => n.name),
    };

    // 既存の子ノードで、ファイルシステムに存在しないものを削除
    children.removeWhere((child) {
      final shouldRemove = !allCurrentNames.contains(child.name);
      if (shouldRemove) {
        child.parent = null;
      }
      return shouldRemove;
    });

    // 新しいノードを追加
    for (final node in folderNodes) {
      addChildIfNotExists(node);
    }
    for (final node in gpkgNodes) {
      addChildIfNotExists(node);
    }
    for (final node in photoNodes) {
      addChildIfNotExists(node);
    }

    // KMetaの可視性設定を子ノードに適用
    await applyMetaVisibility();
  }

  Future<List<LayerTreeNode>> _loadSubFolders(List<KFileEntry> entries) async {
    final nodes = <LayerTreeNode>[];
    final directories = entries
        .where((e) => e.isDirectory && e.name != SyncBaseStore.dirName) // 3-way マージの base 置き場は見せない
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in directories) {
      final name = entity.name;
      // .kmeta.jsonにDrive連携情報があればGlobalDriveFolderNodeとして作成
      final driveNode = await _tryCreateGlobalDriveNode(
        entity.path, name, basePath, this,
      );
      if (driveNode != null) {
        nodes.add(driveNode);
      } else {
        nodes.add(
          GlobalSubFolderNode(
            name,
            basePath: basePath,
            visible: true,
            parent: this,
            children: [],
          ),
        );
      }
    }
    return nodes;
  }

  Future<List<LayerTreeNode>> _loadGeoPackageNodes(
    List<KFileEntry> entries,
  ) async {
    final nodes = <LayerTreeNode>[];
    final gpkgFiles = entries
        .where((e) => !e.isDirectory && e.path.endsWith('.gpkg'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in gpkgFiles) {
      final fileName = entity.name;
      // 絶対パスモードでGeoPackageFileを作成
      final gpkgFile = GeoPackageFile([fileName], absolutePath: entity.path);
      nodes.add(
        GlobalGeoPackageNode(gpkgFile, absolutePath: entity.path, parent: this),
      );
    }
    return nodes;
  }

  Future<List<LayerTreeNode>> _loadImageNodes(
    List<KFileEntry> entries,
  ) async {
    final nodes = <LayerTreeNode>[];
    const supportedExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.tiff', '.tif'];
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
        final node = await GlobalOverlayImageNode._fromGeoTiff(
          entity.path, overlayParams, parent: this,
        );
        nodes.add(node);
      } else {
        final node = await GlobalImageNode.fromPath(entity.path, parent: this);
        if (node != null) nodes.add(node);
      }
    }
    return nodes;
  }

  // 2026-08-25: createIn() を削除した。どこからも呼ばれておらず、
  // 同期I/O（existsSync/createSync）だったため web に持ち込めない。
  // 必要になったら `fs` 経由の非同期版として足すこと。
}

/// グローバルフォルダ用のGeoPackageノード
/// 絶対パスを使用してパス解決
class GlobalGeoPackageNode extends GeoPackageNode {
  /// ファイルの絶対パス
  final String absolutePath;

  GlobalGeoPackageNode(
    super.geoPackageFile, {
    required this.absolutePath,
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
