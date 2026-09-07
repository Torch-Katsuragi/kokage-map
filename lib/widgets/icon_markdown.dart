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
/// Markdown内でFlutter Material Iconsを表示するためのカスタム拡張
///
/// `:icon-pan_tool_alt:` のような記法を、実際の [Icon] ウィジェットに変換する。
/// [IconInlineSyntax] でパターンを検出し、[IconMarkdownBuilder] でウィジェットを生成。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// `:icon-xxx:` パターンを検出するインラインシンタックス
class IconInlineSyntax extends md.InlineSyntax {
  IconInlineSyntax() : super(':icon-([a-z_0-9]+):');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final iconName = match[1]!;
    final el = md.Element.text('flutterIcon', iconName);
    parser.addNode(el);
    return true;
  }
}

/// `flutterIcon` タグを [Icon] ウィジェットに変換するビルダー
class IconMarkdownBuilder extends MarkdownElementBuilder {
  /// アイコン名 → IconData のマッピング
  ///
  /// Markdownで `:icon-pan_tool_alt:` と書くと `Icons.pan_tool_alt` が表示される。
  static const _iconMap = <String, IconData>{
    // ツールバー
    'pan_tool_alt': Icons.pan_tool_alt,
    'edit': Icons.edit,
    'select_all': Icons.select_all,
    'gps_fixed': Icons.gps_fixed,
    'transform': Icons.transform,

    // 一般UI
    'settings': Icons.settings,
    'folder_open': Icons.folder_open,
    'folder': Icons.folder,
    'folder_special': Icons.folder_special,
    'map': Icons.map,
    'layers': Icons.layers,
    'visibility': Icons.visibility,
    'visibility_off': Icons.visibility_off,
    'add': Icons.add,
    'delete': Icons.delete,
    'drag_handle': Icons.drag_handle,
    'cloud': Icons.cloud,
    'sync': Icons.sync,
    'history': Icons.history,
    'camera_alt': Icons.camera_alt,
    'photo_camera': Icons.photo_camera,

    // GPS・測量
    'my_location': Icons.my_location,
    'add_location': Icons.add_location,
    'timeline': Icons.timeline,
    'bluetooth': Icons.bluetooth,
    'bluetooth_connected': Icons.bluetooth_connected,

    // 描画・編集
    'undo': Icons.undo,
    'redo': Icons.redo,
    'check': Icons.check,
    'clear': Icons.clear,
    'touch_app': Icons.touch_app,
    'gesture': Icons.gesture,

    // データ操作
    'file_upload': Icons.file_upload,
    'file_download': Icons.file_download,
    'table_chart': Icons.table_chart,
    'import_export': Icons.import_export,

    // 設定
    'language': Icons.language,
    'format_size': Icons.format_size,
    'palette': Icons.palette,
    'security': Icons.security,
    'info_outline': Icons.info_outline,
    'feedback': Icons.feedback,
    'chevron_right': Icons.chevron_right,
    'open_in_new': Icons.open_in_new,

    // ナビゲーション
    'menu_book': Icons.menu_book,
    'help_outline': Icons.help_outline,
    'warning': Icons.warning,
    'error': Icons.error,
  };

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final iconName = element.textContent;
    final iconData = _iconMap[iconName];
    if (iconData == null) {
      // 未登録のアイコン名はテキストのまま表示
      return Text(
        ':icon-$iconName:',
        style: preferredStyle?.copyWith(color: Colors.red),
      );
    }

    return Icon(
      iconData,
      size: (preferredStyle?.fontSize ?? 14) + 2,
      color: preferredStyle?.color ?? Colors.grey[700],
    );
  }
}
