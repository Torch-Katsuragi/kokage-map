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
part of 'terrain_map_layer.dart';

/// ドライブモード（debug のみ）: 台本でカメラを動かし、被覆率・フレーム時間・停止を `[3D] drive` ログに出す
///
/// ズームボタン列の 🛣 で開始／停止。`.temp/` の `stack.dart`（VM サービスで main isolate のスタック）と組で使う。
/// 判定の規則はシミュレーション（`test/terrain_world_sim_test.dart`）と同じ `TerrainFramePlan.coverage`
mixin _TerrainDrive on State<TerrainMapLayer> {
  TerrainCamera get _camera;
  TerrainWorld get _world;
  TerrainFramePlan? get _lastPlan;
  int get _placeholders;
  set _gesturing(bool v);
  void _refresh();

  Ticker? _drive;
  Timer? _stallProbe;
  (double, double, double, double) _driveOrigin = (0, 0, 0, 0); // centerX, centerY, zoom, bearing
  Duration _driveStart = Duration.zero;
  Duration _driveLastLog = Duration.zero;
  final List<int> _driveUiMs = [];
  final List<int> _driveRasterMs = [];
  int _driveGapFrames = 0;
  int _driveFrames = 0;
  TimingsCallback? _driveTimings;

  /// 台本: 0〜8s 東へ 3km、8〜16s 引き 4 段、16〜24s 寄り 5 段、24〜32s 一回転、32〜40s 傾け往復、40〜48s 西へ 3km
  void _startDrive() {
    if (kReleaseMode || _drive != null) return;
    _driveOrigin = (_camera.centerX, _camera.centerY, _camera.zoom, _camera.bearing);
    _driveGapFrames = 0;
    _driveFrames = 0;
    _driveUiMs.clear();
    _driveRasterMs.clear();
    _driveTimings = (timings) {
      for (final t in timings) {
        _driveUiMs.add(t.buildDuration.inMilliseconds);
        _driveRasterMs.add(t.rasterDuration.inMilliseconds);
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_driveTimings!);
    var last = DateTime.now();
    _stallProbe = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      final gap = now.difference(last).inMilliseconds;
      if (gap > 400) AppLogger.debug('[3D] stall ${gap}ms (isolate blocked)');
      last = now;
    });
    _drive = Ticker((elapsed) {
      try {
        _driveTick(elapsed);
      } catch (e, st) {
        AppLogger.error('[3D] drive error', e, st);
        _stopDrive();
      }
    })
      ..start();
  }

  void _driveTick(Duration elapsed) {
    final (startX, startY, startZoom, startBearing) = _driveOrigin;
    {
      if (_driveStart == Duration.zero) _driveStart = elapsed;
      final t = (elapsed - _driveStart).inMilliseconds / 1000;
      if (t > 48) {
        _stopDrive();
        return;
      }
      if (t < 8) {
        _camera.centerX = startX + 3000 * (t / 8);
      } else if (t < 16) {
        _camera.zoom = startZoom - 4 * ((t - 8) / 8);
      } else if (t < 24) {
        _camera.zoom = startZoom - 4 + 5 * ((t - 16) / 8);
      } else if (t < 32) {
        _camera.bearing = startBearing + 2 * math.pi * ((t - 24) / 8);
      } else if (t < 40) {
        _camera.pitch = (35 + 35 * math.sin((t - 32) / 8 * 2 * math.pi)) * math.pi / 180;
      } else {
        _camera.centerX = startX + 3000 - 3000 * ((t - 40) / 8);
        _camera.centerY = startY;
      }
      _gesturing = t >= 24 && t < 40;
      _refresh();
      _driveFrames++;
      final plan = _lastPlan;
      if (plan != null && !plan.coverage.full) _driveGapFrames++;
      if (elapsed - _driveLastLog >= const Duration(milliseconds: 500)) {
        _driveLastLog = elapsed;
        String stat(List<int> v) {
          if (v.isEmpty) return '-';
          final s = [...v]..sort();
          return '${s[s.length ~/ 2]}/${s.last}';
        }
        AppLogger.debug('[3D] drive t=${t.toStringAsFixed(1)}s z=${_camera.zoom.toStringAsFixed(2)} '
            'dem=${plan?.demZoom} ${plan?.coverage} tiles=${_world.loadedCount} pending=${_world.pendingCount} '
            'ui=${stat(_driveUiMs)} raster=${stat(_driveRasterMs)} placeholders=$_placeholders gapFrames=$_driveGapFrames/$_driveFrames');
        _driveUiMs.clear();
        _driveRasterMs.clear();
      }
    }
  }

  void _stopDrive() {
    final d = _drive;
    if (d == null) return;
    d.dispose();
    _drive = null;
    _stallProbe?.cancel();
    _stallProbe = null;
    _driveStart = Duration.zero;
    if (_driveTimings != null) SchedulerBinding.instance.removeTimingsCallback(_driveTimings!);
    _driveTimings = null;
    _gesturing = false;
    AppLogger.debug('[3D] drive end: gapFrames=$_driveGapFrames/$_driveFrames tiles=${_world.loadedCount}');
    if (mounted) _refresh();
  }

}
