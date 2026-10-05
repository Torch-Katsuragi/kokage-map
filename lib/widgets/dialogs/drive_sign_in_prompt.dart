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
/// Driveのサインイン導線。
///
/// ⚠ web は「アカウントを選ぶ」と「Driveへのアクセスを許可」が**別の操作**で、
/// 前者は Google が描画したボタンでしか、後者はクリックの直下でしか通らない。
/// どちらが要るかは状態で決まるので、出すボタンは常に1つに絞る。
/// （native はアカウント選択と認可が `signIn()` 1回で済む）
library;

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../services/google_drive/index.dart';
import '../../utils/app_logger.dart';
import '../auth/google_sign_in_button.dart';

/// サインインが済むまでの案内。済んだら [onSignedIn] を呼ぶ
class DriveSignInPrompt extends StatefulWidget {
  final VoidCallback? onSignedIn;

  const DriveSignInPrompt({super.key, this.onSignedIn});

  @override
  State<DriveSignInPrompt> createState() => _DriveSignInPromptState();
}

class _DriveSignInPromptState extends State<DriveSignInPrompt> {
  final GoogleDriveService _driveService = GoogleDriveService();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // One Tap は画面を出した後から返ってくる。届いたらボタンを差し替える
    _driveService.authState.addListener(_onAuthChanged);
    _initialize();
  }

  @override
  void dispose() {
    _driveService.authState.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() {});
    if (_driveService.authState.isAuthenticated) widget.onSignedIn?.call();
  }

  Future<void> _initialize() async {
    setState(() => _isLoading = true);
    try {
      // ⚠ ここで認可の復元を呼ばないこと。ダイアログを組み立てている間に
      // ユーザー操作の有効時間が切れ、ポップアップがブロックされる。
      // 復元は `ensureDriveAuthenticated` がクリック直後に済ませている。
      await _driveService.initialize();
    } catch (e) {
      AppLogger.error('[DriveSignInPrompt] 初期化エラー: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    if (mounted && _driveService.authState.isAuthenticated) {
      widget.onSignedIn?.call();
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final success = await _driveService.signIn();
      if (!success) _errorMessage = _driveService.authState.errorMessage ?? t.drive.signInFailed;
      if (success) widget.onSignedIn?.call();
    } catch (e) {
      _errorMessage = t.drive.signInError(error: e.toString());
      AppLogger.error('[DriveSignInPrompt] サインインエラー: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // アカウントがまだ無い web は、Googleが描画するボタンだけが入口
    final needsAccount = !_driveService.hasAccount;
    final rendered = needsAccount ? googleRenderedSignInButton() : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.account_circle, size: 48, color: Colors.grey),
        const SizedBox(height: 16),
        Text(
          needsAccount
              ? 'Googleアカウントにサインインしてください'
              : 'Google Driveへのアクセスを許可してください',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        if (rendered != null)
          SizedBox(height: 44, child: rendered)
        else
          ElevatedButton.icon(
            onPressed: _isLoading ? null : _signIn,
            icon: _isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(needsAccount ? 'Googleでサインイン' : 'アクセスを許可'),
          ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

/// [DriveSignInPrompt] をダイアログで出す。サインインできたら true
///
/// ツリーの ⋮ メニューのように、サインインUIを持たない経路から使う。
class DriveSignInDialog extends StatelessWidget {
  const DriveSignInDialog({super.key});

  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => const DriveSignInDialog(),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.cloud, color: Colors.blue.shade600),
          const SizedBox(width: 8),
          const Text('Google Drive'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: DriveSignInPrompt(
          onSignedIn: () => Navigator.of(context).pop(true),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.common.cancel),
        ),
      ],
    );
  }
}
