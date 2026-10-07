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
/// Root Maps: オーバーレイ変換ダイアログ
///
/// 通常の写真をGeoTIFFオーバーレイに変換する際の設定ダイアログ。
/// 変換後のファイル名と、変換時に適用する画像処理を選択できる。
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../i18n/strings.g.dart';

/// 変換時の画像処理モード
enum OverlayConvertMode {
  /// 何もしない（元画像をそのまま使用）
  none,

  /// 輝度→透明度（グラデーション）
  /// 明るい部分ほど透明に、暗い部分ほど不透明に
  brightnessToAlpha,

  /// 輝度で透明/不透明に分離（閾値ベース）
  /// 閾値以上 → 完全透明、未満 → 完全不透明（色は維持）
  alphaBinarize,

  /// 白黒2値化 + 白部分透明化
  /// 画像をまず白黒にし、白い部分を透明化
  bwTransparent,
}

/// ダイアログの戻り値
class OverlayConvertResult {
  /// 変換後のファイル名（拡張子なし）
  final String outputName;

  /// 適用する処理モード
  final OverlayConvertMode mode;

  /// 閾値（0.0〜1.0、alphaBinarize/bwTransparent時に使用）
  final double threshold;

  const OverlayConvertResult({
    required this.outputName,
    required this.mode,
    this.threshold = 0.5,
  });
}

/// オーバーレイ変換ダイアログを表示
///
/// [srcFileName] 元画像のファイル名（拡張子付き）
/// 戻り値: ユーザーがキャンセルした場合null
Future<OverlayConvertResult?> showOverlayConvertDialog(
  BuildContext context, {
  required String srcFileName,
}) {
  return showDialog<OverlayConvertResult>(
    context: context,
    builder: (ctx) => _OverlayConvertDialog(srcFileName: srcFileName),
  );
}

class _OverlayConvertDialog extends StatefulWidget {
  final String srcFileName;

  const _OverlayConvertDialog({required this.srcFileName});

  @override
  State<_OverlayConvertDialog> createState() => _OverlayConvertDialogState();
}

class _OverlayConvertDialogState extends State<_OverlayConvertDialog> {
  late final TextEditingController _nameController;
  OverlayConvertMode _mode = OverlayConvertMode.none;
  double _threshold = 0.5;

  @override
  void initState() {
    super.initState();
    final baseName = p.basenameWithoutExtension(widget.srcFileName);
    _nameController = TextEditingController(text: baseName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 現在のモードで閾値スライダーを表示するか
  bool get _showThreshold =>
      _mode == OverlayConvertMode.alphaBinarize ||
      _mode == OverlayConvertMode.bwTransparent;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(t.layerDrawer.photo.convertToOverlay),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ファイル名入力
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: t.overlayConvert.outputName,
                suffixText: '.tif',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            // 画像処理モード
            Text(
              t.overlayConvert.effectLabel,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),

            RadioGroup<OverlayConvertMode>(
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v!),
              child: Column(
                children: [
                  for (final (mode, title, desc) in [
                    (
                      OverlayConvertMode.none,
                      t.overlayConvert.modeNone,
                      t.overlayConvert.modeNoneDesc,
                    ),
                    (
                      OverlayConvertMode.brightnessToAlpha,
                      t.overlayConvert.modeBrightness,
                      t.overlayConvert.modeBrightnessDesc,
                    ),
                    (
                      OverlayConvertMode.alphaBinarize,
                      t.overlayConvert.modeAlphaBinarize,
                      t.overlayConvert.modeAlphaBinarizeDesc,
                    ),
                    (
                      OverlayConvertMode.bwTransparent,
                      t.overlayConvert.modeBwTransparent,
                      t.overlayConvert.modeBwTransparentDesc,
                    ),
                  ])
                    RadioListTile<OverlayConvertMode>(
                      value: mode,
                      title: Text(title),
                      subtitle: Text(desc),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),

            // 閾値スライダー（alphaBinarize / bwTransparent 時のみ）
            if (_showThreshold) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(t.overlayConvert.threshold),
                  Expanded(
                    child: Slider(
                      value: _threshold,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      label: (_threshold * 100).round().toString(),
                      onChanged: (v) => setState(() => _threshold = v),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(_threshold * 100).round()}%',
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(
              OverlayConvertResult(
                outputName: name,
                mode: _mode,
                threshold: _threshold,
              ),
            );
          },
          child: Text(t.overlayConvert.convert),
        ),
      ],
    );
  }
}
