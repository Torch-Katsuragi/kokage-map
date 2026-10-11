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
// 編集中の情報パネル（情報パネルの枠のまま編集に替わる）。「形」と「属性」の 2 つ、下に取消・保存。
// 背景には編集中の形を薄く敷き、直すたびに一緒に変わる。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../providers/notification_providers.dart';
import '../tutorial/tutorial.dart';
import '../utils/geodesic.dart';
import '../widgets/feature_silhouette.dart';
import '../widgets/qgis_form/qgis_field_input.dart';
import 'edit_session.dart';
import 'edit_toolbar.dart';

/// 編集をやめる。変更があれば破棄してよいか聞く（取消ボタン・左上の ← ・端末の戻る）
Future<void> cancelEdit(BuildContext context, WidgetRef ref) async {
  final s = ref.read(featureEditorProvider);
  if (s == null || s.saving) return;
  if (s.dirty) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.featureEdit.discardConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.featureEdit.keepEditing)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.featureEdit.discard)),
        ],
      ),
    );
    if (ok != true) return;
  }
  ref.read(featureEditorProvider.notifier).cancel();
}

class EditPanel extends ConsumerStatefulWidget {
  const EditPanel({super.key});

  @override
  ConsumerState<EditPanel> createState() => _EditPanelState();
}

