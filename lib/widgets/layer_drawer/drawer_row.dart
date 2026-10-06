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
/// 動かせる行は左へスワイプすると「移動」（移動先を選ぶ）。以前の長押しドラッグは、長押しのメニューと取り合うのでやめた。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/strings.g.dart';

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
    this.onSwipeMove,
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

  /// 左スワイプで呼ぶ（移動先を選ぶ）。null なら動かせない行
  final VoidCallback? onSwipeMove;
  final TextStyle? titleStyle;
  final double height;

  @override
  State<DrawerRow> createState() => _DrawerRowState();
}

class _DrawerRowState extends State<DrawerRow> {
  Offset? _downAt;

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
        onLongPress: widget.menu != null
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
                          style: (widget.titleStyle ?? const TextStyle(fontSize: 17)).copyWith(
                            color: color,
                            fontWeight: widget.selected ? FontWeight.w600 : null,
                          ),
                          children: [
                            if (widget.trailingInfo != null)
                              TextSpan(
                                text: '  ${widget.trailingInfo}',
                                style: const TextStyle(fontSize: 14, color: Colors.black38, fontWeight: FontWeight.normal),
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
    final move = widget.onSwipeMove;
    if (move == null) return listened;
    return Dismissible(
      key: ValueKey(widget.title),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.3},
      background: Container(
        color: Colors.blue.shade600,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.drive_file_move_outline, color: Colors.white),
            const SizedBox(width: 6),
            Text(t.layerDrawer.moveAction, style: const TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
      ),
      // 消さずに戻し、移動先を選ばせる
      confirmDismiss: (_) async {
        move();
        return false;
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
    this.onSwipeMove,
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
  final VoidCallback? onSwipeMove;

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
        titleStyle: TextStyle(fontSize: 15, color: dimmed ? Colors.black38 : Colors.black54, fontWeight: FontWeight.w600),
        dimmed: dimmed,
        subtitle: badge,
        eye: eye,
        onTap: onToggleExpanded,
        menu: menu,
        onMenu: onMenu,
        onSwipeMove: onSwipeMove,
      ),
    );
  }
}
