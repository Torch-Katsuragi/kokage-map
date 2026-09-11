// 透視（眺め）モードのカメラ: 投影と視線の幾何
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';

void main() {
  TerrainCamera cam({double bearing = 0, double pitch = 0.6}) => TerrainCamera(
        centerX: 0,
        centerY: 0,
        scale: 0.5,
        bearing: bearing,
        pitch: pitch,
        zScale: 1.2,
      )
        ..perspective = true
        ..viewport = const Size(400, 800);

  test('画面中心（高さ centerHeight）は画面の中心に落ちる', () {
    final c = cam();
    final p = c.projectPerspective(0, 0, 100, 100)!;
    expect(p.dx, closeTo(200, 1e-3));
    expect(p.dy, closeTo(200 * 2, 1e-3));
  });

  test('真上・北上: 北は画面の上、東は右。中心付近の倍率は正射影と同じ', () {
    final c = cam(pitch: 0);
    final north = c.projectPerspective(0, 10, 0, 0)!;
    final east = c.projectPerspective(10, 0, 0, 0)!;
    expect(north.dy, lessThan(400));
    expect((north.dx - 200).abs(), lessThan(1e-3));
    expect(east.dx, greaterThan(200));
    // 10 m × 0.5 px/m = 5 px（中心近傍では透視も正射影とほぼ一致）
    expect(east.dx - 200, closeTo(5, 0.05));
  });

  test('方位 90°（東を上に）: 東が画面の上に来る', () {
    final c = cam(bearing: math.pi / 2, pitch: 0);
    final east = c.projectPerspective(10, 0, 0, 0)!;
    expect(east.dy, lessThan(400));
    expect((east.dx - 200).abs(), lessThan(1e-3));
  });

  test('傾けると奥（画面の上）ほど小さく、視点の裏側は null', () {
    final c = cam(pitch: 1.0);
    final near = c.projectPerspective(0, -100, 0, 0)!; // 手前
    final far = c.projectPerspective(0, 100, 0, 0)!; // 奥
    final nearStep = (c.projectPerspective(10, -100, 0, 0)!.dx - near.dx).abs();
    final farStep = (c.projectPerspective(10, 100, 0, 0)!.dx - far.dx).abs();
    expect(farStep, lessThan(nearStep));
    // 視点の真後ろ
    final eye = c.eyeAt(0);
    expect(c.projectPerspective(eye.x * 2, eye.y * 2, eye.z / c.zScale * 2, 0), isNull);
  });

  test('視線と平らな地形の交点を投影し直すと元の画面座標に戻る', () {
    final c = cam(pitch: 0.7, bearing: 0.4);
    const screen = Offset(120, 500);
    final hit = c.intersectRayPerspective(screen, 100, (x, y) => 100, stepMeters: 2, maxHeight: 200)!;
    final back = c.projectPerspective(hit.dx, hit.dy, 100, 100)!;
    expect(back.dx, closeTo(screen.dx, 1.5));
    expect(back.dy, closeTo(screen.dy, 1.5));
  });

  test('地平線の上を向く視線は交点なし、地面の点は maxDistance で打ち切られる', () {
    final c = cam(pitch: 1.2); // 69°。画面上端の視線は 94° → 地平線の上
    expect(c.intersectRayPerspective(const Offset(200, 0), 0, (x, y) => 0, stepMeters: 5, maxHeight: 100), isNull);
    // 視点は中心の 1.7km 後ろ・615m 上（scale 0.5 px/m・画面高 800 px・fov 50°）。画面下端の視線は 44° で
    // 中心の 1km ほど手前の地面に当たる。上端は地平線の上なので maxDistance に打ち切られる
    final p = c.groundPointPerspective(const Offset(200, 0), 0, 0, maxDistance: 3000);
    expect(p.distance, closeTo(3000, 1));
    final q = c.groundPointPerspective(const Offset(200, 800), 0, 0, maxDistance: 3000);
    expect(q.distance, lessThan(3000));
    expect(q.dy, lessThan(0)); // 手前（南）側
  });
}
