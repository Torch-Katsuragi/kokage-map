// 地図バックエンドのベンチマーク（Windows / Android 共通）
//
// 実行:
//   flutter test integration_test/benchmark/map_perf_test.dart -d windows
//   flutter test integration_test/benchmark/map_perf_test.dart -d <android device>
//
// 目的:
//   2026-04にWindows版を凍結した理由は「maplibre_webview のパフォーマンスが
//   要求水準に満たない」だった。その「要求水準」が数値で残っていないので、
//   ここで比較可能な数字を取る。Androidの maplibre_android を基準線として、
//   Windows側が何倍遅いかを見る。
//
//   合否は判定しない（アサーションを置かない）。数字を出すだけ。
//   `tool/test_matrix.ps1` のゲートには含めない（benchmark/ サブディレクトリに置いてある）。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:root_maps/core/r_map_controller.dart';
import 'package:root_maps/widgets/map/r_map_widget.dart';

import '../support/harness.dart';

const kCenter = LatLng(33.9707, 135.8534);
const kZoom = 14.0;
const kMapSize = Size(800, 600);

/// 計測結果。最後にまとめて表で出す。
final _report = <String, String>{};

void _record(String key, String value) => _report[key] = value;

/// 指定件数のポイントを持つGeoJSONを作る（森林簿のフィーチャ量を想定）
String _buildGeoJson(int count) {
  final buf = StringBuffer('{"type":"FeatureCollection","features":[');
  for (var i = 0; i < count; i++) {
    if (i > 0) buf.write(',');
    // 北山村付近に格子状にばら撒く
    final lon = 135.80 + (i % 100) * 0.001;
    final lat = 33.94 + (i ~/ 100) * 0.001;
    buf.write(
      '{"type":"Feature","properties":{"id":$i},'
      '"geometry":{"type":"Point","coordinates":[$lon,$lat]}}',
    );
  }
  buf.write(']}');
  return buf.toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('地図バックエンド性能 [$platformName]', () {
    late RMapController controller;
    late ml.StyleController style;

    /// 地図を描画し、スタイル読込までの時間を返す。
    Future<int> pumpMapMeasured(WidgetTester tester) async {
      var styleLoaded = false;
      final sw = Stopwatch()..start();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: kMapSize.width,
                height: kMapSize.height,
                child: RMapWidget(
                  options: ml.MapOptions(
                    initStyle: kEmptyMapStyle,
                    initCenter: ml.Geographic(
                      lon: kCenter.longitude,
                      lat: kCenter.latitude,
                    ),
                    initZoom: kZoom,
                  ),
                  onMapCreated: (c) => controller = c,
                  onStyleLoaded: (c, s) {
                    controller = c;
                    style = s;
                    styleLoaded = true;
                  },
                ),
              ),
            ),
          ),
        ),
      );

      await pumpUntil(
        tester,
        () => styleLoaded,
        timeout: const Duration(seconds: 60),
        step: const Duration(milliseconds: 16),
        reason: 'onStyleLoaded が発火しない',
      );
      sw.stop();
      return sw.elapsedMilliseconds;
    }

    testWidgets('起動: スタイル読込までの時間', (tester) async {
      final ms = await pumpMapMeasured(tester);
      _record('style_load', '${ms}ms');
    });

    testWidgets('カメラ: move() が反映されるまでの遅延', (tester) async {
      await pumpMapMeasured(tester);

      // 何度か測って中央値を取る（初回はウォームアップぶんが乗る）
      final samples = <int>[];
      for (var i = 0; i < 10; i++) {
        final targetZoom = 10.0 + i * 0.5;
        final sw = Stopwatch()..start();
        controller.move(kCenter, targetZoom);
        await pumpUntil(
          tester,
          () => (controller.camera.zoom - targetZoom).abs() < 0.01,
          timeout: const Duration(seconds: 10),
          step: const Duration(milliseconds: 4),
          reason: 'move() がカメラに反映されない',
        );
        sw.stop();
        samples.add(sw.elapsedMilliseconds);
      }
      samples.sort();
      _record('move_latency_median', '${samples[samples.length ~/ 2]}ms');
      _record('move_latency_max', '${samples.last}ms');
    });

    testWidgets('カメラ: animateTo() の完了と実際の着地のズレ', (tester) async {
      await pumpMapMeasured(tester);

      const target = LatLng(33.90, 135.80);
      const targetZoom = 11.0;
      var done = false;
      final sw = Stopwatch()..start();
      unawaited(controller
          .animateTo(center: target, zoom: targetZoom)
          .then((_) => done = true));

      // Future が完了するまで
      await pumpUntil(
        tester,
        () => done,
        timeout: const Duration(seconds: 15),
        step: const Duration(milliseconds: 4),
        reason: 'animateTo() の Future が完了しない',
      );
      final futureMs = sw.elapsedMilliseconds;
      final zoomAtFuture = controller.camera.zoom;

      // Future 完了後、実際にカメラが目標へ着地するまで
      var settledMs = -1;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if ((controller.camera.zoom - targetZoom).abs() < 0.05) {
          settledMs = sw.elapsedMilliseconds;
          break;
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      sw.stop();

      _record('animate_future_ms', '${futureMs}ms');
      _record('animate_zoom_at_future', zoomAtFuture.toStringAsFixed(2));
      _record(
        'animate_settle_ms',
        settledMs < 0 ? '着地せず(>10s)' : '${settledMs}ms',
      );
    });

    testWidgets('座標変換: toScreenLocation 1000回', (tester) async {
      await pumpMapMeasured(tester);

      // ペン描画中は1ストロークで数百回呼ぶ。ここが遅いと描画が破綻する。
      final sw = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        controller.toScreenLocation(
          LatLng(kCenter.latitude + i * 1e-5, kCenter.longitude + i * 1e-5),
        );
      }
      sw.stop();
      _record('project_1000', '${sw.elapsedMicroseconds ~/ 1000}ms');
      _record(
        'project_per_call',
        '${(sw.elapsedMicroseconds / 1000).toStringAsFixed(1)}us',
      );
    });

    testWidgets('描画: 1万フィーチャの追加', (tester) async {
      await pumpMapMeasured(tester);

      final geoJson = _buildGeoJson(10000);
      const sourceId = 'perf-src';
      const layerId = 'perf-layer';

      final sw = Stopwatch()..start();
      await style.addSource(ml.GeoJsonSource(id: sourceId, data: geoJson));
      await style.addLayer(
        const ml.CircleStyleLayer(id: layerId, sourceId: sourceId),
      );
      await tester.pump(const Duration(milliseconds: 16));
      sw.stop();
      _record('add_10k_features', '${sw.elapsedMilliseconds}ms');

      // 属性編集後の再描画にあたる操作
      final sw2 = Stopwatch()..start();
      await style.updateGeoJsonSource(id: sourceId, data: geoJson);
      await tester.pump(const Duration(milliseconds: 16));
      sw2.stop();
      _record('update_10k_features', '${sw2.elapsedMilliseconds}ms');
    });

    testWidgets('連続パン: 60回の move() スループット', (tester) async {
      await pumpMapMeasured(tester);

      // 指をドラッグしている間に相当する。1フレーム16.7msに収まるかを見る。
      final sw = Stopwatch()..start();
      for (var i = 0; i < 60; i++) {
        controller.move(
          LatLng(kCenter.latitude + i * 1e-4, kCenter.longitude + i * 1e-4),
          kZoom,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      sw.stop();
      _record('pan_60_frames', '${sw.elapsedMilliseconds}ms');
      _record(
        'pan_per_frame',
        '${(sw.elapsedMilliseconds / 60).toStringAsFixed(1)}ms',
      );
    });

    tearDownAll(() {
      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('===== 地図バックエンド性能 [$platformName] =====');
      for (final e in _report.entries) {
        // ignore: avoid_print
        print('${e.key.padRight(24)} ${e.value}');
      }
      // ignore: avoid_print
      print('=============================================');
    });
  }, skip: skipUnless(hasMapBackend, '地図バックエンド未実装'));
}
