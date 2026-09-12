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
// こかげマップ: 地図の上に浮かぶ情報カードの共通の枠
//
// フィーチャ1件の詳細・複数選択の集計・現在位置の情報など、地図の左上に出す
// カードはすべてこの枠を使う（見た目・幅・閉じるボタンを揃えるため）。

import 'package:flutter/material.dart';

/// 情報カードを下パネル／サイドパネルに埋めるとき、その中で「幅いっぱい・高さは親任せ」にする印
class InfoPanelFill extends InheritedWidget {
  const InfoPanelFill({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InfoPanelFill>() != null;

  @override
  bool updateShouldNotify(InfoPanelFill oldWidget) => false;
}

class InfoPanelCard extends StatelessWidget {
  const InfoPanelCard({
    super.key,
    required this.title,
    required this.children,
    this.width = 220,
    this.maxHeight = 300,
    required this.onClose,
  });

  final String title;
  final List<Widget> children;
  final double width;
  final double maxHeight;

  /// 右上の × 。地図の上のカードは全部これで閉じられる
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final fill = InfoPanelFill.of(context);
    return Material(
      elevation: fill ? 0 : 4,
      borderRadius: BorderRadius.circular(fill ? 0 : 12),
      color: fill ? Colors.white : Colors.white.withValues(alpha: 0.8),
      child: Container(
        width: fill ? double.infinity : width,
        constraints: fill ? const BoxConstraints() : BoxConstraints(maxHeight: maxHeight),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(fill ? 0 : 12),
          border: fill ? null : Border.all(color: Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onClose,
                ),
              ],
            ),
            const SizedBox(height: 8),
            // スクロール可能にしつつ、内容に応じて縮小
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
