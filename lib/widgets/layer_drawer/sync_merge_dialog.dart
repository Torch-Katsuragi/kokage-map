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
/// Root Maps: 同期マージダイアログ
/// ファイル単位でローカル/クラウドを選択できるマージUI
library;

import 'package:flutter/material.dart';
import '../../i18n/strings.g.dart';
import '../../services/google_drive/sync_engine.dart';

/// 同期モード
enum SyncMode {
  upload,   // ローカル → クラウド
  download, // クラウド → ローカル
}

/// 同期マージダイアログ
class SyncMergeDialog extends StatefulWidget {
  final String folderName;
  final List<MergeFileEntry> entries;
  final SyncMode mode;

  const SyncMergeDialog({
    super.key,
    required this.folderName,
    required this.entries,
    required this.mode,
  });

  /// ダイアログを表示してマージ決定を取得
  static Future<List<MergeDecision>?> show(
    BuildContext context, {
    required String folderName,
    required List<MergeFileEntry> entries,
    required SyncMode mode,
  }) {
    return showDialog<List<MergeDecision>>(
      context: context,
      builder: (context) => SyncMergeDialog(
        folderName: folderName,
        entries: entries,
        mode: mode,
      ),
    );
  }

  @override
  State<SyncMergeDialog> createState() => _SyncMergeDialogState();
}

class _SyncMergeDialogState extends State<SyncMergeDialog> {
  late Map<String, MergeChoice> _choices;

  @override
  void initState() {
    super.initState();
    _initChoices();
  }

  void _initChoices() {
    _choices = {};
    for (final entry in widget.entries) {
      if (entry.mergeable) {
        // 両方が変えた gpkg は、行単位で合わせるのを既定にする
        _choices[entry.relativePath] = MergeChoice.merge;
        continue;
      }
      // モードに応じて初期値を設定
      // アップロード: ローカル変更があればローカル、なければリモート
      // ダウンロード: リモート変更があればリモート、なければローカル
      _choices[entry.relativePath] = widget.mode == SyncMode.upload
          ? (entry.localChange != MergeChangeType.none ? MergeChoice.local : MergeChoice.remote)
          : (entry.remoteChange != MergeChangeType.none ? MergeChoice.remote : MergeChoice.local);
    }
  }

  String get _title => widget.mode == SyncMode.upload
      ? t.layerDrawer.folder.uploadTitle(name: widget.folderName)
      : t.layerDrawer.folder.downloadTitle(name: widget.folderName);

