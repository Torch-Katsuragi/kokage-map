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
/// [AppLogger.buffer] を画面上で読むためのオーバーレイ。
///
/// 左下に小さな `LOG n` チップを出し、タップでログ一覧を開く。
///
/// ⚠ **web のログはこれで読むこと。** ブラウザのコンソール・`window`・DOM は
/// どれも当てにならなかった（2026-08-28、[AppLogger] のドキュメント参照）。
/// Flutterの外へ出さず、Flutterの中で見るのが唯一確実。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/platform_capabilities.dart';
import '../utils/app_logger.dart';

/// デバッグログのオーバーレイ。web の開発ビルド（debug か `K_LOG`）でだけチップを出す
///
/// ⚠ 製品版には出さない（開発用の道具を製品UIに置かない）。
/// 本番の web で読みたいときは `--dart-define=K_LOG=true` を付けてビルドする。
class DebugLogOverlay extends StatefulWidget {
  final Widget child;

  const DebugLogOverlay({super.key, required this.child});

  @override
  State<DebugLogOverlay> createState() => _DebugLogOverlayState();
}

class _DebugLogOverlayState extends State<DebugLogOverlay> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    // ⚠ Android では出さない（現場の画面に邪魔）。web は開発の観測手段そのもの
    if (!PlatformCapabilities.isWeb || !AppLogger.enabled) return widget.child;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          widget.child,
          Positioned(
            left: 4,
            bottom: 4,
            child: ValueListenableBuilder<int>(
              valueListenable: AppLogger.revision,
              builder: (context, rev, _) => GestureDetector(
                onTap: () => setState(() => _open = !_open),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'LOG ${AppLogger.buffer.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_open)
            Positioned(
              left: 4,
              right: 4,
              bottom: 24,
              height: 360,
              child: Material(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 8),
                        const Text(
                          'AppLogger',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.copy,
                              color: Colors.white, size: 16),
                          tooltip: 'コピー',
                          onPressed: () => Clipboard.setData(
                            ClipboardData(
                                text: AppLogger.buffer.join('\n')),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close,
                              color: Colors.white, size: 16),
                          onPressed: () => setState(() => _open = false),
                        ),
                      ],
                    ),
                    Expanded(
                      child: ValueListenableBuilder<int>(
                        valueListenable: AppLogger.revision,
                        builder: (context, rev, _) => ListView.builder(
                          reverse: true, // 最新が下＝開いた瞬間に最新が見える
                          itemCount: AppLogger.buffer.length,
                          itemBuilder: (context, i) {
                            final line = AppLogger
                                .buffer[AppLogger.buffer.length - 1 - i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 1),
                              child: SelectableText(
                                line,
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
