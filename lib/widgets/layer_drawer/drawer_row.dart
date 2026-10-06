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
/// レイヤドロワーとフォルダ選択の 1 行（2026-10-06 に刷新）
///
/// 右端は表示/非表示の目だけ。メニューは長押しか右クリックで出す（⋮ は置かない）。
/// ドラッグで動かせる行は、長押しして動かさずに離したらメニュー、動かしたらドラッグ。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 行の高さ（詰めた行。以前は ListTile の 68px で、スマホでは数行しか入らなかった）
const double kDrawerRowHeight = 48;

/// 1 段ぶんの字下げ
const double kDrawerIndent = 20;

/// 長押しメニューの 1 項目
class RowMenuItem {
  const RowMenuItem(this.value, this.label, {this.icon, this.danger = false, this.key, this.dividerBefore = false});
  final String value;
  final String label;
  final IconData? icon;
  final bool danger;
  final Key? key;
  final bool dividerBefore;
}

/// [position]（画面座標）にメニューを出し、選んだ値を返す
Future<String?> showRowMenu(BuildContext context, Offset position, List<RowMenuItem> items) {
  if (items.isEmpty) return Future.value();
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      for (final it in items) ...[
        if (it.dividerBefore) const PopupMenuDivider(),
        PopupMenuItem<String>(
          key: it.key,
          value: it.value,
          child: Row(
            children: [
              if (it.icon != null) ...[
                Icon(it.icon, size: 18, color: it.danger ? Colors.red : Colors.black54),
                const SizedBox(width: 12),
              ],
              Text(it.label, style: it.danger ? const TextStyle(color: Colors.red) : null),
            ],
          ),
        ),
      ],
    ],
  );
}

/// 表示/非表示の目。親が隠れているときは自分の状態のまま薄く出す
class VisibilityEye extends StatelessWidget {
  const VisibilityEye({super.key, required this.visible, required this.effective, required this.onToggle});
  final bool visible;

  /// 親まで含めて見えているか
  final bool effective;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(visible ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
      color: visible && effective ? Colors.black87 : Colors.black38,
      visualDensity: VisualDensity.compact,
      onPressed: onToggle,
    );
  }
}

/// ドロワーの 1 行
class DrawerRow extends StatefulWidget {
  const DrawerRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailingInfo,
    this.depth = 0,
    this.selected = false,
    this.dimmed = false,
    this.eye,
    this.onTap,
    this.onDoubleTap,
    this.menu,
    this.onMenu,
    this.dragData,
    this.onDragStarted,
    this.onDragEnded,
    this.dragFeedback,
    this.titleStyle,
    this.height = kDrawerRowHeight,
  });

  final Widget leading;
  final String title;
  final Widget? subtitle;

  /// 名前のすぐ後ろに小さく出す（件数など）
  final String? trailingInfo;
  final int depth;
  final bool selected;
  final bool dimmed;
  final Widget? eye;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  /// 長押し・右クリックで出す項目（その時点で作る）
  final List<RowMenuItem> Function()? menu;
  final void Function(String value)? onMenu;

  /// ドラッグで動かせる行の中身。null ならドラッグしない
  final Object? dragData;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnded;
  final Widget? dragFeedback;
  final TextStyle? titleStyle;
  final double height;

  @override
  State<DrawerRow> createState() => _DrawerRowState();
}

class _DrawerRowState extends State<DrawerRow> {
  Offset? _downAt;
  bool _dragReported = false;

