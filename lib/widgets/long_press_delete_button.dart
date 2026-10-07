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
// Root Maps: 長押し削除ボタンウィジェット
// 長押し（既定 1 秒）でアクションを実行。ゲージアニメーション付き。

import 'package:flutter/material.dart';

/// 長押し削除ボタン
///
/// 操作ミス防止のため、[duration]（既定 1 秒）の長押しを要求する。
/// 長押し中は赤いオーバーレイゲージが左から右にアニメーションで溜まる。
/// 途中で離すとキャンセルされる。
class LongPressDeleteButton extends StatefulWidget {
  /// 削除実行時のコールバック
  final VoidCallback onDelete;

  /// ボタンに表示するラベル
  final String label;

  /// 長押しに必要な時間
  final Duration duration;

  const LongPressDeleteButton({
    super.key,
    required this.onDelete,
    required this.label,
    this.duration = const Duration(seconds: 1),
  });

  @override
  State<LongPressDeleteButton> createState() => _LongPressDeleteButtonState();
}

class _LongPressDeleteButtonState extends State<LongPressDeleteButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        // ゲージ完了 → 削除実行
        _isPressed = false;
        widget.onDelete();
        _controller.reset();
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(LongPressDeleteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerDown() {
    setState(() => _isPressed = true);
    _controller.forward(from: 0.0);
  }

  void _onPointerUp() {
    if (_isPressed) {
      setState(() => _isPressed = false);
      _controller.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _onPointerDown(),
      onTapUp: (_) => _onPointerUp(),
      onTapCancel: _onPointerUp,
      child: AnimatedBuilder(
        animation: _controller,
        // ボタン内容はゲージの進行で変わらないので毎フレーム組み直さない
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline, size: 16, color: Colors.red.shade700),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        builder: (context, content) {
          return Container(
            width: double.infinity,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isPressed ? Colors.red.shade400 : Colors.red.shade200,
                width: 1,
              ),
              color: Colors.red.shade50,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Stack(
                children: [
                  // ゲージ（左から右に溜まる赤いオーバーレイ）
                  if (_isPressed)
                    Positioned.fill(
                      child: FractionallySizedBox(
                        widthFactor: _controller.value,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.red.shade200.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  content!,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
