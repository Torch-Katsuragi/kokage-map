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
// Root Maps: Drive URL入力ダイアログ
// Google DriveフォルダのURLを入力またはQRスキャンしてクローンする

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../services/google_drive/index.dart';
import '../../utils/app_logger.dart';
import 'drive_sign_in_prompt.dart';

/// Drive URL入力ダイアログの結果
class DriveUrlInputResult {
  /// DriveフォルダID
  final String folderId;

  /// Driveフォルダ名
  final String folderName;

  /// 元のURL
  final String url;

  /// 読み取り専用か
  final bool isReadOnly;

  /// JSONで定義された共有フォルダセットか
  final bool isFolderSet;

  /// フォルダセットの場合のマニフェスト（検証時に取得済みの場合）
  final DriveFolderSetManifest? folderSetManifest;

  const DriveUrlInputResult({
    required this.folderId,
    required this.folderName,
    required this.url,
    required this.isReadOnly,
    this.isFolderSet = false,
    this.folderSetManifest,
  });
}

/// Drive URL入力ダイアログ
class DriveUrlInputDialog extends StatefulWidget {
  const DriveUrlInputDialog({super.key, @visibleForTesting this.driveService});

  /// テスト用の差し替え。null なら本物のシングルトン
  final GoogleDriveService? driveService;

  /// ダイアログを表示
  static Future<DriveUrlInputResult?> show(
    BuildContext context, {
    @visibleForTesting GoogleDriveService? driveService,
  }) {
    return showDialog<DriveUrlInputResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => DriveUrlInputDialog(driveService: driveService),
    );
  }

  @override
  State<DriveUrlInputDialog> createState() => _DriveUrlInputDialogState();
}