  Future<void> _openMenu(Offset at) async {
    final build = widget.menu;
    if (build == null) return;
    final items = build();
    if (items.isEmpty) return;
    final v = await showRowMenu(context, at, items);
    if (v != null) widget.onMenu?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.selected
        ? theme.colorScheme.primary
        : widget.dimmed
            ? Colors.black38
            : null;
    final row = Material(
      color: widget.selected ? theme.colorScheme.primary.withValues(alpha: 0.10) : Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        // ドラッグできる行の長押しは Draggable が受ける（離したらメニュー）
        onLongPress: widget.dragData == null && widget.menu != null
            ? () {
                HapticFeedback.selectionClick();
                if (_downAt != null) _openMenu(_downAt!);
              }
            : null,
        onSecondaryTapUp: widget.menu != null ? (d) => _openMenu(d.globalPosition) : null,
        child: SizedBox(
          height: widget.subtitle == null ? widget.height : widget.height + 12,
          child: Padding(
            padding: EdgeInsets.only(left: 12 + widget.depth * kDrawerIndent, right: 4),
            child: Row(
              children: [
                SizedBox(width: 28, child: Center(child: widget.leading)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          text: widget.title,
                          style: (widget.titleStyle ?? const TextStyle(fontSize: 15)).copyWith(
                            color: color,
                            fontWeight: widget.selected ? FontWeight.w600 : null,
                          ),
                          children: [
                            if (widget.trailingInfo != null)
                              TextSpan(
                                text: '  ${widget.trailingInfo}',
                                style: const TextStyle(fontSize: 12, color: Colors.black38, fontWeight: FontWeight.normal),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.subtitle != null) widget.subtitle!,
                    ],
                  ),
                ),
                if (widget.eye != null) widget.eye! else const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
    final listened = Listener(
      onPointerDown: (e) {
        if (e.kind != PointerDeviceKind.mouse || e.buttons == kPrimaryButton) _downAt = e.position;
      },
      child: row,
    );
    final data = widget.dragData;
    if (data == null) return listened;
    return LongPressDraggable<Object>(
      data: data,
      dragAnchorStrategy: (_, _, _) => Offset.zero,
      feedback: widget.dragFeedback ?? const SizedBox.shrink(),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      hapticFeedbackOnStart: true,
      onDragStarted: () => _dragReported = false,
      // 動かし始めて初めてドラッグとして知らせる（長押ししただけで画面全体がドラッグの表示にならないように）
      onDragUpdate: (d) {
        if (_dragReported || _downAt == null) return;
        if ((d.globalPosition - _downAt!).distance > 12) {
          _dragReported = true;
          widget.onDragStarted?.call();
        }
      },
      onDraggableCanceled: (_, offset) {
        final moved = _downAt == null ? 99.0 : (offset - _downAt!).distance;
        if (_dragReported) widget.onDragEnded?.call();
        _dragReported = false;
        if (moved <= 12 && _downAt != null) _openMenu(_downAt!);
      },
      onDragEnd: (_) {
        if (_dragReported) widget.onDragEnded?.call();
        _dragReported = false;
      },
      child: listened,
    );
  }
}

/// gpkg の見出し（行ではなく小さい見出し。▾ で畳む）
class DrawerGroupHeader extends StatelessWidget {
  const DrawerGroupHeader({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggleExpanded,
    this.depth = 0,
    this.dimmed = false,
    this.eye,
    this.menu,
    this.onMenu,
    this.highlight = false,
    this.badge,
    this.dragData,
    this.dragFeedback,
    this.onDragStarted,
    this.onDragEnded,
    this.headerKey,
  });
  final String title;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final int depth;
  final bool dimmed;
  final Widget? eye;
  final List<RowMenuItem> Function()? menu;
  final void Function(String value)? onMenu;

  /// ドロップ先として光らせる
  final bool highlight;
  final Widget? badge;
  final Object? dragData;
  final Widget? dragFeedback;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnded;

  /// 見出しの行に付ける鍵（チュートリアルの案内先）
  final Key? headerKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: highlight ? Colors.blue.withValues(alpha: 0.10) : null,
        border: Border(top: BorderSide(color: Colors.black.withValues(alpha: 0.06))),
      ),
      child: DrawerRow(
        key: headerKey,
        depth: depth,
        height: 40,
        leading: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 20, color: Colors.black54),
        title: title,
        titleStyle: TextStyle(fontSize: 13, color: dimmed ? Colors.black38 : Colors.black54, fontWeight: FontWeight.w600),
        dimmed: dimmed,
        subtitle: badge,
        eye: eye,
        onTap: onToggleExpanded,
        menu: menu,
        onMenu: onMenu,
        dragData: dragData,
        dragFeedback: dragFeedback,
        onDragStarted: onDragStarted,
        onDragEnded: onDragEnded,
      ),
    );
  }
}