  String get _description => widget.mode == SyncMode.upload
      ? t.layerDrawer.folder.uploadDesc
      : t.layerDrawer.folder.downloadDesc;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.entries.isEmpty
            ? Center(child: Text(t.layerDrawer.folder.noChanges))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 説明文
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _description,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  // ヘッダー
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        _buildColumnHeader(t.layerDrawer.folder.localLabel),
                        _buildColumnHeader(t.layerDrawer.folder.cloudLabel),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  // ファイルリスト
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.entries.length,
                      itemBuilder: (context, index) {
                        return _buildFileRow(widget.entries[index]);
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.common.cancel),
        ),
        if (widget.entries.isNotEmpty)
          FilledButton(
            onPressed: _onSync,
            child: Text(t.layerDrawer.folder.syncExecute),
          ),
      ],
    );
  }

  /// 「端末」「クラウド」の列見出し
  Widget _buildColumnHeader(String label) => Expanded(
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  /// 片側を押したとき。両方変わっていればその側に決め、片方だけなら端末とクラウドを入れ替える
  void _onSideTap(MergeFileEntry entry, MergeChoice side, {required bool isConflict}) {
    setState(() {
      final current = _choices[entry.relativePath] ?? MergeChoice.local;
      _choices[entry.relativePath] = isConflict
          ? side
          : (current == MergeChoice.local ? MergeChoice.remote : MergeChoice.local);
    });
  }

  Widget _buildFileRow(MergeFileEntry entry) {
    final choice = _choices[entry.relativePath] ?? MergeChoice.local;
    final isLocalSelected = choice == MergeChoice.local;
    final isRemoteSelected = choice == MergeChoice.remote;
    final isMergeSelected = choice == MergeChoice.merge;
    final hasLocalChange = entry.localChange != MergeChangeType.none;
    final hasRemoteChange = entry.remoteChange != MergeChangeType.none;
    final isConflict = hasLocalChange && hasRemoteChange;

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // ローカル側（変更がある場合のみ表示）
          Expanded(
            child: hasLocalChange
                ? _buildFileMarker(
                    entry.relativePath,
                    entry.localChange,
                    isChecked: isLocalSelected,
                    onTap: () => _onSideTap(entry, MergeChoice.local, isConflict: isConflict),
                  )
                : const SizedBox.shrink(),
          ),
          // クラウド側（変更がある場合のみ表示）
          Expanded(
            child: hasRemoteChange
                ? _buildFileMarker(
                    entry.relativePath,
                    entry.remoteChange,
                    isChecked: isRemoteSelected,
                    onTap: () => _onSideTap(entry, MergeChoice.remote, isConflict: isConflict),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
    if (!entry.mergeable) return row;

    // 両方が変えた gpkg: 行単位で合わせる選択肢（既定）
    const mergeColor = Colors.purple;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        Padding(
          padding: const EdgeInsets.only(left: 18, bottom: 6),
          child: InkWell(
            onTap: () => setState(() => _choices[entry.relativePath] = MergeChoice.merge),
            child: Opacity(
              opacity: isMergeSelected ? 1.0 : 0.6,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSelectionIndicator(isMergeSelected, mergeColor),
                  Flexible(
                    child: Text(
                      t.layerDrawer.folder.mergeLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isMergeSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.call_merge, size: 14, color: mergeColor),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// ファイルマーカー（チェックボックス + ファイル名 + アイコン）
  Widget _buildFileMarker(
    String relativePath,
    MergeChangeType changeType, {
    required bool isChecked,
    required VoidCallback onTap,
  }) {
    final icon = _getChangeIcon(changeType);
    final baseColor = _getChangeColor(changeType);
    // チェックされていない場合はグレーアウト
    final color = isChecked ? baseColor : baseColor.withValues(alpha: 0.4);
    final textColor = isChecked
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);

    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: isChecked ? 1.0 : 0.6,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSelectionIndicator(isChecked, baseColor),
            Flexible(
              child: Text(
                relativePath, // サブフォルダも含めて表示
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isChecked ? FontWeight.bold : FontWeight.normal,
                  color: textColor,
                  decoration: changeType == MergeChangeType.deleted
                      ? TextDecoration.lineThrough
                      : null,
                ),
                softWrap: true,
              ),
            ),
            const SizedBox(width: 4),
            Icon(icon, size: 14, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionIndicator(bool isSelected, Color changeColor) {
    return Container(
      width: 14,
      height: 14,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? changeColor : Colors.transparent,
        border: Border.all(
          color: isSelected ? changeColor : Colors.grey,
          width: 1.5,
        ),
      ),
      child: isSelected
          ? const Icon(Icons.check, size: 10, color: Colors.white)
          : null,
    );
  }

  IconData _getChangeIcon(MergeChangeType changeType) => switch (changeType) {
        MergeChangeType.added => Icons.add,
        MergeChangeType.modified || MergeChangeType.none => Icons.circle,
        MergeChangeType.deleted => Icons.remove,
        MergeChangeType.moved => Icons.arrow_forward,
      };

  Color _getChangeColor(MergeChangeType changeType) => switch (changeType) {
        MergeChangeType.added => Colors.green,
        MergeChangeType.modified => Colors.orange,
        MergeChangeType.deleted => Colors.red,
        MergeChangeType.moved => Colors.blue,
        MergeChangeType.none => Colors.grey,
      };

  void _onSync() {
    final decisions = [
      for (final entry in widget.entries)
        if (_choices[entry.relativePath] case final choice?)
          if (entry.localChange != MergeChangeType.none ||
              entry.remoteChange != MergeChangeType.none)
            MergeDecision(entry: entry, choice: choice),
    ];
    Navigator.of(context).pop(decisions);
  }
}
