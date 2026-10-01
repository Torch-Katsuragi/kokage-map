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
// 動きは付けない。案内先の位置は案内中だけ一定間隔で測り直す（一覧の開閉などで動くため）。

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

class _TutorialOverlayState extends ConsumerState<TutorialOverlay> {
  Rect? _target;
  Timer? _poll;

  // ── 指の動き（地図を動かす・拡大）。地図の動きは読み込み時の位置合わせでも起きるので指で見る ──
  final _pointers = <int, Offset>{};
  double _dragged = 0;
  double? _spreadAtStart;

  bool _isStep(String id) {
    final s = ref.read(tutorialProvider);
    return s != null && !s.menu && s.chapter == TutorialChapter.view && s.step.id == id;
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    _spreadAtStart = _pointers.length == 2 ? _spread() : null;
  }

  void _onUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    _spreadAtStart = null;
  }

  double _spread() {
    final v = _pointers.values.toList();
    return (v[0] - v[1]).distance;
  }

  void _onMove(PointerMoveEvent e) {
    _pointers[e.pointer] = e.position;
    final tutorial = ref.read(tutorialProvider.notifier);
    if (_pointers.length == 1 && _isStep('move')) {
      _dragged += e.delta.distance;
      if (_dragged > 150) tutorial.report(const CameraMoved());
    }
    final start = _spreadAtStart;
    if (_pointers.length == 2 && start != null && _isStep('zoom') && (_spread() - start).abs() > 60) {
      tutorial.report(const Pinched());
    }
  }

  // ── 案内先 ──

  Rect? _measure(TutorialState s) {
    if (s.menu) return null;
    final me = context.findRenderObject();
    if (me is! RenderBox) return null;
    for (final key in s.step.targets) {
      final box = key.currentContext?.findRenderObject();
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
    if (r != _target) setState(() => _target = r);
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
      _dragged = 0;
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
    final target = s == null || s.menu || typing ? null : _target;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    // 上に出すときはアプリバーの下（アプリバーのボタンを案内することがあるので隠さない）
    final topY = pad.top + kToolbarHeight + 8;
    // 札は案内先と反対の側に置く
    final cardAtTop = s != null && !s.menu && (s.step.cardTop || (target != null && target.center.dy > size.height / 2));

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: Stack(
        children: [
          widget.child,
          if (target != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _RingPainter(target.inflate(5), Theme.of(context).colorScheme.primary)),
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
      ),
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
          Row(
            children: [
              TextButton(onPressed: tutorial.showMenu, child: Text(t.tutorial.menuTitle)),
              const Spacer(),
              // 操作の手順も飛ばせる（屋内で GPS が取れない・写真が無いなど）
              if (state.step.isInfo)
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

/// 案内先を囲む枠（太い線と外側の淡い帯）
class _RingPainter extends CustomPainter {
  _RingPainter(this.hole, this.color);
  final Rect hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(hole, const Radius.circular(10));
    canvas.drawRRect(r.inflate(4), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = color.withValues(alpha: 0.25));
    canvas.drawRRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.hole != hole || old.color != color;
}
