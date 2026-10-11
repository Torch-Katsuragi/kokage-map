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
// こかげマップ: 「地図を PDF に」のダイアログ（用紙・向き・表題・備考 → 作って保存）
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../providers/notification_providers.dart';
import '../services/map_pdf/map_pdf_layout.dart';

/// ダイアログで選んだもの
typedef MapPdfOptions = ({MapPdfPaper paper, bool landscape, String title, String notes});

/// PDF を作る（地図ページが材料を集めて渡す）。[onProgress] は 0〜1
typedef MapPdfBuilder = Future<Uint8List> Function(MapPdfOptions options, void Function(double) onProgress);

/// 前回の用紙・向き（アプリを開いている間だけ覚える）
MapPdfPaper _lastPaper = MapPdfPaper.a4;
bool _lastLandscape = true;

Future<void> showMapPdfDialog(BuildContext context, {required String defaultTitle, required MapPdfBuilder build}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MapPdfDialog(defaultTitle: defaultTitle, build: build),
    );

class _MapPdfDialog extends ConsumerStatefulWidget {
  const _MapPdfDialog({required this.defaultTitle, required this.build});
  final String defaultTitle;
  final MapPdfBuilder build;

  @override
  ConsumerState<_MapPdfDialog> createState() => _MapPdfDialogState();
}

class _MapPdfDialogState extends ConsumerState<_MapPdfDialog> {
  late final _title = TextEditingController(text: widget.defaultTitle);
  final _notes = TextEditingController();
  MapPdfPaper _paper = _lastPaper;
  bool _landscape = _lastLandscape;

  /// 作っている最中なら進み具合（0〜1）
  double? _progress;

  /// 作っている途中で取りやめた（戻る・キャンセル）。できた PDF は捨て、保存先も聞かない
  bool _cancelled = false;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    _lastPaper = _paper;
    _lastLandscape = _landscape;
    final title = _title.text.trim();
    setState(() => _progress = 0);
    final notify = ref.read(notificationCenterProvider.notifier);
    try {
      final bytes = await widget.build(
        (paper: _paper, landscape: _landscape, title: title, notes: _notes.text),
        (v) {
          // 背景地図のタイルを 1 枚読むたびに来る。取りやめたら残りのタイルを読まずに止める
          if (_cancelled) throw const _MapPdfCancelled();
          if (mounted) setState(() => _progress = v);
        },
      );
      if (_cancelled) return;
      final d = DateTime.now();
      final stamp = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
      final base = (title.isEmpty ? 'map' : title).replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      final fileName = '${base}_$stamp.pdf';
      // 保存先を選んでもらう（Android は SAF、web はダウンロード。ほかの書き出しと同じ）
      final saved = await FilePicker.saveFile(
        dialogTitle: t.mapPdf.dialogTitle,
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      if (saved != null) notify.add(title: t.mapPdf.saved(name: fileName), level: NotificationLevel.success);
    } catch (e) {
      if (_cancelled) return;
      notify.add(title: t.mapPdf.failed(error: '$e'), level: NotificationLevel.error);
      if (mounted) setState(() => _progress = null);
    }
  }

  /// 作っている途中で取りやめる。タイルを読んでいる間ならそこで止まり、そのあとの段なら出来上がりを捨てる
  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    ref.read(notificationCenterProvider.notifier).add(title: t.mapPdf.cancelled, level: NotificationLevel.info);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    // 作っている途中の「戻る」は取りやめにする（以前は黙って閉じ、出来上がると保存先を聞いていた）
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && busy) _cancel();
      },
      child: _dialog(context, busy),
    );
  }

  Widget _dialog(BuildContext context, bool busy) {
    return AlertDialog(
      title: Text(t.mapPdf.dialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.mapPdf.about, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(width: 56, child: Text(t.mapPdf.paper)),
                SegmentedButton<MapPdfPaper>(
                  segments: const [
                    ButtonSegment(value: MapPdfPaper.a4, label: Text('A4')),
                    ButtonSegment(value: MapPdfPaper.a3, label: Text('A3')),
                  ],
                  selected: {_paper},
                  onSelectionChanged: busy ? null : (s) => setState(() => _paper = s.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(width: 56, child: Text(t.mapPdf.orientation)),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: true, label: Text(t.mapPdf.landscape)),
                    ButtonSegment(value: false, label: Text(t.mapPdf.portrait)),
                  ],
                  selected: {_landscape},
                  onSelectionChanged: busy ? null : (s) => setState(() => _landscape = s.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _title,
              enabled: !busy,
              decoration: InputDecoration(labelText: t.mapPdf.docTitle),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notes,
              enabled: !busy,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: t.mapPdf.notes, hintText: t.mapPdf.notesHint),
            ),
            if (busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 4),
              Text(t.mapPdf.rendering(percent: '${(_progress! * 100).round()}'),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? _cancel : () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        FilledButton(onPressed: busy ? null : _create, child: Text(t.mapPdf.create)),
      ],
    );
  }
}

/// 作っている途中で取りやめた（タイルの読み込みを止めるために投げる）
class _MapPdfCancelled implements Exception {
  const _MapPdfCancelled();
}
