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
// Root Maps: フォルダ種類選択ダイアログ
// 新規フォルダ作成時に「通常フォルダ」か「Drive連携フォルダ」かを選択

import 'package:flutter/material.dart';
import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';

/// フォルダ追加の種類
enum AddFolderType {
  /// 通常のローカルフォルダ
  local,
  /// Google Drive連携フォルダ
  drive,
}

/// フォルダ種類選択ダイアログの結果
class AddFolderTypeResult {
  final AddFolderType type;
  final String? folderName; // 通常フォルダの場合のみ

  const AddFolderTypeResult({
    required this.type,
    this.folderName,
  });
}

/// フォルダ種類選択ダイアログ
class AddFolderTypeDialog extends StatefulWidget {
  final bool allowDrive;

  const AddFolderTypeDialog({super.key, this.allowDrive = true});

  /// ダイアログを表示
  /// [allowDrive] が false の場合、Driveオプションを非表示にする
  static Future<AddFolderTypeResult?> show(
    BuildContext context, {
    bool allowDrive = true,
  }) {
    return showDialog<AddFolderTypeResult>(
      context: context,
      builder: (context) => AddFolderTypeDialog(allowDrive: allowDrive),
    );
  }

  @override
  State<AddFolderTypeDialog> createState() => _AddFolderTypeDialogState();
}

class _AddFolderTypeDialogState extends State<AddFolderTypeDialog> {
  final TextEditingController _nameController = TextEditingController();
  AddFolderType _selectedType = AddFolderType.local;

  /// Driveオプションを表示するか
  bool get _showDriveOption =>
      widget.allowDrive && PlatformCapabilities.supportsDriveSync;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.addFolder.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showDriveOption) ...[
              Text(
                t.addFolder.folderType,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              _buildTypeOption(
                type: AddFolderType.local,
                icon: Icons.folder,
                iconColor: Colors.amber,
                title: t.addFolder.localFolder,
                subtitle: t.addFolder.localFolderDesc,
              ),
              const SizedBox(height: 8),
              _buildTypeOption(
                type: AddFolderType.drive,
                icon: Icons.cloud,
                iconColor: Colors.blue,
                title: t.addFolder.driveClone,
                subtitle: t.addFolder.driveCloneDesc,
              ),
              const SizedBox(height: 16),
            ],

            // 通常フォルダの場合はフォルダ名入力
            if (_selectedType == AddFolderType.local) ...[
              TextField(
                controller: _nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: t.addFolder.folderName,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _onSubmit(),
              ),
            ],

            // Driveフォルダの場合は説明
            if (_selectedType == AddFolderType.drive) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.addFolder.driveUrlHint,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.cancel),
        ),
        TextButton(
          onPressed: _canSubmit() ? _onSubmit : null,
          child: Text(_selectedType == AddFolderType.local ? t.addFolder.create : t.addFolder.next),
        ),
      ],
    );
  }

  /// 種類選択オプションを構築
  Widget _buildTypeOption({
    required AddFolderType type,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _selectedType == type;
    return InkWell(
      onTap: () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected ? Theme.of(context).primaryColor : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
          color: isSelected ? Theme.of(context).primaryColor.withValues(alpha: 0.05) : null,
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).primaryColor,
              ),
          ],
        ),
      ),
    );
  }

  /// 送信可能か
  bool _canSubmit() {
    if (_selectedType == AddFolderType.local) {
      return _nameController.text.trim().isNotEmpty;
    }
    return true; // Driveの場合は常に次へ進める
  }

  /// 送信処理
  void _onSubmit() {
    if (!_canSubmit()) return;
    
    Navigator.pop(
      context,
      AddFolderTypeResult(
        type: _selectedType,
        folderName: _selectedType == AddFolderType.local
            ? _nameController.text.trim()
            : null,
      ),
    );
  }
}
