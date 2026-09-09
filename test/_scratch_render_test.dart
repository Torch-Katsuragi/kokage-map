import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_world_painter.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

const out = r'C:\Users\mtmtk\AppData\Local\Temp\claude\G---------matsumoto-personal\63f2a25d-e663-43fc-a6ce-d6f2b7a24a6e\scratchpad';

void main() {
  testWidgets('render real dem', (tester) async {
    final bytes = File('$out/dem_13.f32').readAsBytesSync();
    final heights = Float32List.view(bytes.buffer, bytes.offsetInBytes, 256 * 256);
    final mpp = WebMercator.metersPerPixel(13);
    final dem = DemGrid(cols: 256, rows: 256, originX: 0, originY: 0, cellSize: mpp, heights: heights);
    final span = 256 * mpp;
    final cases = <(String, double, double, int, double)>[
      ('p45_b0_s2', 45, 0, 2, span * 0.03),
      ('p60_b0_s2', 60, 0, 2, span * 0.03),
      ('p45_b30_s2', 45, 30, 2, span * 0.03),
      ('p45_b0_s1', 45, 0, 1, span * 0.03),
      ('p45_b0_s2_noskirt', 45, 0, 2, 0),
      ('p45_b200_s2', 45, 200, 2, span * 0.03),
    ];
    for (final (name, pitchDeg, bearingDeg, step, skirt) in cases) {
      final camera = TerrainCamera(
        centerX: span / 2,
        centerY: span / 2,
        scale: 1080 / span * 0.9,
        bearing: bearingDeg * math.pi / 180,
        pitch: pitchDeg * math.pi / 180,
        zScale: 1.2,
      );
      final builder = TerrainMeshBuilder(dem, textureWidth: 512, textureHeight: 512, chunkSize: 32, step: step, skirtDepth: skirt);
      final mesh = builder.build(camera);
      final painter = TerrainWorldPainter(
        camera: camera,
        tiles: [TerrainTileDrawable(originX: 0, originY: 0, mesh: mesh, texture: null)],
        elevationAt: (x, y) => dem.elevationAt(x, y),
        heightRange: dem.heightRange,
        stepMeters: mpp,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(width: 540, height: 1000, child: ColoredBox(color: const Color(0xFFE6E6E6), child: CustomPaint(painter: painter))),
          ),
        ),
      );
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await boundary.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$out/render_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  });
}
