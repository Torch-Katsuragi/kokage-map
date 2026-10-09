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
// 左下フローティングアクションボタンウィジェット
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../i18n/strings.g.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import '../tools/pen_tool.dart';
import '../tools/select_tool.dart';

/// 左下に表示される白い円形のフローティングボタン
class LeftBottomFab extends ConsumerWidget {
  const LeftBottomFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = ref.watch(isFabActiveProvider);
    final currentTool = ref.watch(currentToolProvider);

    // ペン: 消しゴム／選択: 複数選択。ほかのツールでは意味を持たない
    final iconData = switch (currentTool) {
      PenTool() => Icons.auto_fix_normal,
      SelectTool() => Icons.library_add_check_outlined,
      _ => Icons.circle,
    };

    return GestureDetector(
      onTap: () {
        final on = !isActive;
        ref.read(isFabActiveProvider.notifier).set(on);
        // モードが変わるので中央に出す（ほかのツールでは意味を持たないので出さない）
        final flash = t.map.flash;
        final label = switch (currentTool) {
          PenTool() => on ? flash.eraserOn : flash.eraserOff,
          SelectTool() => on ? flash.multiSelectOn : flash.multiSelectOff,
          _ => null,
        };
        if (label != null) ref.read(mapFlashProvider.notifier).show(label);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: isActive ? Colors.blue : Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(
            color: isActive ? Colors.blueAccent : Colors.grey.shade300,
            width: 2,
          ),
        ),
        child: Icon(
          iconData,
          color: isActive ? Colors.white : Colors.grey,
          size: 32,
        ),
      ),
    );
  }
}
