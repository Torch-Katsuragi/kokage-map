// 計測ツール: 点を置く・戻す・消す、始点のタップか左下のボタンで面にする、空のタップは無視、ツールを離れたら消える
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/interfaces/map_state_interface.dart';
import 'package:root_maps/providers/tool_providers.dart';
import 'package:root_maps/providers/ui_state_providers.dart';
import 'package:root_maps/tools/measure_tool.dart';
import 'package:root_maps/utils/geodesic.dart';

/// 1 px = 0.00001° の素直な投影。画面の上半分（y < 0）は空で地図に当たらない
class _FakeMap implements IMapState {
  static const _o = LatLng(33.93, 135.96);
  static const _k = 0.00001;

  @override
  LatLng? tryOffsetToLatLng(Offset o) => o.dy < 0 ? null : LatLng(_o.latitude - o.dy * _k, _o.longitude + o.dx * _k);

  @override
  LatLng offsetToLatLng(Offset o) => tryOffsetToLatLng(o) ?? _o;

  @override
  Offset latLngToOffset(LatLng p) => Offset((p.longitude - _o.longitude) / _k, (_o.latitude - p.latitude) / _k);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

TapUpDetails _tap(double x, double y) => TapUpDetails(kind: PointerDeviceKind.touch, localPosition: Offset(x, y));

void main() {
  group('MeasureSession', () {
    const a = LatLng(33.93, 135.96);
    const b = LatLng(33.93, 135.97);
    const c = LatLng(33.94, 135.97);

    test('点を足すと区間と合計が増え、面の指定があっても 3 点未満なら面積は出ない', () {
      final s = MeasureSession();
      expect(s.segments, isEmpty);
      s.add(a);
      expect(s.total, 0);
      s.add(b);
      expect(s.segments, hasLength(1));
      expect(s.total, closeTo(Geodesic.distance(a, b), 1e-9));
      s.closeRequested = true;
      expect(s.isArea, isFalse);
      expect(s.area, isNull);
      s.add(c);
      expect(s.isArea, isTrue);
      // 面: 戻りの区間が入り、合計は周長
      expect(s.segments, hasLength(3));
      expect(s.total, closeTo(Geodesic.ringPerimeter([a, b, c]), 1e-6));
      expect(s.area, closeTo(Geodesic.ringArea([a, b, c]), 1e-6));
    });

    test('戻す・消す・面をやめる', () {
      final s = MeasureSession()
        ..add(a)
        ..add(b)
        ..add(c)
        ..closeRequested = true;
      var notified = 0;
      s.addListener(() => notified++);
      expect(s.undo(), isTrue);
      expect(s.points, [a, b]);
      expect(s.isArea, isFalse);
      s.add(c);
      s.closeRequested = false;
      expect(s.area, isNull);
      expect(s.segments, hasLength(2));
      s.clear();
      expect(s.isEmpty, isTrue);
      expect(s.undo(), isFalse);
      expect(notified, 4);
    });
  });

  group('MeasureTool', () {
    late ProviderContainer container;
    late MeasureTool tool;
    final map = _FakeMap();

    setUp(() {
      container = ProviderContainer();
      tool = container.read(measureToolProvider);
      container.read(currentToolProvider.notifier).set(tool);
    });
    tearDown(() => container.dispose());

    test('タップで点を置き、空のタップは無視する', () {
      tool.onTap(_tap(0, 0), map);
      tool.onTap(_tap(100, 0), map);
      tool.onTap(_tap(50, -20), map); // 空
      expect(tool.session.points, hasLength(2));
      expect(tool.session.total, closeTo(Geodesic.distance(map.offsetToLatLng(Offset.zero), map.offsetToLatLng(const Offset(100, 0))), 1e-6));
    });

    test('始点の近くを叩くと面になり、左下のボタンが点く（切り替えの表示はボタンから出る）', () {
      tool.onTap(_tap(0, 0), map);
      tool.onTap(_tap(100, 0), map);
      tool.onTap(_tap(100, 100), map);
      tool.onTap(_tap(5, 5), map); // 始点から 7 px
      expect(tool.session.points, hasLength(3));
      expect(container.read(isFabActiveProvider), isTrue);
      expect(tool.session.isArea, isTrue);
      expect(tool.session.area, greaterThan(0));
      // ボタンを消すと距離に戻る
      container.read(isFabActiveProvider.notifier).set(false);
      expect(tool.session.isArea, isFalse);
    });

    test('2 点のうちは始点を叩いても点が増える（面にならない）', () {
      tool.onTap(_tap(0, 0), map);
      tool.onTap(_tap(100, 0), map);
      tool.onTap(_tap(3, 0), map);
      expect(tool.session.points, hasLength(3));
      expect(container.read(isFabActiveProvider), isFalse);
    });

    test('ほかのツールに替えると測った線は消える', () {
      tool.onTap(_tap(0, 0), map);
      tool.onTap(_tap(100, 0), map);
      container.read(currentToolProvider.notifier).set(container.read(panToolProvider));
      expect(tool.session.isEmpty, isTrue);
    });
  });
}
