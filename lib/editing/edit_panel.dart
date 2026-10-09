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

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../providers/notification_providers.dart';
import '../tutorial/tutorial.dart';
import '../widgets/feature_silhouette.dart';
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
  final _controllers = <String, TextEditingController>{};

  TextEditingController _controller(String col, Object? value) =>
      _controllers.putIfAbsent(col, () => TextEditingController(text: value == null ? '' : '$value'));

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

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
                            final ok = await ref.read(featureEditorProvider.notifier).save();
                            if (!ok && context.mounted) {
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
    return ListView(
      // 欄の名前は枠の上にはみ出して出るので、上に少し空ける
      padding: const EdgeInsets.only(top: 8),
      children: [
        for (final c in s.columns)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              key: c == 'name' ? TutorialTargets.nameField : null,
              controller: _controller(c, s.originalAttrs[c]),
              decoration: InputDecoration(labelText: c, isDense: true, border: const OutlineInputBorder()),
              minLines: 1,
              maxLines: c.toLowerCase().contains('memo') || c.contains('メモ') ? 4 : 1,
              onChanged: (v) => ref.read(featureEditorProvider.notifier).setAttr(c, v.isEmpty ? null : v),
            ),
          ),
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
        const d = Distance();
        var len = 0.0;
        final l = s.geom.first;
        for (var i = 1; i < l.length; i++) {
          len += d(l[i - 1], l[i]);
        }
        return t.featureEdit.lineStats(n: n, len: len >= 1000 ? '${(len / 1000).toStringAsFixed(2)} km' : '${len.toStringAsFixed(1)} m');
      case EditKind.polygon:
        final a = _area(s.geom);
        return t.featureEdit.polygonStats(n: n, area: a >= 10000 ? '${(a / 10000).toStringAsFixed(3)} ha' : '${a.toStringAsFixed(1)} m²');
    }
  }

  /// 面積（m²、平面近似。外周から穴を引く）
  double _area(List<List<LatLng>> rings) {
    double ringArea(List<LatLng> r) {
      if (r.length < 3) return 0;
      final lat0 = r.first.latitude * math.pi / 180;
      const my = 110540.0;
      final mx = 111320.0 * math.cos(lat0);
      var sum = 0.0;
      for (var i = 0; i < r.length; i++) {
        final a = r[i];
        final b = r[(i + 1) % r.length];
        sum += a.longitude * mx * b.latitude * my - b.longitude * mx * a.latitude * my;
      }
      return sum.abs() / 2;
    }

    if (rings.isEmpty) return 0;
    return math.max(0, ringArea(rings.first) - rings.skip(1).fold<double>(0, (a, r) => a + ringArea(r)));
  }
}
