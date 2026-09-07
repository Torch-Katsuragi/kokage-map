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
// フルスクリーン写真ビューワー
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import '../i18n/strings.g.dart';

/// フルスクリーン写真ビューワーウィジェット
/// photo_viewパッケージを使用した高機能な画像表示
/// - 縦長・横長どちらの画像も最適に表示
/// - ピンチズーム、ダブルタップズーム、パン対応
/// - 全プラットフォーム対応（Android, iOS, Web, Windows, macOS, Linux）
class PhotoViewer extends StatelessWidget {
  final String imagePath;

  const PhotoViewer({
    super.key,
    required this.imagePath,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 画像表示エリア（photo_viewで自動的にアスペクト比最適化）
          PhotoView(
            imageProvider: FileImage(File(imagePath)),
            // 初期スケール: 画像全体が画面に収まるように表示
            minScale: PhotoViewComputedScale.contained,
            // 最大スケール: 画像サイズの3倍まで拡大可能
            maxScale: PhotoViewComputedScale.covered * 3.0,
            initialScale: PhotoViewComputedScale.contained,
            backgroundDecoration: const BoxDecoration(
              color: Colors.black,
            ),
            // エラー時の表示
            errorBuilder: (context, error, stackTrace) {
              return Container(
                color: Colors.grey.shade900,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.broken_image,
                        color: Colors.white54,
                        size: 64,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        t.photoViewer.loadError,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          // 閉じるボタン（右上）
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: t.photoViewer.close,
              ),
            ),
          ),
          // 下部ヒント
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.transparent,
                  ],
                ),
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 8,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: Text(
                t.photoViewer.zoomHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// フルスクリーン写真ビューワーを表示するヘルパー関数
void showPhotoViewer(
  BuildContext context, {
  required String imagePath,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => PhotoViewer(
        imagePath: imagePath,
      ),
    ),
  );
}
