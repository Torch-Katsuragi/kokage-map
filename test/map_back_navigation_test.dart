import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/devices/trupulse/trupulse_providers.dart';
import 'package:root_maps/editing/edit_session.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/tool_providers.dart';
import 'package:root_maps/screens/map_page/map_page.dart' show MapPagePopScope;
import 'package:root_maps/tools/map_tool.dart';
import 'package:root_maps/utils/global_drawing_state.dart';
import 'package:root_maps/widgets/radial_action_menu.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MenuTool extends MapTool {
  VoidCallback? _dismissMenu;

  @override
  String get name => 'MenuTool';

  @override
  IconData get icon => Icons.explore;

  void openMenu(BuildContext context) {
    late final VoidCallback dismiss;
    dismiss = showRadialMenu(
      context: context,
      center: const Offset(200, 200),
      onDismissed: () {
        if (identical(_dismissMenu, dismiss)) _dismissMenu = null;
      },
      actions: [
        RadialAction(icon: Icons.my_location, label: 'Station', onTap: () {}),
      ],
    );
    _dismissMenu = dismiss;
  }

  @override
  bool onBackPressed() {
    final d = _dismissMenu;
    if (d == null) return false;
    _dismissMenu = null;
    d();
    return true;
  }
}

class _DummyMapRoute extends ConsumerWidget {
  const _DummyMapRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(featureEditorProvider) != null;
    return MapPagePopScope(
      editing: editing,
      child: Scaffold(
        appBar: AppBar(
          leading: MapPagePopScope.buildLeading(context, ref, editing: editing),
          title: const Text('MapPage'),
        ),
        body: const Center(child: Text('MAP_BODY')),
      ),
    );
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(GlobalDrawingState.instance.clearAll);

  testWidgets('端末の戻るボタンではホーム画面に戻らず、左上の ← ボタンでのみホーム画面へ戻る', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(builder: (_) => const _DummyMapRoute()),
                  ),
                  child: const Text('OPEN_MAP'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('OPEN_MAP'));
    await tester.pumpAndSettle();
    expect(find.text('MAP_BODY'), findsOneWidget);

    // 1. 端末の戻る操作（handlePopRoute / maybePop）ではホーム画面へ戻らない
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('MAP_BODY'), findsOneWidget);
    expect(find.text('OPEN_MAP'), findsNothing);

    // 2. ツールの一時メニュー（放射状メニュー）が開いているときに端末の戻るを押すとメニューだけ閉じる
    final menuTool = _MenuTool();
    container.read(currentToolProvider.notifier).set(menuTool);
    menuTool.openMenu(tester.element(find.text('MAP_BODY')));
    await tester.pumpAndSettle();
    expect(find.text('Station'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Station'), findsNothing);
    expect(find.text('MAP_BODY'), findsOneWidget);

    // 3. 地物の編集中は、端末の戻るでも左上の ← でも編集を取り消すだけでホーム画面には戻らない
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('map_back_nav_'));
    final gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp!.path}/t.gpkg');
    addTearDown(() async {
      await gpkg.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final layer = PointLayerNode(gpkg, 'pts', parent: GeoPackageNode(gpkg));
    final pt = PointFeatureNode.fromGeoFeature(
      const geo.Feature<geo.Geometry>(
        geometry: geo.Point(geo.Geographic(lon: 136.0, lat: 34.0)),
        properties: {'name': 'P1'},
      ),
      layer,
      1,
    );
    await tester.runAsync(() => container.read(featureEditorProvider.notifier).start(pt));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(container.read(featureEditorProvider), isNotNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(container.read(featureEditorProvider), isNull);
    expect(find.text('MAP_BODY'), findsOneWidget);

    await tester.runAsync(() => container.read(featureEditorProvider.notifier).start(pt));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(container.read(featureEditorProvider), isNotNull);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(container.read(featureEditorProvider), isNull);
    expect(find.text('MAP_BODY'), findsOneWidget);

    // 4. 通常時に左上の ← ボタンを押すと確認なしでホーム画面へ戻る
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('OPEN_MAP'), findsOneWidget);
    expect(find.text('MAP_BODY'), findsNothing);
  });

  testWidgets('未確定の測量・作図データやTruPulse器械点があるときは左上の ← で確認ダイアログを出す', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(builder: (_) => const _DummyMapRoute()),
                  ),
                  child: const Text('OPEN_MAP'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('OPEN_MAP'));
    await tester.pumpAndSettle();

    // 1. 未確定のライン測量点がある状態 → 左上の ← で確認ダイアログ
    GlobalDrawingState.instance.addPoint(const LatLng(34.0, 136.0), null, isLine: true);
    expect(GlobalDrawingState.instance.isDrawing, isTrue);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text(t.map.leaveConfirm.unconfirmedDrawing), findsOneWidget);

    // 「地図に留まる」を選ぶとデータも画面も維持される
    await tester.tap(find.text(t.map.leaveConfirm.stay));
    await tester.pumpAndSettle();
    expect(find.text('MAP_BODY'), findsOneWidget);
    expect(GlobalDrawingState.instance.isDrawing, isTrue);

    // 「ホームへ戻る」を選ぶと未確定データをクリアしてホーム画面へ戻る
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.map.leaveConfirm.leave));
    await tester.pumpAndSettle();
    expect(GlobalDrawingState.instance.isDrawing, isFalse);
    expect(find.text('OPEN_MAP'), findsOneWidget);

    // 2. TruPulse ツール選択中で器械点が設定されている状態 → 左上の ← で確認ダイアログ
    await tester.tap(find.text('OPEN_MAP'));
    await tester.pumpAndSettle();

    final gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: 't.gpkg');
    final layer = PointLayerNode(gpkg, 'pts', parent: GeoPackageNode(gpkg));
    final stn = PointFeatureNode.fromGeoFeature(
      const geo.Feature<geo.Geometry>(
        geometry: geo.Point(geo.Geographic(lon: 136.0, lat: 34.0)),
        properties: {'name': 'STN0'},
      ),
      layer,
      1,
    );
    final trupulse = container.read(trupulseToolProvider)..debugStation = stn;
    container.read(currentToolProvider.notifier).set(trupulse);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text(t.map.leaveConfirm.trupulseStation), findsOneWidget);

    // 「地図に留まる」なら器械点は維持される
    await tester.tap(find.text(t.map.leaveConfirm.stay));
    await tester.pumpAndSettle();
    expect(find.text('MAP_BODY'), findsOneWidget);
    expect(trupulse.station, same(stn));

    // 「ホームへ戻る」なら器械点を解除してホーム画面へ戻る
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.map.leaveConfirm.leave));
    await tester.pumpAndSettle();
    expect(trupulse.station, isNull);
    expect(find.text('OPEN_MAP'), findsOneWidget);
  });
}