class _EditPanelState extends ConsumerState<EditPanel> {
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(featureEditorProvider);
    if (s == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final kindName = switch (s.kind) {
      EditKind.point => t.featureDetail.typePoint,
      EditKind.line => t.featureDetail.typeLine,
      EditKind.polygon => t.featureDetail.typePolygon,
    };
    return Stack(
      children: [
        Positioned.fill(child: FeatureSilhouette.shape(parts: s.geom, closed: s.kind == EditKind.polygon)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(t.featureEdit.title(kind: kindName),
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                  SegmentedButton<bool>(
                    key: TutorialTargets.attrsSegment,
                    segments: [
                      ButtonSegment(value: false, label: Text(t.featureEdit.shapeTab), icon: const Icon(Icons.polyline, size: 16)),
                      ButtonSegment(value: true, label: Text(t.featureEdit.attrsTab), icon: const Icon(Icons.notes, size: 16)),
                    ],
                    selected: {s.attrsTab},
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    onSelectionChanged: (v) => ref.read(featureEditorProvider.notifier).setAttrsTab(v.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(child: s.attrsTab ? _attrs(s, theme) : _shape(s, theme)),
              Row(
                children: [
                  TextButton(onPressed: s.saving ? null : () => cancelEdit(context, ref), child: Text(t.featureEdit.cancel)),
                  const Spacer(),
                  FilledButton.icon(
                    key: TutorialTargets.editSaveButton,
                    onPressed: s.saving
                        ? null
                        : () async {
                            FocusScope.of(context).unfocus();
                            final ed = ref.read(featureEditorProvider.notifier);
                            final ok = await ed.save();
                            // 制約で止めたときは理由を通知に出してある
                            if (!ok && context.mounted && !ed.lastSaveBlocked) {
                              ref.read(notificationCenterProvider.notifier).add(
                                    title: t.featureEdit.saveFailed,
                                    level: NotificationLevel.error,
                                  );
                            }
                          },
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(t.featureEdit.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _shape(EditState s, ThemeData theme) {
    final hint = switch (s.mode) {
      EditMode.vertex => t.featureEdit.hints.vertex,
      EditMode.move => s.kind == EditKind.point ? t.featureEdit.hints.movePoint : t.featureEdit.hints.move,
      EditMode.rotate => t.featureEdit.hints.rotate,
      EditMode.scale => t.featureEdit.hints.scale,
      EditMode.extend => t.featureEdit.hints.extend,
      EditMode.simplify => t.featureEdit.hints.simplify,
      EditMode.trim => t.featureEdit.hints.trim,
    };
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Row(
          children: [
            Icon(editModeIcon(s.mode), size: 18, color: const Color(0xFFD32F2F)),
            const SizedBox(width: 6),
            Text(editModeName(s.mode), style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 4),
        Text(hint, style: theme.textTheme.bodyMedium),
        if (s.mode == EditMode.simplify) _simplifySlider(s),
        if (s.mode == EditMode.trim) _trimSlider(s),
        const SizedBox(height: 4),
        Text(t.featureEdit.hints.twoFingers, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 10),
        Text(_stats(s), style: theme.textTheme.bodySmall),
      ],
    );
  }

  /// 簡略化: つまみは消える頂点の数に比例（左端は 1 個、右端は線なら 2 点・面なら 3 点を残すところ）。
  /// 表示はその段の許す幅（m）。以前は幅をそのまま 0〜50 m で動かしていて、効き方が形によってまちまちだった
  Widget _simplifySlider(EditState s) {
    final ed = ref.read(featureEditorProvider.notifier);
    final steps = ed.simplifySteps;
    final k = s.tolerance <= 0 ? 0 : steps.where((t) => t <= s.tolerance).length;
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: k.toDouble(),
            max: steps.isEmpty ? 1 : steps.length.toDouble(),
            divisions: steps.isEmpty ? null : steps.length,
            label: '${s.tolerance.toStringAsFixed(1)} m',
            onChangeStart: steps.isEmpty ? null : (_) => ed.sliderStart(),
            onChanged: steps.isEmpty ? null : (v) => ed.setTolerance(v < 1 ? 0 : steps[v.round() - 1]),
            onChangeEnd: steps.isEmpty ? null : (_) => ed.sliderEnd(),
          ),
        ),
        SizedBox(width: 56, child: Text('${s.tolerance.toStringAsFixed(1)} m', textAlign: TextAlign.right)),
      ],
    );
  }

  /// 切り落とす: 残す頂点の範囲
  Widget _trimSlider(EditState s) {
    final ed = ref.read(featureEditorProvider.notifier);
    final max = ed.trimMax;
    if (max < 2) return const SizedBox.shrink();
    final (a, b) = s.trimRange ?? (0, max);
    return RangeSlider(
      values: RangeValues(a.toDouble(), b.toDouble()),
      max: max.toDouble(),
      divisions: max,
      labels: RangeLabels('${a + 1}', '${b + 1}'),
      onChangeStart: (_) => ed.sliderStart(),
      onChanged: (v) => ed.setTrim(v.start.round(), v.end.round()),
      onChangeEnd: (_) => ed.sliderEnd(),
    );
  }

  Widget _attrs(EditState s, ThemeData theme) {
    if (s.columns.isEmpty) {
      return Text(t.featureEdit.noAttrs, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline));
    }
    final ed = ref.read(featureEditorProvider.notifier);
    final form = s.form;
    // QGIS のドラッグ&ドロップの配置があれば、タブ・グループを見出しにして並べる
    final rows = form?.layout == null
        ? [for (final c in s.columns) QgisFormFieldRow(c, depth: 0)]
        : qgisFormRows(form, s.columns);
    return ListView(
      // 欄の名前は枠の上にはみ出して出るので、上に少し空ける
      padding: const EdgeInsets.only(top: 8),
      children: [
        for (final row in rows)
          switch (row) {
            QgisFormHeader() => QgisFormHeaderView(row),
            QgisFormFieldRow(column: final c, :final depth) => Padding(
                padding: EdgeInsets.only(bottom: 10, left: depth * 8.0),
                child: QgisFieldInput(
                  key: c == 'name' ? TutorialTargets.nameField : ValueKey('edit/$c'),
                  column: c,
                  field: form?[c],
                  sqlType: ed.columnType(c),
                  value: s.attrs[c],
                  enabled: s.canEdit(c),
                  options: s.options[c],
                  errorText: s.errors[c],
                  dense: false,
                  multilineFallback: c.toLowerCase().contains('memo') || c.contains('メモ'),
                  onChanged: (v, {required commit}) => ed.setAttr(c, v),
                ),
              ),
          },
      ],
    );
  }

  /// 頂点の数と長さ・面積（直すたびに変わる）
  String _stats(EditState s) {
    final n = s.geom.fold<int>(0, (a, r) => a + r.length);
    switch (s.kind) {
      case EditKind.point:
        final p = s.geom.first.first;
        return '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}';
      case EditKind.line:
        // 情報パネル・計測ツールと同じ測り方（WGS84 楕円体）
        final len = Geodesic.lineLength(s.geom.first);
        return t.featureEdit.lineStats(n: n, len: len >= 1000 ? '${(len / 1000).toStringAsFixed(2)} km' : '${len.toStringAsFixed(1)} m');
      case EditKind.polygon:
        final a = Geodesic.polygonArea(s.geom);
        return t.featureEdit.polygonStats(n: n, area: a >= 10000 ? '${(a / 10000).toStringAsFixed(3)} ha' : '${a.toStringAsFixed(1)} m²');
    }
  }
}
