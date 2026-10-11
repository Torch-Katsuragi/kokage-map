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
// こかげマップ: 計測ツールの線・点（地図の上に描く）と、値のパネル
//
// 線は地図の場面に焼かず、カメラが動くたびに描き直す（編集の重ね絵と同じ）。3D では地形の高さで持ち上げた位置に出る

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../../i18n/strings.g.dart';
import '../../../tools/measure_tool.dart';
import '../../../utils/geodesic.dart';

const _ink = Color(0xFFFF6F00);

final _linePaint = Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = 3
  ..strokeJoin = StrokeJoin.round
  ..color = _ink;
final _fillPaint = Paint()..color = _ink.withValues(alpha: 0.18);
final _dotPaint = Paint()..color = Colors.white;
final _dotRimPaint = Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = 2.5
  ..color = _ink;

/// 計測の線と点
class MeasureOverlay extends StatelessWidget {
  const MeasureOverlay({super.key, required this.session, required this.project, required this.cameraTick});

  final MeasureSession session;

  /// 緯度経度 → 画面（地図の状態の latLngToOffset）
  final Offset Function(LatLng) project;
  final Listenable cameraTick;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _MeasurePainter(session, project, Listenable.merge([session, cameraTick])),
      size: Size.infinite,
    ),
  );
}

class _MeasurePainter extends CustomPainter {
  _MeasurePainter(this.session, this.project, Listenable repaint) : super(repaint: repaint);

  final MeasureSession session;
  final Offset Function(LatLng) project;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = session.points;
    if (pts.isEmpty) return;
    final px = [for (final p in pts) project(p)];
    final area = session.isArea;
    if (px.length > 1) {
      final path = Path()..addPolygon(px, area);
      if (area) canvas.drawPath(path, _fillPaint);
      canvas.drawPath(path, _linePaint);
    }
    // 区間の長さを辺の中ほどに
    final segs = session.segments;
    for (var i = 0; i < segs.length; i++) {
      final a = px[i];
      final b = px[(i + 1) % px.length];
      _label(canvas, (a + b) / 2, Geodesic.formatLengthShort(segs[i]));
    }
    for (var i = 0; i < px.length; i++) {
      final r = i == 0 ? 7.0 : 5.5; // 始点は大きく（叩くと面になる）
      canvas.drawCircle(px[i], r, _dotPaint);
      canvas.drawCircle(px[i], r, _dotRimPaint);
    }
  }

  void _label(Canvas canvas, Offset at, String text) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(center: at, width: tp.width + 8, height: tp.height + 4);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), Paint()..color = Colors.black.withValues(alpha: 0.6));
    tp.paint(canvas, rect.topLeft + const Offset(4, 2));
  }

  @override
  bool shouldRepaint(_MeasurePainter old) => !identical(old.session, session) || !identical(old.project, project);
}

/// 計測の値（区間・合計、面なら周長と面積）と、1 点戻す・消す
class MeasurePanel extends StatelessWidget {
  const MeasurePanel({super.key, required this.session});

  final MeasureSession session;

  @override
  Widget build(BuildContext context) {
    final tr = t.map.measure;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final segs = session.segments;
        final area = session.area;
        Widget row(String label, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 56, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54))),
              Expanded(
                child: Text(value, style: TextStyle(fontSize: bold ? 14 : 12, fontWeight: bold ? FontWeight.bold : null)),
              ),
            ],
          ),
        );
        return Card(
          elevation: 4,
          margin: EdgeInsets.zero,
          child: Container(
            width: 230,
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.straighten, size: 16, color: _ink),
                    const SizedBox(width: 4),
                    Expanded(child: Text(tr.title, style: const TextStyle(fontWeight: FontWeight.bold))),
                    IconButton(
                      icon: const Icon(Icons.undo, size: 20),
                      tooltip: tr.undo,
                      visualDensity: VisualDensity.compact,
                      onPressed: session.isEmpty ? null : session.undo,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: tr.clear,
                      visualDensity: VisualDensity.compact,
                      onPressed: session.isEmpty ? null : session.clear,
                    ),
                  ],
                ),
                if (session.points.length < 2)
                  Text(tr.hint, style: const TextStyle(fontSize: 12, color: Colors.black54))
                else ...[
                  // 区間が多いときは最後の数本だけ（パネルを地図の邪魔にしない）
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Column(
                        children: [for (var i = 0; i < segs.length; i++) row(tr.segment(i: i + 1), Geodesic.formatLength(segs[i]))],
                      ),
                    ),
                  ),
                  const Divider(height: 8),
                  if (area == null)
                    row(tr.total, Geodesic.formatLength(session.total), bold: true)
                  else ...[
                    row(tr.area, Geodesic.formatArea(area), bold: true),
                    row(tr.perimeter, Geodesic.formatLength(session.total)),
                  ],
                  if (area == null && session.points.length >= 3)
                    Text(tr.closeHint, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
