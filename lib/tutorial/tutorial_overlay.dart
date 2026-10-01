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
// チュートリアルの重ね絵: 案内先を枠で囲み、説明の札を出す。
//
// 押すのは本物の部品なので、札以外は触れる（IgnorePointer）。
// 動きは付けない。案内先の位置は描き終わるたびに測り直す（レイヤ一覧が開くと動くため）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.g.dart';
import '../providers/selection_providers.dart';
import '../providers/tool_providers.dart';
import 'tutorial.dart';

class TutorialOverlay extends ConsumerStatefulWidget {
  const TutorialOverlay({super.key});

  @override
  ConsumerState<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends ConsumerState<TutorialOverlay> {
  Rect? _target;

  // 「地図を動かす」: 指の動いた量で見る（地図の動きは読み込み時の位置合わせでも起きるので使えない）
  double _dragged = 0;

  void _onPointerMove(PointerMoveEvent e) {
    if (ref.read(tutorialProvider) != TutorialStep.move) return;
    _dragged += e.delta.distance;
    if (_dragged > 150) ref.read(tutorialProvider.notifier).report(const CameraMoved());
  }

  Rect? _measure(TutorialStep step) {
    final ctx = TutorialTargets.of(step)?.currentContext;
    final box = ctx?.findRenderObject();
    final me = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached || me is! RenderBox) return null;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: me);
    return topLeft & box.size;
  }

  // 案内先は重ね絵の外で組まれ、出るのも動くのも重ね絵の描き直しと関係ない（一覧の読み込み・開閉）。
  // なので案内中だけ一定間隔で測る。変わらなければ何もしない
  Timer? _poll;

  void _tick() {
    final step = ref.read(tutorialProvider);
    if (!mounted || step == null) return;
    final r = _measure(step);
    if (r != _target) setState(() => _target = r);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentToolProvider, (_, tool) => ref.read(tutorialProvider.notifier).report(ToolChosen(tool.name)));
    ref.listen(selectedLayerNodeProvider, (_, layer) => ref.read(tutorialProvider.notifier).report(LayerSelected(layer)));
    ref.listen(tutorialProvider, (_, _) => _dragged = 0);
    final step = ref.watch(tutorialProvider);
    if (step == null) {
      _poll?.cancel();
      _poll = null;
      return const SizedBox.shrink();
    }
    _poll ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());

    final wantsTarget = TutorialTargets.of(step) != null;
    final target = wantsTarget ? _target : null;
    final size = MediaQuery.sizeOf(context);
    // 札は案内先と反対の側に置く
    final cardAtTop = target != null && target.center.dy > size.height / 2;

    return Stack(
      children: [
        // 指の動きだけ覗く（translucent なので下の地図にもそのまま届く）
        Positioned.fill(
          child: Listener(behavior: HitTestBehavior.translucent, onPointerMove: _onPointerMove),
        ),
        if (target != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _SpotPainter(target.inflate(6), Theme.of(context).colorScheme.primary)),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          top: cardAtTop ? MediaQuery.paddingOf(context).top + 12 : null,
          bottom: cardAtTop ? null : MediaQuery.paddingOf(context).bottom + 24,
          child: SafeArea(top: false, bottom: false, child: _Card(step: step)),
        ),
      ],
    );
  }
}

class _Card extends ConsumerWidget {
  const _Card({required this.step});
  final TutorialStep step;

  (String, String) _text() {
    final s = t.tutorial.steps;
    return switch (step) {
      TutorialStep.move => (s.move.title, s.move.body),
      TutorialStep.openLayers => (s.openLayers.title, s.openLayers.body),
      TutorialStep.hideStands => (s.hideStands.title, s.hideStands.body),
      TutorialStep.showStands => (s.showStands.title, s.showStands.body),
      TutorialStep.pickPoints => (s.pickPoints.title, s.pickPoints.body),
      TutorialStep.closeLayers => (s.closeLayers.title, s.closeLayers.body),
      TutorialStep.pen => (s.pen.title, s.pen.body),
      TutorialStep.placePoint => (s.placePoint.title, s.placePoint.body),
      TutorialStep.done => (s.done.title, s.done.body),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (title, body) = _text();
    final tutorial = ref.read(tutorialProvider.notifier);
    final total = TutorialStep.values.length - 1;
    final theme = Theme.of(context);
    final done = step == TutorialStep.done;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!done)
              Text('${step.index + 1} / $total',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(body, style: theme.textTheme.bodyMedium),
            Row(
              children: [
                if (!done) TextButton(onPressed: tutorial.stop, child: Text(t.tutorial.quit)),
                const Spacer(),
                // 自分で操作しなくても先へ進めるのは「地図を動かす」だけ（動かしたかは判りにくいので）
                if (step == TutorialStep.move) TextButton(onPressed: tutorial.next, child: Text(t.tutorial.next)),
                if (done) FilledButton(onPressed: tutorial.stop, child: Text(t.tutorial.finish)),
                if (done) const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 案内先のまわりだけ明るく残し、枠で囲む
class _SpotPainter extends CustomPainter {
  _SpotPainter(this.hole, this.color);
  final Rect hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(hole, const Radius.circular(10));
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(r);
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawRRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color);
  }

  @override
  bool shouldRepaint(_SpotPainter old) => old.hole != hole || old.color != color;
}
