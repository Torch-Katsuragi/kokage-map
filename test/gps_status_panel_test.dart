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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/gnss_quality.dart';
import 'package:root_maps/models/gps_info.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/gps_providers.dart';
import 'package:root_maps/providers/selection_providers.dart';
import 'package:root_maps/providers/tool_providers.dart';
import 'package:root_maps/screens/map_page/widgets/gps_status_panel.dart';
import 'package:root_maps/utils/global_drawing_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.ja);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalDrawingState.instance.clearAll();
  });

  Widget buildHarness({
    required ProviderContainer container,
    required GpsInfo info,
    bool toolbarLeft = true,
    VoidCallback? onTap,
  }) {
    final gpsTool = container.read(gpsToolProvider);
    return UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                GpsStatusPanel(
                  tool: gpsTool,
                  toolbarLeft: toolbarLeft,
                  infoOverride: info,
                  onTapOverride: onTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('内蔵GPS使用時: 右下に受信状態・座標・精度・標高・方位を表示し、線作図中はFABの上に退避する', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const internalInfo = GpsInfo(
      sourceType: GpsSourceType.internal,
      latitude: 33.941234,
      longitude: 135.961234,
      altitude: 145.2,
      accuracy: 3.4,
      bearing: 180,
      isGpsActive: true,
      isInitialized: true,
    );

    var tapped = false;
    await tester.pumpWidget(
      buildHarness(
        container: container,
        info: internalInfo,
        onTap: () => tapped = true,
      ),
    );

    expect(find.text('内蔵GPS'), findsOneWidget);
    expect(find.text('測位中'), findsOneWidget);
    expect(find.text('33.941234, 135.961234'), findsOneWidget);
    expect(find.text('±3.4 m'), findsOneWidget);
    expect(find.text('145.2m'), findsOneWidget);
    expect(find.text('180°'), findsOneWidget);

    final posNormal = tester.widget<Positioned>(find.byType(Positioned));
    expect(posNormal.right, 8);
    expect(posNormal.bottom, 8);

    await tester.tap(find.byType(Card));
    expect(tapped, isTrue);

    // 線レイヤで頂点を記録中（右下に確定FABが出る状態）は bottom: 84 へ持ち上がる
    addTearDown(GlobalDrawingState.instance.clearAll);
    final lineLayer = LineLayerNode(GeoPackageFile(const ['dummy.gpkg']), 'ルート');
    container.read(selectedLayerNodeProvider.notifier).select(lineLayer);
    GlobalDrawingState.instance.addPoint(const LatLng(33.94, 135.96), null, isLine: true);
    await tester.pump();

    expect(find.text('ルート'), findsOneWidget);
    final posShifted = tester.widget<Positioned>(find.byType(Positioned));
    expect(posShifted.bottom, 84);
    GlobalDrawingState.instance.clearAll();
  });

  testWidgets('外部GNSS接続時: 機器名・RTK FIX・GST精度・衛星数・HDOPを表示し、未測位・切断・品質ゲート警告にも追従する',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // 1. 外部GNSS RTK FIX（GST標準偏差あり）
    const rtkInfo = GpsInfo(
      sourceType: GpsSourceType.external,
      selectedDevice: 'DG-PRO1RWS',
      latitude: 33.941234,
      longitude: 135.961234,
      altitude: 210.5,
      accuracy: 0.02,
      accuracySource: GnssAccuracySource.gst,
      isGpsActive: true,
      isInitialized: true,
      isExternalConnected: true,
      satelliteCount: 18,
      hdop: 0.62,
      gpsQuality: 4,
      fixType: 'RTK Fixed',
    );

    await tester.pumpWidget(buildHarness(container: container, info: rtkInfo));

    expect(find.text('外部GNSS · DG-PRO1RWS'), findsOneWidget);
    expect(find.text('RTK FIX'), findsOneWidget);
    expect(find.text('精度(GST)'), findsOneWidget);
    expect(find.text('±0.02 m'), findsOneWidget);
    expect(find.text('18基'), findsOneWidget);
    expect(find.text('0.62'), findsOneWidget);
    expect(find.text('210.5m'), findsOneWidget);

    // 2. 品質足切り（RTK FIX・±0.05m必須）に対して DGPS 測位が届いたとき警告が出る
    await container.read(gnssQualityGateSettingProvider.notifier).set(
          const GnssQualityGate(
            maxAccuracy: 0.05,
            minFix: GnssFix.rtkFixed,
            strict: true,
          ),
        );

    const dgpsInfo = GpsInfo(
      sourceType: GpsSourceType.external,
      selectedDevice: 'DG-PRO1RWS',
      latitude: 33.941234,
      longitude: 135.961234,
      accuracy: 0.8,
      accuracySource: GnssAccuracySource.hdop,
      isGpsActive: true,
      isInitialized: true,
      isExternalConnected: true,
      satelliteCount: 10,
      hdop: 0.90,
      gpsQuality: 9,
      fixType: 'SBAS(MSAS)',
      correctionSource: 'MSAS (PRN 137, MTSAT-2)',
    );

    await tester.pumpWidget(buildHarness(container: container, info: dgpsInfo));
    await tester.pump();

    expect(find.text('SBAS(MSAS)'), findsOneWidget);
    expect(find.textContaining('MSAS'), findsWidgets);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    // 3. 接続直後の No Fix（座標未取得・衛星4基）
    const noFixInfo = GpsInfo(
      sourceType: GpsSourceType.external,
      selectedDevice: 'DG-PRO1RWS',
      isGpsActive: true,
      isInitialized: true,
      isExternalConnected: true,
      satelliteCount: 4,
      gpsQuality: 0,
      fixType: 'No Fix',
    );

    await tester.pumpWidget(buildHarness(container: container, info: noFixInfo));
    await tester.pump();

    expect(find.text('No Fix'), findsOneWidget);
    expect(find.text('4基'), findsOneWidget);

    // 4. Bluetooth 切断時
    const disconnectedInfo = GpsInfo(
      sourceType: GpsSourceType.external,
      selectedDevice: 'DG-PRO1RWS',
      isGpsActive: false,
      isInitialized: true,
      isExternalConnected: false,
    );

    await tester.pumpWidget(
      buildHarness(container: container, info: disconnectedInfo, toolbarLeft: false),
    );
    await tester.pump();

    expect(find.text('未接続'), findsOneWidget);
    // 左利き配置では左下に逃げる
    final leftHandedPos = tester.widget<Positioned>(find.byType(Positioned));
    expect(leftHandedPos.left, 8);
    expect(leftHandedPos.right, isNull);
  });
}
