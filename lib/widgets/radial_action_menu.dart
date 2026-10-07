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
/// Radial action menu overlay
///
/// Displays icon buttons in a circular layout around a center point.
/// Supports a primary ring and an expandable secondary ring via
/// [RadialAction.secondaryActions].
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';

class RadialAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  /// If non-null, tapping this action expands a secondary ring
  /// instead of dismissing the menu. [onTap] is still called first.
  final List<RadialAction>? secondaryActions;

  const RadialAction({
    required this.icon,
    required this.label,
    this.color = Colors.white,
    required this.onTap,
    this.secondaryActions,
  });
}

/// Shows a radial menu at [center] (global coordinates).
/// Returns a callback to dismiss it programmatically.
VoidCallback showRadialMenu({
  required BuildContext context,
  required Offset center,
  required List<RadialAction> actions,
  double radius = 60,
  double buttonSize = 48,
}) {
  late OverlayEntry entry;
  var removed = false;
  // 外のタップ・項目のタップ・呼び出し側のどれから来ても 1 回だけ外して破棄する
  void dismiss() {
    if (removed) return;
    removed = true;
    entry
      ..remove()
      ..dispose();
  }

  entry = OverlayEntry(
    builder: (_) => _RadialMenuOverlay(
      center: center,
      actions: actions,
      radius: radius,
      buttonSize: buttonSize,
      onDismiss: dismiss,
    ),
  );
  Overlay.of(context).insert(entry);
  return dismiss;
}

class _RadialMenuOverlay extends StatefulWidget {
  final Offset center;
  final List<RadialAction> actions;
  final double radius;
  final double buttonSize;
  final VoidCallback onDismiss;

  const _RadialMenuOverlay({
    required this.center,
    required this.actions,
    required this.radius,
    required this.buttonSize,
    required this.onDismiss,
  });

  @override
  State<_RadialMenuOverlay> createState() => _RadialMenuOverlayState();
}

class _RadialMenuOverlayState extends State<_RadialMenuOverlay>
    with TickerProviderStateMixin {
  late final _RingAnimation _primary;
  _RingAnimation? _secondary;
  List<RadialAction>? _secondaryActions;

  @override
  void initState() {
    super.initState();
    _primary = _RingAnimation(this);
  }

  @override
  void dispose() {
    _primary.dispose();
    _secondary?.dispose();
    super.dispose();
  }

  void _onActionTap(RadialAction action) {
    action.onTap();
    final secondary = action.secondaryActions;
    if (secondary != null && secondary.isNotEmpty) {
      setState(() {
        _secondaryActions = secondary;
        _secondary?.dispose();
        _secondary = _RingAnimation(this);
      });
    } else {
      widget.onDismiss();
    }
  }

  void _onSecondaryTap(RadialAction action) {
    action.onTap();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => widget.onDismiss(),
      child: Material(
        color: Colors.black26,
        child: Stack(
          children: [
            ..._buildRing(
              widget.actions,
              widget.radius,
              _primary.curve,
              _onActionTap,
            ),
            if (_secondaryActions != null && _secondary != null)
              ..._buildRing(
                _secondaryActions!,
                widget.radius * 2,
                _secondary!.curve,
                _onSecondaryTap,
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRing(
    List<RadialAction> actions,
    double radius,
    Animation<double> curved,
    void Function(RadialAction) onTap,
  ) {
    final count = actions.length;
    const startAngle = -math.pi / 2;
    final sweep = count == 1 ? 0.0 : 2 * math.pi / count;

    return List.generate(count, (i) {
      final angle = startAngle + sweep * i;
      return AnimatedBuilder(
        animation: curved,
        builder: (context, child) {
          final t = curved.value;
          final dx = widget.center.dx + radius * t * math.cos(angle);
          final dy = widget.center.dy + radius * t * math.sin(angle);
          return Positioned(
            left: dx - widget.buttonSize / 2,
            top: dy - widget.buttonSize / 2,
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(scale: t, child: child),
            ),
          );
        },
        child: _RadialButton(
          action: actions[i],
          size: widget.buttonSize,
          onTap: () => onTap(actions[i]),
        ),
      );
    });
  }
}

/// 1 つの輪が開くアニメーション（作った時点で再生を始める）。
/// CurvedAnimation は親に購読を張るので、毎ビルド作らずここで持って一緒に破棄する
class _RingAnimation {
  _RingAnimation(TickerProvider vsync)
    : controller = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 250),
      )..forward() {
    curve = CurvedAnimation(parent: controller, curve: Curves.easeOutBack);
  }

  final AnimationController controller;
  late final CurvedAnimation curve;

  void dispose() {
    curve.dispose();
    controller.dispose();
  }
}

class _RadialButton extends StatelessWidget {
  final RadialAction action;
  final double size;
  final VoidCallback onTap;

  const _RadialButton({
    required this.action,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: action.color,
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Icon(action.icon, size: size * 0.5),
          ),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              action.label,
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
