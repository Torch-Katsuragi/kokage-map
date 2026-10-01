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
// 編集中の左の道具の列（ふだんの MapToolbar と入れ替わる）。地物の種類で出す道具が違う。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/map_layout.dart';
import '../i18n/strings.g.dart';
import '../providers/ui_state_providers.dart';
import 'edit_session.dart';

IconData editModeIcon(EditMode m) => switch (m) {
      EditMode.vertex => Icons.polyline,
      EditMode.move => Icons.open_with,
      EditMode.rotate => Icons.rotate_right,
      EditMode.scale => Icons.open_in_full,
      EditMode.extend => Icons.trending_flat,
    };

String editModeName(EditMode m) => switch (m) {
      EditMode.vertex => t.featureEdit.modes.vertex,
      EditMode.move => t.featureEdit.modes.move,
      EditMode.rotate => t.featureEdit.modes.rotate,
      EditMode.scale => t.featureEdit.modes.scale,
      EditMode.extend => t.featureEdit.modes.extend,
    };

class EditToolbar extends ConsumerWidget {
  const EditToolbar({super.key, this.side = ToolbarSide.left});

  final ToolbarSide side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(featureEditorProvider);
    if (s == null) return const SizedBox.shrink();
    final ed = ref.read(featureEditorProvider.notifier);
    return Positioned(
      left: side == ToolbarSide.left ? 0 : null,
      right: side == ToolbarSide.right ? 0 : null,
      top: 0,
      bottom: 0,
      child: SizedBox(
        width: 44,
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 16),
              for (final m in modesFor(s.kind)) ...[
                _Button(
                  icon: editModeIcon(m),
                  tooltip: editModeName(m),
                  selected: s.mode == m,
                  onPressed: () {
                    ed.setMode(m);
                    // 道具が替わったことを地図の上にも出す（モード切替はフラッシュを徹底）
                    ref.read(mapFlashProvider.notifier).show(editModeName(m));
                  },
                ),
                const SizedBox(height: 8),
              ],
              if (s.mode == EditMode.vertex) ...[
                _Button(
                  icon: Icons.remove_circle_outline,
                  tooltip: t.featureEdit.deleteVertex,
                  onPressed: ed.canDeleteSelected ? ed.deleteSelected : null,
                ),
                const SizedBox(height: 8),
              ],
              const Divider(height: 16, indent: 8, endIndent: 8),
              _Button(icon: Icons.undo, tooltip: t.featureEdit.undo, onPressed: s.undo.isEmpty ? null : ed.undo),
              const SizedBox(height: 8),
              _Button(icon: Icons.redo, tooltip: t.featureEdit.redo, onPressed: s.redo.isEmpty ? null : ed.redo),
            ],
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.icon, required this.tooltip, required this.onPressed, this.selected = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(shape: BoxShape.circle, color: selected ? const Color(0xFFD32F2F) : Colors.transparent),
        child: IconButton(
          icon: Icon(icon, color: selected ? Colors.white : (onPressed == null ? Colors.black26 : Colors.black)),
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 24,
          padding: EdgeInsets.zero,
        ),
      );
}
