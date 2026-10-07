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
// Root Maps: ノードのUI表示に関する責務を集約
// LayerTreeNodeからUI関連の責務を分離

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/node_types.dart';
import '../i18n/strings.g.dart';
import '../models/nodes/drive_folder_node.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/overlay_image_node.dart';
import '../models/nodes/sys_node.dart';

/// Drive連携UIのテーマカラー（彩度控えめ・明度高めのモダンな青）
const Color cloudColor = Color(0xFF7EB0D5);

/// ノードのUI表示情報を提供するクラス
/// 
/// 単一責任原則に従い、ノードのUI表示に関する責務のみを担当：
/// - アイコン
/// - 色
/// - 表示名
class NodePresenter {
  NodePresenter._();
  
  // ========================================
  // アイコン関連
  // ========================================
  
  /// ノードタイプに基づくベースアイコンを取得
  static IconData getIconForType(NodeType type) {
    switch (type) {
      case NodeType.folder:
        return Icons.folder;
      case NodeType.geopackage:
        return Icons.storage;
      case NodeType.layer:
        return Icons.layers;
      case NodeType.view:
        return Icons.filter_alt;
      case NodeType.feature:
        return Icons.location_on;
      case NodeType.image:
        return Icons.photo_camera;
    }
  }
  
  /// ノードインスタンスに基づくアイコンを取得
  /// サブクラス固有のアイコンがある場合はそれを返す
  static IconData getIcon(LayerTreeNode node) {
    // 「System」は端末のアイコン
    if (node is SysNode) return Icons.smartphone;

    // Drive連携フォルダはクラウドフォルダアイコン
    if (node is DriveFolderNode) return Icons.cloud;
    if (node is DriveSubFolderNode) return Icons.folder;
    
    // LayerNodeのサブクラスは特別なアイコンを持つ
    if (node is PointLayerNode) return Icons.scatter_plot;
    if (node is LineLayerNode) return Icons.show_chart;
    if (node is PolygonLayerNode) return Icons.terrain;
    
    // FeatureNodeのサブクラスは特別なアイコンを持つ
    if (node is PointFeatureNode) return Icons.location_on;
    if (node is LineFeatureNode) return Icons.timeline;
    if (node is PolygonFeatureNode) return Icons.crop_square;
    
    // オーバーレイ画像ノードは地図画像アイコン
    if (node is OverlayImageNode) return Icons.image;
    
    // 基本タイプのアイコン
    return getIconForType(node.nodeType);
  }
  
  // ========================================
  // 色関連
  // ========================================
  
  /// ノードタイプに基づくベース色を取得
  static Color getColorForType(NodeType type) {
    switch (type) {
      case NodeType.folder:
        return Colors.amber;
      case NodeType.geopackage:
        return Colors.blueGrey;
      case NodeType.layer:
        return Colors.blue;
      case NodeType.view:
        return Colors.teal;
      case NodeType.feature:
        return Colors.red;
      case NodeType.image:
        return Colors.purple;
    }
  }
  
  /// ノードインスタンスに基づく色を取得
  /// グローバルノードは青色系、サブクラス固有の色がある場合はそれを返す
  static Color getColor(LayerTreeNode node) {
    if (node is DriveFolderNode) {
      return cloudColor;
    }

    // 端末側（sys とグローバル配下）は青色で差別化
    if (node is SysNode || node.isGlobalNode) {
      return Colors.blue.shade700;
    }
    
    // LayerNodeのサブクラスは特別な色を持つ
    if (node is PointLayerNode) return Colors.blue;
    if (node is LineLayerNode) return Colors.green;
    if (node is PolygonLayerNode) return Colors.deepOrange;
    
    // FeatureNodeのサブクラスは特別な色を持つ
    if (node is PointFeatureNode) return Colors.red;
    if (node is LineFeatureNode) return Colors.blueGrey;
    if (node is PolygonFeatureNode) return Colors.orange;
    
    // オーバーレイ画像ノードはtealで差別化
    if (node is OverlayImageNode) return Colors.teal;
    
    // 基本タイプの色
    return getColorForType(node.nodeType);
  }
  
  // ========================================
  // Drive連携フォルダ関連
  // ========================================
  
  /// 同期状態に対応するオーバーレイアイコンを取得
  static IconData? getSyncOverlayIcon(SyncStatus status) {
    switch (status) {
      case SyncStatus.synced:
        return null; // オーバーレイなし
      case SyncStatus.localChanges:
        return Icons.arrow_upward;
      case SyncStatus.remoteChanges:
        return Icons.arrow_downward;
      case SyncStatus.conflict:
        return Icons.warning;
      case SyncStatus.syncing:
        return Icons.sync;
      case SyncStatus.error:
        return Icons.error_outline;
      case SyncStatus.unknown:
        return null;
    }
  }
  
  /// 同期状態に対応する色を取得
  static Color? getSyncOverlayColor(SyncStatus status) {
    switch (status) {
      case SyncStatus.synced:
        return null;
      case SyncStatus.localChanges:
        return Colors.orange;
      case SyncStatus.remoteChanges:
        return Colors.green;
      case SyncStatus.conflict:
        return Colors.red;
      case SyncStatus.syncing:
        return Colors.blue;
      case SyncStatus.error:
        return Colors.red;
      case SyncStatus.unknown:
        return null;
    }
  }
  
  /// 同期状態オーバーレイ付きアイコンウィジェットを生成
  static Widget buildIconWithSyncOverlay(
    LayerTreeNode node, {
    double size = 24,
    SyncStatus? syncStatus,
  }) {
    final baseIcon = Icon(
      getIcon(node),
      color: getColor(node),
      size: size,
    );
    
    // DriveFolderNodeでない場合、または同期状態がない場合はベースアイコンのみ
    if (node is! DriveFolderNode || syncStatus == null) {
      return baseIcon;
    }
    
    final overlayIcon = getSyncOverlayIcon(syncStatus);
    if (overlayIcon == null) {
      return baseIcon;
    }
    
    return Stack(
      clipBehavior: Clip.none,
      children: [
        baseIcon,
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 2,
                ),
              ],
            ),
            child: Icon(
              overlayIcon,
              size: size * 0.5,
              color: getSyncOverlayColor(syncStatus),
            ),
          ),
        ),
      ],
    );
  }
  
  // ========================================
  // 表示名関連
  // ========================================
  
  /// ノードの表示名を取得（名前 + タイプ情報）
  static String getDisplayName(LayerTreeNode node) {
    // sys の name は内部の鍵（`<sys>`）。表示は i18n
    if (node is SysNode) return t.layerDrawer.sysFolder;
    // プロジェクトのルートの name は内部の 'Home'。表示は開いているフォルダの名前（パスの無い仮ルートは Home のまま）
    if (node.parent == null) {
      final path = node.getAbsoluteFilePath();
      if (path != null && path.isNotEmpty) return p.basename(path);
    }
    return node.name;
  }
  
  // ========================================
  // アイコンウィジェット生成
  // ========================================
  
  /// ノードのアイコンウィジェットを生成
  static Icon buildIcon(LayerTreeNode node, {double? size}) {
    return Icon(
      getIcon(node),
      color: getColor(node),
      size: size,
    );
  }
}
