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
// 編集中の形と取っ手を地図の上に描く（地図の場面には焼かない。頂点を動かすたびに描き直すため）。
// 元の地物は地図から隠し、ここで写しを描く。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' hide Path;

import 'edit_session.dart';

const _red = Color(0xFFD32F2F);

class EditOverlay extends ConsumerWidget {
  const EditOverlay({super.key, required this.project, required this.cameraTick});

  /// 緯度経度 → 画面（地図の状態の latLngToOffset）
  final Offset Function(LatLng) project;
  final Listenable cameraTick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(featureEditorProvider);
    if (s == null) return const SizedBox.shrink();
    return IgnorePointer(child: CustomPaint(painter: _EditPainter(s, project, cameraTick), size: Size.infinite));
  }
}

class _EditPainter extends CustomPainter {
  _EditPainter(this.s, this.project, Listenable repaint) : super(repaint: repaint);

  final EditState s;
  final Offset Function(LatLng) project;

  @override
  void paint(Canvas canvas, Size size) {
    final rings = [for (final r in s.geom) [for (final p in r) project(p)]];
    final closed = s.kind == EditKind.polygon;

    // 形
    if (s.kind != EditKind.point) {
      final path = Path()..fillType = PathFillType.evenOdd;
      for (final r in rings) {
        if (r.length > 1) path.addPolygon(r, closed);
      }
      if (closed) canvas.drawPath(path, Paint()..color = _red.withValues(alpha: 0.18));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..color = _red,
      );
    }

    // 辺の中点（頂点を足すところ）
    if (s.mode == EditMode.vertex) {
      // 線の上でも見えるように白地に赤の縁（頂点より小さく）
      final fill = Paint()..color = Colors.white.withValues(alpha: 0.9);
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _red;
      for (final r in rings) {
        final edges = closed ? r.length : r.length - 1;
        for (var i = 0; i < edges; i++) {
          final c = (r[i] + r[(i + 1) % r.length]) / 2;
          canvas.drawCircle(c, 4.5, fill);
          canvas.drawCircle(c, 4.5, rim);
        }
      }
    }

    // 頂点
    // 間引く・切り落とすでも頂点を出す（どれが残るかを見るため）
    final showVertices = s.mode == EditMode.vertex ||
        s.mode == EditMode.extend ||
        s.mode == EditMode.simplify ||
        s.mode == EditMode.trim ||
        s.kind == EditKind.point;
    if (showVertices) {
      for (var ri = 0; ri < rings.length; ri++) {
        for (var i = 0; i < rings[ri].length; i++) {
          final sel = s.selected == (ri, i);
          // 延ばす道具では端点だけ大きく（そこから続く）
          final end = s.mode == EditMode.extend && (i == 0 || i == rings[ri].length - 1);
          final radius = sel ? 10.0 : (end ? 8.0 : 6.5);
          canvas.drawCircle(rings[ri][i], radius, Paint()..color = sel ? _red : Colors.white);
          canvas.drawCircle(
            rings[ri][i],
            radius,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5
              ..color = _red,
          );
        }
      }
    }

    // 回す・大きさを変えるときは重心に印
    if (s.mode == EditMode.rotate || s.mode == EditMode.scale) {
      final c = project(centroidOf(s.geom));
      final p = Paint()
        ..strokeWidth = 2
        ..color = _red;
      canvas.drawLine(c - const Offset(10, 0), c + const Offset(10, 0), p);
      canvas.drawLine(c - const Offset(0, 10), c + const Offset(0, 10), p);
      canvas.drawCircle(c, 14, p..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(_EditPainter old) => !identical(old.s, s);
}
