// 地図バックエンドの契約テスト（Android / web 共通）
//
// 実行:
//   flutter test integration_test/map_contract_test.dart -d <android device>
//
//   web だけは `flutter test -d chrome` が使えない。chromedriver を立てて
//   `flutter drive` を使う（手順は [[docs/technical/testing]]）:
//     chromedriver --port=4444
//     flutter drive --driver=test_driver/integration_test.dart //       --target=integration_test/map_contract_test.dart //       -d web-server --browser-name=chrome
//
// 目的:
//   地図バックエンドが**プラットフォームごとに別物**（Android はネイティブSDK、
//   web は maplibre-gl-js）なので、その挙動差をここで数値として固定する。
//   もとは Windows版（maplibre_webview）の受け入れ条件として作ったもので、
//   デスクトップ撤去後は web が同じ役目を引き継いでいる。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:root_maps/core/r_map_controller.dart';
import 'package:root_maps/widgets/map/r_map_widget.dart';

import 'support/harness.dart';

/// 契約テストの基準座標（北山村役場付近）
const kTestCenter = LatLng(33.9707, 135.8534);
const kTestZoom = 14.0;

/// 地図ウィジェットの論理サイズ。座標変換の期待値がサイズに依存するため固定する。
const kMapSize = Size(400, 400);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets の skip は bool しか取れないため、理由つきの skip は group 側に置く。
  group('地図バックエンド契約 [$platformName]', () {
    late RMapController controller;
    late ml.StyleController style;

    /// 地図を描画し、スタイル読込完了まで待つ。
    Future<void> pumpMap(WidgetTester tester) async {
      var styleLoaded = false;

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
                      lon: kTestCenter.longitude,
                      lat: kTestCenter.latitude,
                    ),
                    initZoom: kTestZoom,
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
        reason: 'onStyleLoaded が発火しない（地図バックエンドが動いていない）',
      );

      // > [!IMPORTANT] web は生成直後、まだコンテナのサイズを取り込んでいない
      // > maplibre-gl は ResizeObserver でコンテナの縮小に気づくが、それは
      // > 非同期。それまで投影はページ幅を基準にした値を返す
      // > （400pxのウィジェットなのに中心の dx が 789 になる）。
      // >
      // > さらに厄介なことに、この遅れてくる `resize()` は `moveend` を撒く。
      // > 飛行中に来ると maplibre_web が flyTo を「キャンセルされた」と判定し、
      // > カメラが途中で止まる。**地図が落ち着く前にテストを始めない。**
      await pumpUntil(
        tester,
        () =>
            (controller.toScreenLocation(kTestCenter).dx - kMapSize.width / 2)
                .abs() <
            2.0,
        reason: '地図がウィジェットのサイズを取り込まない',
      );
    }

    testWidgets('スタイルが読み込まれ、初期カメラが指定どおりになる', (tester) async {
      await pumpMap(tester);

      expect(
        controller.raw,
        isNotNull,
        reason: 'MapController が attach されていない',
      );
      expect(
        controller.style,
        isNotNull,
        reason: 'StyleController が attach されていない',
      );

      final cam = controller.camera;
      expect(cam.zoom, closeTo(kTestZoom, 0.01));
      expect(cam.center.latitude, closeTo(kTestCenter.latitude, 1e-4));
      expect(cam.center.longitude, closeTo(kTestCenter.longitude, 1e-4));
      expect(cam.bearing, closeTo(0, 0.01));
      expect(cam.pitch, closeTo(0, 0.01));
    });

    testWidgets('move() が即時にカメラへ反映される', (tester) async {
      await pumpMap(tester);

      const target = LatLng(34.0, 135.9);
      controller.move(target, 12.0);
      await pumpUntil(
        tester,
        () => (controller.camera.zoom - 12.0).abs() < 0.01,
        reason: 'move() 後にズームが反映されない',
      );

      final cam = controller.camera;
      expect(cam.center.latitude, closeTo(target.latitude, 1e-4));
      expect(cam.center.longitude, closeTo(target.longitude, 1e-4));
    });

    testWidgets('moveAndRotate() で bearing が反映される', (tester) async {
      await pumpMap(tester);

      controller.moveAndRotate(kTestCenter, kTestZoom, 45.0);
      await pumpUntil(
        tester,
        () => (controller.camera.bearing - 45.0).abs() < 0.5,
        reason: 'moveAndRotate() 後に bearing が反映されない',
      );
      // rotation は bearing の別名。同じ値を返す契約。
      expect(
        controller.camera.rotation,
        closeTo(controller.camera.bearing, 1e-6),
      );
    });

    testWidgets('カメラ中心のスクリーン座標がウィジェット中央になる', (tester) async {
      await pumpMap(tester);

      final offset = controller.toScreenLocation(kTestCenter);
      // 論理ピクセルでウィジェット中央。バックエンドがDPRを二重適用すると
      // ここが 2 倍ズレる。
      expect(
        offset.dx,
        closeTo(kMapSize.width / 2, 2.0),
        reason: 'toScreenLocation のX。DPRの扱いを疑う',
      );
      expect(
        offset.dy,
        closeTo(kMapSize.height / 2, 2.0),
        reason: 'toScreenLocation のY。DPRの扱いを疑う',
      );
    });

    testWidgets('スクリーン座標 ⇄ 地理座標が往復しても一致する', (tester) async {
      await pumpMap(tester);

      // 中央から外れた点で試す（中央だけだと恒等変換でも通ってしまう）
      const probes = [Offset(50, 50), Offset(300, 120), Offset(180, 350)];
      for (final probe in probes) {
        final latLng = controller.toLngLat(probe);
        final back = controller.toScreenLocation(latLng);
        expect(back.dx, closeTo(probe.dx, 2.0), reason: '往復X $probe');
        expect(back.dy, closeTo(probe.dy, 2.0), reason: '往復Y $probe');
      }
    });

    testWidgets('KMapCamera のヘルパも同じ変換を返す', (tester) async {
      await pumpMap(tester);

      const probe = Offset(120, 240);
      final viaController = controller.toLngLat(probe);
      final viaCamera = controller.camera.offsetToCrs(probe);
      expect(viaCamera.latitude, closeTo(viaController.latitude, 1e-9));
      expect(viaCamera.longitude, closeTo(viaController.longitude, 1e-9));

      final screenA = controller.toScreenLocation(kTestCenter);
      final screenB = controller.camera.latLngToScreenOffset(kTestCenter);
      expect(screenB.dx, closeTo(screenA.dx, 1e-6));
      expect(screenB.dy, closeTo(screenA.dy, 1e-6));
    });

    testWidgets('animateTo() が完了し、目標カメラに着地する', (tester) async {
      await pumpMap(tester);

      const target = LatLng(33.90, 135.80);
      var done = false;
      // await するとテスト側が pump を回せず永久に完了しないため、
      // fire-and-forget して pump で進める。
      unawaited(controller.animateTo(center: target, zoom: 11.0).then((_) => done = true));

      await pumpUntil(
        tester,
        () => done,
        reason: 'animateTo() の Future が完了しない',
      );

      final cam = controller.camera;
      expect(cam.zoom, closeTo(11.0, 0.05));
      expect(cam.center.latitude, closeTo(target.latitude, 1e-3));
      expect(cam.center.longitude, closeTo(target.longitude, 1e-3));
    });

    testWidgets('fitCoordinates() が全座標を画面内に収める', (tester) async {
      await pumpMap(tester);

      const coords = [
        LatLng(33.95, 135.83),
        LatLng(33.99, 135.88),
        LatLng(33.97, 135.85),
      ];
      controller.fitCoordinates(coords, padding: const EdgeInsets.all(20));

      // 150ms のデバウンス + fitBounds のアニメーション分を待つ。
      await pumpUntil(tester, () {
        final screen = coords.map(controller.toScreenLocation);
        return screen.every(
          (o) =>
              o.dx >= 0 &&
              o.dx <= kMapSize.width &&
              o.dy >= 0 &&
              o.dy <= kMapSize.height,
        );
      }, reason: 'fitCoordinates() 後も座標が画面外にある');
    });

    testWidgets('GeoJSONソースとレイヤの追加・削除が反映される', (tester) async {
      await pumpMap(tester);

      const sourceId = 'contract-src';
      const layerId = 'contract-layer';
      const geoJson =
          '{"type":"FeatureCollection","features":['
          '{"type":"Feature","properties":{},'
          '"geometry":{"type":"Point","coordinates":[135.8534,33.9707]}}]}';

      await style.addSource(
        const ml.GeoJsonSource(id: sourceId, data: geoJson),
      );
      await style.addLayer(
        const ml.CircleStyleLayer(id: layerId, sourceId: sourceId),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        style.getLayerIds(),
        contains(layerId),
        reason: 'addLayer 後にレイヤIDが取得できない',
      );
      // 空スタイルの背景レイヤは残ったままである契約
      expect(
        style.getLayerIds(),
        contains('bg'),
        reason: 'addLayer が既存レイヤを吹き飛ばしている',
      );

      await style.updateGeoJsonSource(id: sourceId, data: geoJson);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        style.getLayerIds(),
        contains(layerId),
        reason: 'updateGeoJsonSource がレイヤを壊している',
      );

      // removeLayer の検証に getLayerIds() は使わない。
      // getLayerIds() は @visibleForTesting なキャッシュで、maplibre_webview は
      // addLayer 後にしか更新しない（removeLayer 後は消えたレイヤが残って見える）。
      // 実際の削除は効いているので、機能で確かめる:
      // 同じIDでもう一度 addLayer できれば、本当に消えている
      // （残っていれば MapLibre が duplicate id で失敗する）。
      await style.removeLayer(layerId);
      await tester.pump(const Duration(milliseconds: 300));
      await style.addLayer(
        const ml.CircleStyleLayer(id: layerId, sourceId: sourceId),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        style.getLayerIds(),
        contains(layerId),
        reason: 'removeLayer 後に同じIDで再追加できない（削除が効いていない）',
      );

      // 後片付け
      await style.removeLayer(layerId);
      await style.removeSource(sourceId);
      await tester.pump(const Duration(milliseconds: 300));
    });
  }, skip: skipUnless(hasMapBackend, '地図バックエンド未実装'));
}