class _DriveUrlInputDialogState extends State<DriveUrlInputDialog>
    with SingleTickerProviderStateMixin {
  late final GoogleDriveService _driveService = widget.driveService ?? GoogleDriveService();
  final TextEditingController _urlController = TextEditingController();

  late TabController _tabController;

  bool _isLoading = false;
  bool _isSignedIn = false;

  /// URL検証の入力待ちと世代番号
  ///
  /// ⚠ 1文字ごとに叩くと、**途中まで打ったURLの応答が後から届いて
  /// 正しい結果を上書きする**（打ち終わっているのに「アクセスできません」の
  /// まま止まる）。打ち終わりを待ち、古い応答は捨てること。
  Timer? _validateDebounce;
  int _validateSeq = 0;
  String? _errorMessage;

  /// エラーが取り直せば直りうるもの（圏外など）か。再試行のボタンを出す
  bool _canRetry = false;
  String? _folderName;
  String? _folderId;
  bool? _isReadOnly;
  bool _isFolderSet = false;
  DriveFolderSetManifest? _folderSetManifest;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _hasQrTab ? 2 : 1, vsync: this);
    // サインイン済みなら最初から入力欄を出す（サインインの案内を一瞬挟まない）
    _isSignedIn = _driveService.authState.isAuthenticated;
    // One Tap は開いた後から返ってくる。届いたらボタンを差し替える
    _driveService.authState.addListener(_onAuthChanged);
    _initializeAuth();
  }

  @override
  void dispose() {
    _validateDebounce?.cancel();
    _driveService.authState.removeListener(_onAuthChanged);
    _tabController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() => _isSignedIn = _driveService.authState.isAuthenticated);
  }

  /// 認証状態を初期化
  Future<void> _initializeAuth() async {
    setState(() => _isLoading = true);
    try {
      await _driveService.initialize();
      _isSignedIn = _driveService.authState.isAuthenticated;
    } catch (e) {
      AppLogger.error('[DriveUrlInputDialog] 初期化エラー: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// クリップボードから貼り付け
  Future<void> _pasteFromClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || !mounted) return;
    _validateDebounce?.cancel();
    _urlController.text = text;
    await _validateUrl();
  }

  /// URLを検証してフォルダ情報を取得
  /// 打ち終わりを待ってから検証する
  void _scheduleValidateUrl() {
    _validateDebounce?.cancel();
    _validateDebounce = Timer(
      const Duration(milliseconds: 400),
      _validateUrl,
    );
  }

  /// 見つけたフォルダを忘れ、[error] を出す（null なら何も出さない）。
  /// [canRetry] なら再試行のボタンを添える
  void _clearFolder([String? error, bool canRetry = false]) {
    if (!mounted) return;
    setState(() {
      _errorMessage = error;
      _canRetry = canRetry;
      _folderName = null;
      _folderId = null;
      _isReadOnly = null;
      _isFolderSet = false;
      _folderSetManifest = null;
      _isLoading = false;
    });
  }

  Future<void> _validateUrl() async {
    final seq = ++_validateSeq;
    final url = _urlController.text.trim();
    if (url.isEmpty) return _clearFolder();

    // URLからフォルダIDを抽出
    final folderId = GoogleDriveService.extractFolderIdFromUrl(url);
    if (folderId == null) return _clearFolder(t.drive.invalidUrl);

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _canRetry = false;
    });

    try {
      // フォルダを確かめる。失敗は「圏外」「権限なし」「無い」「その他」で文言を分ける
      // （⚠ 圏外を「共有設定を確認」と出すと、直す必要のない共有設定を触りに行かせる）
      final lookup = await _driveService.lookupFolder(folderId);
      // 追い越された応答・閉じたあとの応答は捨てる
      if (seq != _validateSeq || !mounted) return;
      final folderInfo = lookup.folder;
      if (folderInfo == null) return _clearFolder(lookup.message, lookup.canRetry);

      // 権限を確認（編集可能かどうか）
      final canEdit = folderInfo.capabilities?.canEdit ?? false;
      final isJsonSet = GoogleDriveService.isJsonFileMetadata(folderInfo);
      if (!isJsonSet && !GoogleDriveService.isFolderMetadata(folderInfo)) {
        return _clearFolder(t.drive.invalidUrl);
      }
      DriveFolderSetManifest? manifest;
      if (isJsonSet) {
        try {
          manifest = await DriveFolderSetService(driveService: _driveService)
              .fetchManifest(folderId, fallbackName: folderInfo.name);
        } catch (e) {
          if (seq != _validateSeq || !mounted) return;
          AppLogger.error('[DriveUrlInputDialog] JSON解析エラー: $e');
          return _clearFolder(t.drive.invalidFolderSetJson);
        }
        if (seq != _validateSeq || !mounted) return;
      }

      setState(() {
        _folderId = folderId;
        _folderName = isJsonSet
            ? (manifest?.name ??
                (folderInfo.name?.replaceAll(
                      RegExp(r'\.json$', caseSensitive: false),
                      '',
                    ) ??
                    'Unknown'))
            : (folderInfo.name ?? 'Unknown');
        _isReadOnly = isJsonSet ? true : !canEdit;
        _isFolderSet = isJsonSet;
        _folderSetManifest = manifest;
        _errorMessage = null;
        _canRetry = false;
        _isLoading = false;
      });
    } catch (e) {
      if (seq != _validateSeq) return;
      AppLogger.error('[DriveUrlInputDialog] フォルダ情報取得エラー: $e');
      _clearFolder(t.drive.fetchError(error: e.toString()), true);
    }
  }

  /// クローン実行
  void _onClone() {
    if (_folderId == null || _folderName == null) return;

    Navigator.pop(
      context,
      DriveUrlInputResult(
        folderId: _folderId!,
        folderName: _folderName!,
        url: _urlController.text.trim(),
        isReadOnly: _isReadOnly ?? true,
        isFolderSet: _isFolderSet,
        folderSetManifest: _folderSetManifest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // キーボードが出ると背が足りず下がはみ出していた（2026-09-24、Fold で 15px）
      scrollable: true,
      title: Row(
        children: [
          const Icon(Icons.cloud, color: Colors.blue),
          const SizedBox(width: 8),
          Flexible(child: Text(t.driveUrlDialog.title)),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // タブバー（QRスキャンはカメラのある端末だけ）
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: t.driveUrlDialog.urlTab),
                if (_hasQrTab) Tab(text: t.driveUrlDialog.qrTab),
              ],
            ),
            const SizedBox(height: 16),

            // タブコンテンツ
            SizedBox(
              height: 250,
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildUrlInputTab(),
                  if (_hasQrTab) _buildQrScanTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.cancel),
        ),
        TextButton(
          onPressed: _canClone() ? _onClone : null,
          child: Text(t.drive.clone),
        ),
      ],
    );
  }

  /// QRスキャンのタブを出すか
  bool get _hasQrTab => PlatformCapabilities.supportsQrScan;

  /// 未サインインのときの案内。中身は [DriveSignInPrompt] に任せる
  Widget _buildSignInPrompt() => Center(
        child: DriveSignInPrompt(
          onSignedIn: () {
            if (mounted) setState(() => _isSignedIn = true);
          },
        ),
      );

  /// URL入力タブ
  Widget _buildUrlInputTab() {
    if (!_isSignedIn) return _buildSignInPrompt();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // URL入力フィールド
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: t.driveUrlDialog.urlLabel,
              hintText: 'https://drive.google.com/drive/folders/...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                onPressed: _pasteFromClipboard,
                tooltip: t.drive.paste,
              ),
            ),
            onChanged: (_) => _scheduleValidateUrl(),
            maxLines: 2,
          ),
          const SizedBox(height: 16),

          // ローディング
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            ),

          // エラーメッセージ
          if (_errorMessage != null) _buildErrorBox(_errorMessage!),

          // フォルダ情報
          if (_folderName != null && !_isLoading)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _boxDecoration(Colors.green),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        _isFolderSet ? t.drive.folderSetDetected : t.drive.folderDetected,
                        style: const TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        _isFolderSet ? Icons.folder_copy : Icons.folder,
                        color: Colors.blue.shade700,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _folderName!,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        _isReadOnly == true ? Icons.visibility : Icons.edit,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _accessLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// QRスキャンタブ
  Widget _buildQrScanTab() {
    if (!_isSignedIn) return _buildSignInPrompt();

    return Column(
      children: [
        // QRスキャナー
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: MobileScanner(
              onDetect: _onQrDetected,
            ),
          ),
        ),
        const SizedBox(height: 8),
        
        // スキャン結果
        if (_folderName != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: _boxDecoration(Colors.green),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _folderName!,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _accessLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        
        if (_errorMessage != null) _buildErrorBox(_errorMessage!),
      ],
    );
  }

  /// 結果欄の薄い色の角丸背景
  static BoxDecoration _boxDecoration(Color color) => BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      );

  /// 赤い枠のエラー表示（URL タブ・QR タブ共通）。取り直せるものには再試行のボタンを添える
  Widget _buildErrorBox(String message) => Container(
        padding: const EdgeInsets.all(12),
        decoration: _boxDecoration(Colors.red),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
            if (_canRetry) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _isLoading ? null : _retryValidate,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(t.drive.retry),
              ),
            ],
          ],
        ),
      );

  /// 同じ URL でもう一度確かめる
  void _retryValidate() {
    _validateDebounce?.cancel();
    _validateUrl();
  }

  /// 読み取り専用か編集可か
  String get _accessLabel =>
      _isFolderSet
          ? t.drive.folderSetCount(count: _folderSetManifest?.items.length ?? 0)
          : (_isReadOnly == true ? t.drive.readOnly : t.drive.editable);

  /// QRコード検出時の処理
  void _onQrDetected(BarcodeCapture capture) {
    if (_isLoading) return;
    
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      
      // Google Drive URLかチェック
      if (GoogleDriveService.extractFolderIdFromUrl(value) != null) {
        _validateDebounce?.cancel();
        _urlController.text = value;
        _validateUrl();
        
        // URL入力タブに切り替え（結果を見せる）
        _tabController.animateTo(0);
        break;
      }
    }
  }

  /// クローン可能か
  bool _canClone() {
    return _folderId != null && _folderName != null && !_isLoading;
  }
}
