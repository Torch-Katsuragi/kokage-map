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
// 情報パネルの背景に、選んだ地物の形を薄く敷く（松本 2026-10-01「背景が白なの勿体無い」）。
//
// 線と面は形がひと目で分かるように、パネルいっぱいに縮尺を合わせて描く（向きは北が上）。
// 点は形が無いので「POINT」の文字を薄く出す。文字や数値の邪魔にならない濃さに抑える。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../models/nodes/feature_node.dart';
import '../models/nodes/image_node.dart';

class FeatureSilhouette extends StatelessWidget {
  const FeatureSilhouette({super.key, required this.feature}) : parts = null, closed = false;

  /// 形を直接渡す（編集中の写しを、直すたびに描き直すため）。parts が 1 点だけなら点として扱う
  const FeatureSilhouette.shape({super.key, required List<List<LatLng>> this.parts, required this.closed})
      : feature = null;

  final Object? feature;
  final List<List<LatLng>>? parts;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final f = feature;
    final color = Theme.of(context).colorScheme.primary;
    final given = this.parts;
    if (given != null) {
      if (given.length == 1 && given.first.length == 1) return _point(color);
      if (given.every((p) => p.length < 2)) return const SizedBox.shrink();
      return IgnorePointer(child: CustomPaint(painter: _ShapePainter(given, this.closed, color)));
    }
    if (f is PointFeatureNode) return _point(color);
    // 写真は写真そのものを薄く敷く
    if (f is ImageNode && !kIsWeb) {
      return IgnorePointer(
        child: Opacity(
          opacity: 0.22,
          child: Image.file(File(f.filePath), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
        ),
      );
    }
    final List<List<LatLng>> parts;
    final bool closed;
    if (f is LineFeatureNode) {
      parts = [f.line];
      closed = false;
    } else if (f is PolygonFeatureNode) {
      parts = f.polygon;
      closed = true;
    } else {
      return const SizedBox.shrink();
    }
    if (parts.every((p) => p.length < 2)) return const SizedBox.shrink();
    return IgnorePointer(child: CustomPaint(painter: _ShapePainter(parts, closed, color)));
  }

  Widget _point(Color color) => IgnorePointer(
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              'POINT',
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w900,
                letterSpacing: 4,
                color: color.withValues(alpha: 0.07),
              ),
            ),
          ),
        ),
      );
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.parts, this.closed, this.color);

  final List<List<LatLng>> parts;
  final bool closed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 経度は緯度で縮めて、形が横に伸びないように（狭い範囲なので平面で足りる）
    final all = parts.expand((p) => p).toList();
    final midLat = all.map((p) => p.latitude).reduce((a, b) => a + b) / all.length;
    final k = math.cos(midLat * math.pi / 180);
    Offset xy(LatLng p) => Offset(p.longitude * k, -p.latitude);
    final pts = all.map(xy).toList();
    final minX = pts.map((p) => p.dx).reduce(math.min);
    final maxX = pts.map((p) => p.dx).reduce(math.max);
    final minY = pts.map((p) => p.dy).reduce(math.min);
    final maxY = pts.map((p) => p.dy).reduce(math.max);
    final w = math.max(maxX - minX, 1e-12);
    final h = math.max(maxY - minY, 1e-12);

    const pad = 20.0;
    final avail = Size(math.max(size.width - pad * 2, 1), math.max(size.height - pad * 2, 1));
    final scale = math.min(avail.width / w, avail.height / h);
    final dx = pad + (avail.width - w * scale) / 2;
    final dy = pad + (avail.height - h * scale) / 2;
    Offset toCanvas(LatLng p) {
      final q = xy(p);
      return Offset(dx + (q.dx - minX) * scale, dy + (q.dy - minY) * scale);
    }

    final path = Path()..fillType = PathFillType.evenOdd;
    for (final part in parts) {
      if (part.length < 2) continue;
      path.addPolygon(part.map(toCanvas).toList(), closed);
    }
    if (closed) canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = closed ? 2 : 4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: closed ? 0.22 : 0.20),
    );
  }

  @override
  bool shouldRepaint(_ShapePainter old) => old.parts != parts || old.color != color;
}
