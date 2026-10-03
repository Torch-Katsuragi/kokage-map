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
/// Drive連携フォルダのURLをQRコードで見せる。
///
/// > [!IMPORTANT] 共有の単位は「dir」
/// > 連携dirは**それ自体が自己完結した共有可能な単位**。
/// > このQRを読んだ端末は `SyncEngine.cloneFromDrive()` で
/// > データ・スタイル・`project.qgs` を丸ごと受け取る。**サーバ不要**。
/// > 設計は [[docs/technical/project-format-design#共有の単位は「dir」]]。
///
/// 受け側（`mobile_scanner` でのスキャン）は実装済み。ここは出す側。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/shared_link.dart';
import '../../i18n/strings.g.dart';
import '../../services/google_drive/google_drive_service.dart';

/// [driveUrl] のQRコードを出すダイアログ。
///
/// 画面が小さい端末でも読み取れるよう、QRは表示領域いっぱいまで広げる。
class DriveQrDialog extends StatelessWidget {
  const DriveQrDialog({
    super.key,
    required this.folderName,
    required this.driveUrl,
  });

  final String folderName;
  final String driveUrl;

  static Future<void> show(
    BuildContext context, {
    required String folderName,
    required String driveUrl,
  }) {
    return showDialog<void>(
      context: context,
      builder:
          (_) => DriveQrDialog(folderName: folderName, driveUrl: driveUrl),
    );
  }

  @override
  Widget build(BuildContext context) {
    // QR はこかげマップの共有リンクにする（読むとアプリが開いて取り込む。アプリが無ければ案内のページ）。
    // Drive の URL から ID が取れなければ従来どおり Drive の URL のまま
    final id = GoogleDriveService.extractFolderIdFromUrl(driveUrl);
    final link = id == null ? driveUrl : sharedMapLink(id);
    final maxSide = MediaQuery.of(context).size.shortestSide;
    // ダイアログの余白ぶんを引いて、それでも大きすぎない値に収める
    final qrSize = (maxSide - 120).clamp(160.0, 320.0);

    return AlertDialog(
      title: Text(t.driveQr.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              folderName,
              style: const TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            // QRは常に白地・黒。端末のダークテーマでも読めるように固定する
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: link,
                size: qrSize,
                backgroundColor: Colors.white,
                // 印刷して現場に持っていく使い方を想定し、誤り訂正は高めに
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t.driveQr.description,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            SelectableText(
              link,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (!context.mounted) return;
            Navigator.pop(context);
          },
          icon: const Icon(Icons.copy, size: 18),
          label: Text(t.driveQr.copyUrl),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.close),
        ),
      ],
    );
  }
}
