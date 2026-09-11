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
// こかげマップ: ツールを切り替えたとき、その名前を地図の中央に一瞬出して消す
//
// 左のツールバーは小さなアイコンだけなので、初めての人には「いま何のモードか」が
// 分かりにくい。切り替えの瞬間だけ名前を出し、操作の邪魔にならないよう
// タッチは素通しにする。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../providers/tool_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../tools/map_tool.dart';

class ToolNameFlash extends ConsumerStatefulWidget {
  const ToolNameFlash({super.key});

  @override
  ConsumerState<ToolNameFlash> createState() => _ToolNameFlashState();
}

class _ToolNameFlashState extends ConsumerState<ToolNameFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// 0→1 でさっと出て、しばらく留まり、後半で消える
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 12),
    TweenSequenceItem(tween: ConstantTween(1), weight: 43),
    TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 45),
  ]).animate(_controller);

  late final Animation<double> _scale = Tween<double>(begin: 0.92, end: 1)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  String _label = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 内部名（`MapTool.name`）から表示名へ。知らないツールは内部名をそのまま出す
  static String labelOf(MapTool tool) => switch (tool.name) {
        'Pan' => t.map.toolbar.pan,
        'Pen' => t.map.toolbar.pen,
        'Select' => t.map.toolbar.select,
        'GPS' => t.map.toolbar.gpsTool,
        'Overlay Transform' => t.map.toolbar.overlayTransform,
        _ => tool.name,
      };

  void _flash(String label) {
    setState(() => _label = label);
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<MapTool>(currentToolProvider, (prev, next) {
      if (prev == null || prev == next) return;
      _flash(labelOf(next));
    });
    // ツール以外のモード切替（眺め・北上真上・3D/2D・ドライブ）も同じ演出で
    ref.listen<(String, int)>(mapFlashProvider, (prev, next) {
      if (prev == null || prev == next || next.$1.isEmpty) return;
      _flash(next.$1);
    });

    return IgnorePointer(
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            if (_controller.isDismissed || _controller.isCompleted) {
              return const SizedBox.shrink();
            }
            return Opacity(
              opacity: _opacity.value,
              child: Transform.scale(scale: _scale.value, child: child),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
