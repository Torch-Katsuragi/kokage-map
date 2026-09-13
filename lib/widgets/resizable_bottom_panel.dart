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
/// Root Maps: リサイズ可能なボトムパネルウィジェット
/// 属性テーブルなど画面下部に表示するパネル用。
/// ResizableSidePanelの設計を踏襲: リサイズ可能、背景半透明。
/// [Column] の子として配置する前提（Positionedは使わない）。
library;

import 'package:flutter/material.dart';

/// リサイズ可能なボトムパネルウィジェット
///
/// パネル上端にドラッグハンドル（高さリサイズ用）を描画する。
/// [Column] の子として配置し、[Expanded] の兄弟として使用すること。
class ResizableBottomPanel extends StatefulWidget {
  /// パネルの子ウィジェット
  final Widget child;

  /// パネルの初期高さ
  final double initialHeight;

  /// パネルの最小高さ（これ未満にドラッグするとパネルが閉じる）
  final double minHeight;

  /// パネルの最大高さ（絶対値ピクセル）
  ///
  /// ドラッグ時のクランプに使用する。
  /// 呼び出し側で `MediaQuery.of(context).size.height * ratio` 等を渡す。
  final double maxHeight;

  /// パネルの開閉状態変更コールバック
  final void Function(bool isOpen)? onOpenChanged;

  /// パネル高さ変更コールバック
  final void Function(double height)? onHeightChanged;

  /// パネルの背景色
  final Color? backgroundColor;

  /// ドラッグハンドルの色
  final Color handleColor;

  const ResizableBottomPanel({
    super.key,
    required this.child,
    this.initialHeight = 250,
    this.minHeight = 120,
    this.maxHeight = double.infinity,
    this.onOpenChanged,
    this.onHeightChanged,
    this.backgroundColor,
    this.handleColor = Colors.black12,
  });

  @override
  State<ResizableBottomPanel> createState() => _ResizableBottomPanelState();
}

class _ResizableBottomPanelState extends State<ResizableBottomPanel> {
  late double _panelHeight;

  @override
  void initState() {
    super.initState();
    _panelHeight = widget.initialHeight;
  }

  @override
  void didUpdateWidget(covariant ResizableBottomPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // maxHeight が変わった場合、現在値がはみ出していれば補正
    if (oldWidget.maxHeight != widget.maxHeight) {
      _panelHeight = _panelHeight.clamp(widget.minHeight, widget.maxHeight);
    }
  }

  @override
  Widget build(BuildContext context) {
    final clampedHeight = _panelHeight.clamp(widget.minHeight, widget.maxHeight);

    return SizedBox(
      height: clampedHeight,
      child: Material(
        elevation: 0,
        color: Colors.transparent,
        child: Column(
          children: [
            // 上端ドラッグハンドル
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (details) {
                setState(() {
                  _panelHeight -= details.delta.dy;
                  if (_panelHeight < widget.minHeight) {
                    // minHeight 未満 → 閉じる（高さは記憶したまま）
                    widget.onOpenChanged?.call(false);
                  } else if (_panelHeight > widget.maxHeight) {
                    _panelHeight = widget.maxHeight;
                  } else {
                    widget.onHeightChanged?.call(_panelHeight);
                  }
                });
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                child: Container(
                  height: 20,
                  color: widget.handleColor,
                  child: const Center(
                    child: SizedBox(
                      width: 40,
                      child: Divider(height: 2, thickness: 2),
                    ),
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
      ),
    );
  }
}
