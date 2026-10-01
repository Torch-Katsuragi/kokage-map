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
// チュートリアルの重ね絵: 案内先を枠で囲み、説明の札を出す。章の一覧もここ。
//
// MaterialApp の builder に置き、どの画面（ダイアログ・写真の選択）の上にも出す。
// 押すのは本物の部品なので、札以外は触れる。画面を暗くしないのはダイアログまで暗くなるため。
// 枠はくすんだ赤。外側のハローだけゆっくり広がって薄れる（目に入るが点滅ほどうるさくない。松本 2026-10-01）。
// 枠が別の場所へ移るときは 0.22 秒で寄っていく（どこへ移ったかを目で追えるように）。
// 案内先の位置は案内中だけ一定間隔で測り直す（一覧の開閉などで動くため）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.g.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../providers/selection_providers.dart';
import '../providers/tool_providers.dart';
import '../providers/ui_state_providers.dart';
import 'practice_project.dart';
import 'tutorial.dart';

class TutorialOverlay extends ConsumerStatefulWidget {
  const TutorialOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TutorialOverlay> createState() => _TutorialOverlayState();
}

/// 案内の枠の色（彩度を抑えた赤）
const _ringColor = Color(0xFFC0504D);

class _TutorialOverlayState extends ConsumerState<TutorialOverlay> with TickerProviderStateMixin {
  Rect? _target;
  Timer? _poll;

  /// ハローの脈動（枠が出ている間だけ回す）
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  /// 枠が別の場所へ移るときの短い移動（出てくるときはその場に出す）
  late final _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Rect? _from;

  /// いま描く枠（移動中は前の場所から寄っていく途中）
  Rect? _shown() {
    final to = _target;
    final from = _from;
    if (to == null || from == null) return to;
    return Rect.lerp(from, to, Curves.easeOutCubic.transform(_move.value));
  }

  // ── 案内先 ──

  Rect? _measure(TutorialState s) {
    if (s.menu) return null;
    final me = context.findRenderObject();
    if (me is! RenderBox) return null;
    // レイヤ一覧が開いているか（練習のレイヤの行が画面にあるか）
    final listOpen = [TutorialTargets.areaTile, TutorialTargets.routeTile, TutorialTargets.pointsTile]
        .any((k) => k.currentContext?.mounted ?? false);
    final targets = s.step.pickTargets?.call(ref.read(currentToolProvider).name, listOpen) ?? s.step.targets;
    for (final key in targets) {
      final ctx = key.currentContext;
      // 下に隠れた画面の部品は囲まない（地図の上に設定を開いたときなど。地図は裏で生きている）
      if (ctx == null || !(ModalRoute.of(ctx)?.isCurrent ?? true)) continue;
      final box = ctx.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        return box.localToGlobal(Offset.zero, ancestor: me) & box.size;
      }
    }
    return null;
  }

  void _tick() {
    final s = ref.read(tutorialProvider);
    if (!mounted || s == null) return;
    final r = _measure(s);
    if (r == _target) return;
    final prev = _shown();
    // 離れた場所へ移るときだけ動かす（一覧の開閉に合わせた数ピクセルのずれは追いかけるだけ）
    if (prev != null && r != null && (prev.center - r.center).distance > 24) {
      _from = prev;
      _move.forward(from: 0);
    } else {
      _from = null;
    }
    setState(() => _target = r);
  }

  /// 章に入るときの下ごしらえ
  void _prepare(TutorialChapter c) {
    if (c != TutorialChapter.gps) return;
    // GPS の章は「測点に書き込む」前提で始める（レイヤの選び方は「記録する」で教える）
    final tree = ref.read(folderTreeProvider);
    final points = tree?.getVisibleLayerNodes().whereType<LayerNode>()
        .where((l) => isPracticeLayer(l, PracticeProject.pointsLayer)).firstOrNull;
    if (points != null) ref.read(selectedLayerNodeProvider.notifier).select(points);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pulse.dispose();
    _move.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tutorial = ref.read(tutorialProvider.notifier);
    ref.listen(currentToolProvider, (_, tool) => tutorial.report(ToolChosen(tool.name)));
    ref.listen(selectedLayerNodeProvider, (_, layer) => tutorial.report(LayerSelected(layer)));
    ref.listen(selectedFeaturesProvider, (_, nodes) {
      // 持ち主はフィーチャの親から取る（選択中レイヤはこのあとで切り替わる）
      final parent = nodes.whereType<FeatureNode>().firstOrNull?.parent;
      if (parent is LayerNode) tutorial.report(FeatureSelected(parent));
    });
    ref.listen(tutorialProvider, (prev, s) {
      if (s != null && !s.menu && (prev == null || prev.menu || prev.chapter != s.chapter)) _prepare(s.chapter);
    });

    final s = ref.watch(tutorialProvider);
    if (s == null) {
      _poll?.cancel();
      _poll = null;
    } else {
      _poll ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
      WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
    }

    // キーボードが出ている間（名前の入力など）は札も枠も引っ込める。入力欄やダイアログを隠さないように
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    // 済んだ手順は囲まない（「次へ」を見てもらう）
    final target = s == null || s.menu || s.satisfied || typing ? null : _target;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    // 上に出すときはアプリバーの下（アプリバーのボタンを案内することがあるので隠さない）
    final topY = pad.top + kToolbarHeight + 8;
    // 札は案内先と反対の側に置く
    if (target != null && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (target == null && _pulse.isAnimating) {
      _pulse.stop();
    }
    final cardAtTop = s != null && !s.menu && (s.step.cardTop || (target != null && target.center.dy > size.height / 2));

    return Stack(
      children: [
        widget.child,
        if (target != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _RingPainter(() => (_shown() ?? target).inflate(5), _ringColor, _pulse, _move)),
            ),
          ),
        if (s != null && !typing)
          Positioned(
            // 上に出すときは左右の道具の列（幅 44）を空ける
            left: cardAtTop ? 52 : 12,
            right: cardAtTop ? 52 : 12,
            top: cardAtTop ? topY : null,
            bottom: cardAtTop ? null : pad.bottom + 20 + (s.menu ? 0 : s.step.cardLift),
            child: s.menu ? _MenuCard(state: s) : _StepCard(state: s),
          ),
      ],
    );
  }
}

