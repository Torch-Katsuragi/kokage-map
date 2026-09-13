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
/// Root Maps: リサイズ可能なサイドパネルウィジェット
/// LayerDrawerや属性テーブルなどで再利用できる汎用的なパネル。
/// 配置（Positioned等）は呼び出し側の責務。
library;

import 'package:flutter/material.dart';

/// リサイズ可能なサイドパネルウィジェット
///
/// パネル本体＋左端ドラッグハンドルを描画する。
/// [Positioned] は含まないため、呼び出し側で配置すること。
class ResizableSidePanel extends StatefulWidget {
  /// パネルの子ウィジェット
  final Widget child;

  /// パネルの初期幅
  final double initialWidth;

  /// パネルの最小幅（これ未満にドラッグするとパネルが閉じる）
  final double minWidth;

  /// パネルの最大幅（絶対値ピクセル）
  ///
  /// ドラッグ時のクランプに使用する。
  /// 呼び出し側で `MediaQuery.of(context).size.width * ratio` 等を渡す。
  final double maxWidth;

  /// パネルの開閉状態変更コールバック
  final void Function(bool isOpen)? onOpenChanged;

  /// パネル幅変更コールバック
  final void Function(double width)? onWidthChanged;

  /// パネルの背景色
  final Color? backgroundColor;

  /// ドラッグハンドルの色
  final Color handleColor;

  const ResizableSidePanel({
    super.key,
    required this.child,
    this.initialWidth = 320,
    this.minWidth = 200,
    this.maxWidth = double.infinity,
    this.onOpenChanged,
    this.onWidthChanged,
    this.backgroundColor,
    this.handleColor = Colors.black12,
  });

  @override
  State<ResizableSidePanel> createState() => _ResizableSidePanelState();
}

class _ResizableSidePanelState extends State<ResizableSidePanel> {
  late double _panelWidth;

  @override
  void initState() {
    super.initState();
    _panelWidth = widget.initialWidth;
  }

  @override
  void didUpdateWidget(covariant ResizableSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // initialWidth が変わった場合、現在値がはみ出していれば補正
    if (oldWidget.initialWidth != widget.initialWidth) {
      _panelWidth = _panelWidth.clamp(widget.minWidth, widget.maxWidth);
    }
  }

  @override
  Widget build(BuildContext context) {

    return Material(
      elevation: 0,
      color: Colors.transparent,
      child: Row(
        children: [
          // 左端ドラッグハンドル
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: (details) {
              setState(() {
                _panelWidth -= details.delta.dx;
                if (_panelWidth < widget.minWidth) {
                  // minWidth 未満 → 閉じる（幅は記憶したまま）
                  widget.onOpenChanged?.call(false);
                } else if (_panelWidth > widget.maxWidth) {
                  _panelWidth = widget.maxWidth;
                } else {
                  widget.onWidthChanged?.call(_panelWidth);
                }
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                width: 28,
                color: widget.handleColor,
                child: const Center(
                  child: VerticalDivider(width: 2, thickness: 2),
                ),
              ),
            ),
          ),
          // パネル本体
          Expanded(
            // Material で塗る（Container だと中の ListTile の押した色や波紋が隠れ、debug では毎フレーム assertion が出る）
            child: Material(
              color: widget.backgroundColor ??
                  Theme.of(context).colorScheme.surface,
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}