String _chapterName(TutorialChapter c) => t.tutorial.chapters[c.name] ?? c.name;

class _StepCard extends ConsumerWidget {
  const _StepCard({required this.state});
  final TutorialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tutorial = ref.read(tutorialProvider.notifier);
    final key = '${state.chapter.name}_${state.step.id}';
    final title = t.tutorial.text['${key}_t'] ?? key;
    final body = t.tutorial.text['${key}_b'] ?? '';
    final theme = Theme.of(context);
    return _CardFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_chapterName(state.chapter)}  ${state.index + 1} / ${state.stepCount}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
          Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(body, style: theme.textTheme.bodyMedium),
          if (state.satisfied) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.check_circle, size: 18, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(child: Text(t.tutorial.doneHint, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.green[800]))),
              ],
            ),
          ],
          Row(
            children: [
              TextButton(onPressed: tutorial.showMenu, child: Text(t.tutorial.menuTitle)),
              const Spacer(),
              // 操作の手順は、済むまでは控えめな「とばす」（屋内で GPS が取れない・写真が無いなど）。
              // 済んだら「次へ」に替わる
              if (state.step.isInfo || state.satisfied)
                FilledButton(onPressed: tutorial.next, child: Text(t.tutorial.next))
              else
                TextButton(
                  onPressed: tutorial.next,
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.outline),
                  child: Text(t.tutorial.skip),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MenuCard extends ConsumerWidget {
  const _MenuCard({required this.state});
  final TutorialState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tutorial = ref.read(tutorialProvider.notifier);
    final theme = Theme.of(context);
    const chapters = TutorialChapter.values;
    final nextIndex = state.chapter.index + 1;
    final next = state.justFinished && nextIndex < chapters.length ? chapters[nextIndex] : null;
    return _CardFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            state.justFinished ? t.tutorial.chapterDone(name: _chapterName(state.chapter)) : t.tutorial.menuTitle,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (!state.justFinished) Text(t.tutorial.menuBody, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          for (final c in chapters)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              leading: Icon(
                state.finished.contains(c) ? Icons.check_circle : Icons.circle_outlined,
                color: state.finished.contains(c) ? Colors.green : theme.colorScheme.outline,
              ),
              title: Text('${c.index + 1}. ${_chapterName(c)}',
                  style: TextStyle(fontWeight: c == next ? FontWeight.bold : null)),
              subtitle: Text(t.tutorial.chapterHints[c.name] ?? ''),
              onTap: () => tutorial.openChapter(c),
            ),
          Row(
            children: [
              TextButton(onPressed: tutorial.stop, child: Text(t.tutorial.finish)),
              const Spacer(),
              if (next != null)
                FilledButton(onPressed: () => tutorial.openChapter(next), child: Text(t.tutorial.continueTo)),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surface,
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 4), child: child),
      );
}

/// 案内先を囲む枠と、外へ広がって薄れるハロー
class _RingPainter extends CustomPainter {
  _RingPainter(this.hole, this.color, this.pulse, Animation<double> move)
      : super(repaint: Listenable.merge([pulse, move]));
  final Rect Function() hole;
  final Color color;
  final Animation<double> pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(hole(), const Radius.circular(10));
    final p = Curves.easeOut.transform(pulse.value);
    canvas.drawRRect(r.inflate(3 + 9 * p), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = color.withValues(alpha: 0.35 * (1 - p)));
    canvas.drawRRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}
