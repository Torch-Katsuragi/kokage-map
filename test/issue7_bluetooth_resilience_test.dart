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

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/devices/trupulse/trupulse_providers.dart';
import 'package:root_maps/devices/trupulse/trupulse_status_panel.dart';
import 'package:root_maps/devices/trupulse/trupulse_tool.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/gps_position_record.dart';
import 'package:root_maps/models/map_style_group.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/device_tool_providers.dart';
import 'package:root_maps/providers/gps_providers.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/providers/selection_providers.dart';
import 'package:root_maps/providers/service_providers.dart';
import 'package:root_maps/providers/tool_providers.dart';
import 'package:root_maps/screens/map_page/widgets/gps_status_panel.dart';
import 'package:root_maps/services/bluetooth_connection_coordinator.dart';
import 'package:root_maps/services/device_connection_log_service.dart';
import 'package:root_maps/services/gps_manager_service.dart';
import 'package:root_maps/services/ntrip/gnss_fix_sound_monitor.dart';
import 'package:root_maps/services/survey/survey_chain_resolver.dart';
import 'package:root_maps/services/survey/traverse_recorder.dart';
import 'package:root_maps/utils/global_drawing_state.dart';
import 'package:root_maps/widgets/device_connection_log_section.dart';
import 'package:root_maps/widgets/survey_conversion_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _nmeaWithChecksum(String body) {
  var xor = 0;
  for (final c in body.codeUnits) {
    xor ^= c;
  }
  return '\$$body*${xor.toRadixString(16).toUpperCase().padLeft(2, '0')}\r\n';
}

double _identityAz(double az, LatLng _) => az;

TraverseReading _shot(double az, double hd, {double inc = 0, int t = 0}) {
  final r = inc * math.pi / 180;
  return TraverseReading(
    az: az,
    inc: inc,
    hd: hd,
    sd: hd / math.cos(r),
    vd: hd * math.tan(r),
    timestamp: DateTime.utc(2026, 11, 17, 9, 0, t),
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      (_) async => null,
    );
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocaleSettings.setLocaleSync(AppLocale.ja);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BluetoothConnectionCoordinator.instance.resetForTesting();
    DeviceConnectionLogService.instance.resetForTesting();
    GpsManagerService().resetForTesting();
    GlobalDrawingState.instance.clearAll();
  });

  tearDown(() {
    GpsManagerService().resetForTesting();
    GlobalDrawingState.instance.clearAll();
  });

  group('Issue #7: 外部GNSS切断検知・無断フォールバック禁止・明示切替・再起動後自動再接続', () {
    test(
      '外部GNSS切断時は警告音＋通知を出し、無断で内蔵GPSへ切り替えず、明示フォールバック時のみ internal_fallback で区別して自動復帰する',
      () async {
        final tmp = await Directory.systemTemp.createTemp('issue7_gnss_');
        final gpkg = GeoPackageFile(
          const ['t.gpkg'],
          absolutePath: '${tmp.path}/t.gpkg',
        );
        final ptLayer =
            (await PointLayerNode.createIn(GeoPackageNode(gpkg), 'pts'))!;

        final container = ProviderContainer();
        addTearDown(() async {
          container.dispose();
          await gpkg.dispose();
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        final playedAssets = <String>[];
        final manager = container.read(gpsManagerServiceProvider);
        manager.debugFixSoundMonitor = GnssFixSoundMonitor(
          onPlayAsset: (asset) async => playedAssets.add(asset),
          cooldown: Duration.zero,
        );
        manager.externalReconnectBackoff = const [
          Duration(milliseconds: 80),
        ];

        const gnssDevice = BluetoothDevice(
          address: 'AA:BB:CC:11:22:33',
          name: 'DG-PRO1RWS',
        );
        var allowConnect = true;
        manager.internalStartOverride = () async {};
        manager.externalConnectOverride = (_) async {
          if (!allowConnect) throw Exception('radio_out_of_range');
          manager.ensureExternalServiceForTesting.debugSetConnected(true);
        };

        await manager.initialize();
        await manager.switchGpsSource(GpsSourceType.external, gnssDevice);
        expect(manager.isExternalConnected, isTrue);

        // RTK FIX の NMEA を流し、1点記録 → gps_source = 'external'
        final gga = _nmeaWithChecksum(
          'GNGGA,030000.00,3356.4740,N,13557.6740,E,4,16,0.6,145.2,M,38.1,M,1.0,0001',
        );
        manager.ensureExternalServiceForTesting
            .debugReceive(Uint8List.fromList(ascii.encode(gga)));

        container.read(selectedLayerNodeProvider.notifier).select(ptLayer);
        final gpsTool = container.read(gpsToolProvider);
        final r1 = await gpsTool.recordCurrentGpsPosition();
        expect(r1.recorded, isTrue);
        expect(ptLayer.featureCount, 1);
        final firstPt = ptLayer.children.whereType<PointFeatureNode>().first;
        expect(firstPt.properties['gps_source'], 'external');
        expect(firstPt.properties['gnss_device'], 'DG-PRO1RWS');

        // 電波切れで外部GNSSが切断（まだ再接続は失敗させる）
        allowConnect = false;
        playedAssets.clear();
        await manager.ensureExternalServiceForTesting
            .debugSimulateUnexpectedDisconnect('bt_link_loss');

        // 1) 切断警告音が鳴り、通知センターに警告が積み上がる
        expect(playedAssets, contains(GnssFixSoundMonitor.rtkLostAsset));
        final notes = container.read(notificationCenterProvider);
        expect(
          notes.any((n) => n.title.contains('DG-PRO1RWS')),
          isTrue,
        );
        // 2) 無断で内蔵GPSには切り替わっていない（内蔵GPSの測位が届いても無視される）
        expect(manager.currentSource, GpsSourceType.external);
        expect(manager.isFallbackInternal, isFalse);
        expect(manager.isExternalReconnecting, isTrue);
        manager.debugInjectInternalPosition(
          GpsPositionRecord(
            latitude: 33.9000,
            longitude: 135.9000,
            accuracy: 6.5,
            timestamp: DateTime.now(),
          ),
        );
        expect(manager.currentInfo.isActive, isFalse);

        // 切断中に単発記録を試みてもブロックされ、5m精度の内蔵GPS点は混入しない
        final blocked = await gpsTool.recordCurrentGpsPosition();
        expect(blocked.recorded, isFalse);
        expect(ptLayer.featureCount, 1);

        // 3) ユーザーが明示的に「内蔵GPSへ一時切替」を選択 → 記録可能になり internal_fallback が刻印される
        await manager.enableTemporaryInternalFallback();
        expect(manager.isFallbackInternal, isTrue);
        expect(manager.currentInfo.gpsSourceCode, 'internal_fallback');

        manager.debugInjectInternalPosition(
          GpsPositionRecord(
            latitude: 33.9005,
            longitude: 135.9005,
            accuracy: 5.8,
            timestamp: DateTime.now(),
          ),
        );
        final r2 = await gpsTool.recordCurrentGpsPosition();
        expect(r2.recorded, isTrue);
        expect(ptLayer.featureCount, 2);
        final fallbackPt = ptLayer.children.whereType<PointFeatureNode>().last;
        expect(fallbackPt.properties['gps_source'], 'internal_fallback');
        final drawingPts = fallbackPt.metadata?['drawing_points'] as List?;
        final firstMeta = drawingPts?.first as Map<String, dynamic>?;
        expect(firstMeta?['gps_source'], 'internal_fallback');

        // 4) 電波が戻るとバックグラウンド自動再接続で外部GNSSへ自動復帰する
        allowConnect = true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(manager.isExternalConnected, isTrue);
        expect(manager.isFallbackInternal, isFalse);
        expect(manager.currentInfo.gpsSourceCode, 'external');

        // 5) 接続・切断ログに一連の時刻付きイベントが残っている
        final logTypes =
            DeviceConnectionLogService.instance.events.map((e) => e.type).toList();
        expect(
          logTypes,
          containsAll([
            DeviceConnectionEventType.connected,
            DeviceConnectionEventType.disconnected,
            DeviceConnectionEventType.fallbackInternal,
            DeviceConnectionEventType.resumedExternal,
          ]),
        );
      },
    );

    test(
      'アプリ再起動後（SharedPreferences 復元）に、前回つないでいた外部GNSSと測距器の両方へ自動でつなぎ直す',
      () async {
        // 1回目の起動: 外部GNSS と TruPulse の両方を接続
        final c1 = ProviderContainer();
        final gm1 = c1.read(gpsManagerServiceProvider);
        gm1.externalConnectOverride = (_) async {
          gm1.ensureExternalServiceForTesting.debugSetConnected(true);
        };
        final tp1 = c1.read(trupulseServiceProvider);
        tp1.connectOverride = (_) async {};

        await gm1.initialize();
        await gm1.switchGpsSource(
          GpsSourceType.external,
          const BluetoothDevice(address: '11:22:33:44:55:66', name: 'Drogger-RWS'),
        );
        await tp1.connectToDevice(
          const BluetoothDevice(address: '77:88:99:AA:BB:CC', name: 'TruPulse 360R'),
        );
        c1.dispose();

        // アプリを「最近のアプリ」からタスクキルして再起動した状態を再現
        GpsManagerService().resetForTesting();
        final c2 = ProviderContainer();
        addTearDown(c2.dispose);

        await c2.read(preferredGpsSourceTypeProvider.notifier).load();
        await c2.read(selectedGnssDeviceAddressProvider.notifier).load();
        await c2.read(selectedGnssDeviceNameProvider.notifier).load();

        var gnssReconnectedAddr = '';
        final gm2 = c2.read(gpsManagerServiceProvider);
        gm2.scanDevicesOverride = () async => const [
              BluetoothDevice(address: '11:22:33:44:55:66', name: 'Drogger-RWS'),
            ];
        gm2.externalConnectOverride = (dev) async {
          gnssReconnectedAddr = dev.address;
          gm2.ensureExternalServiceForTesting.debugSetConnected(true);
        };

        var trupulseReconnectedAddr = '';
        final tp2 = c2.read(trupulseServiceProvider);
        tp2.connectOverride = (dev) async {
          trupulseReconnectedAddr = dev.address;
        };

        await gm2.initialize();
        await gm2.startGps();
        await tp2.restorePreviousConnection();

        expect(gm2.currentSource, GpsSourceType.external);
        expect(gm2.isExternalConnected, isTrue);
        expect(gnssReconnectedAddr, '11:22:33:44:55:66');
        expect(tp2.isConnected, isTrue);
        expect(trupulseReconnectedAddr, '77:88:99:AA:BB:CC');
      },
    );
  });

  group('Issue #7 & 後視やり直し: 測距器の瞬断復帰・未確定測線ガード・後視のみの取り消し', () {
    test('測距器が電波断で瞬断してもツールと器械点が維持され、数十秒以内に自動再接続する', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final svc = container.read(trupulseServiceProvider);
      svc.reconnectBackoff = const [Duration(milliseconds: 60)];
      var canConnect = true;
      svc.connectOverride = (_) async {
        if (!canConnect) throw Exception('out_of_range');
      };

      await svc.connectToDevice(
        const BluetoothDevice(address: '77:88:99:AA:BB:CC', name: 'TruPulse 360R'),
      );
      expect(svc.isConnected, isTrue);
      expect(container.read(connectedDeviceToolsProvider), isNotEmpty);

      // 一時的な電波切れ
      canConnect = false;
      await svc.debugSimulateUnexpectedDisconnect('timeout');
      expect(svc.isConnected, isFalse);
      expect(svc.isReconnecting, isTrue);
      // ツールバーからコンパスツールが消えず利用可能のまま維持される
      expect(container.read(connectedDeviceToolsProvider), isNotEmpty);

      // 電波復帰 → 自動再接続成功
      canConnect = true;
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(svc.isConnected, isTrue);
      expect(svc.isReconnecting, isFalse);
    });

    test('後視のない1回測定は未確定（provisional）として区別され、confirmedOnly では確定測線に含まれない', () async {
      final tmp = await Directory.systemTemp.createTemp('issue7_chain_');
      final gpkg = GeoPackageFile(
        const ['t.gpkg'],
        absolutePath: '${tmp.path}/t.gpkg',
      );
      final layer =
          (await PointLayerNode.createIn(GeoPackageNode(gpkg), 'pts'))!;
      await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
      final p0 = (await PointFeatureNode.createIn(
        layer,
        const LatLng(34.0, 136.0),
        'P0',
        null,
      ))!;
      addTearDown(() async {
        await gpkg.dispose();
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      // P0 -> P1（前視＋後視で確定）
      final p1 =
          (await TraverseRecorder.record(p0, _shot(90, 30, t: 1), trueAz: _identityAz))!
              .point;
      expect(p1.properties['survey_backsight'], 'false');
      await TraverseRecorder.record(p1, _shot(270, 30, t: 2), trueAz: _identityAz);
      expect(TraverseRecorder.isBacksighted(p1), isTrue);

      // P1 -> P2_orphan（瞬断前に前視1回だけ撃って後視できなかった未確定点）
      final p2Orphan =
          (await TraverseRecorder.record(p1, _shot(10, 25, t: 3), trueAz: _identityAz))!
              .point;
      expect(TraverseRecorder.isBacksighted(p2Orphan), isFalse);

      // P1 に戻って P1 -> P2_confirmed を前視＋後視で確定させた場合、チェーン解決は確定済みの P2_confirmed を優先する
      final p2Confirmed =
          (await TraverseRecorder.record(p1, _shot(0, 25, t: 4), trueAz: _identityAz))!
              .point;
      await TraverseRecorder.record(
        p2Confirmed,
        _shot(180, 25, t: 5),
        trueAz: _identityAz,
      );

      // P2_confirmed -> P3_tail（まだ後視していない末端の1回測定）
      final p3Tail = (await TraverseRecorder.record(
        p2Confirmed,
        _shot(45, 20, t: 6),
        trueAz: _identityAz,
      ))!
          .point;
      expect(TraverseRecorder.isBacksighted(p3Tail), isFalse);

      final rawChains = SurveyChainResolver.resolveAll(layer);
      expect(rawChains, hasLength(1));
      expect(rawChains.first.points.map((p) => p.node).toList(), [
        p1,
        p2Confirmed,
        p3Tail,
      ]);
      expect(rawChains.first.unconfirmedCount, 1);

      final confirmedChains =
          SurveyChainResolver.resolveAll(layer, confirmedOnly: true);
      expect(confirmedChains, hasLength(1));
      expect(confirmedChains.first.points.map((p) => p.node).toList(), [
        p1,
        p2Confirmed,
      ]);
      expect(confirmedChains.first.hasUnconfirmedPoints, isFalse);
    });

    test('undoBacksight: 許容差を超えた後視だけを取り消して元の前視に戻し、その場で再後視できる', () async {
      final tmp = await Directory.systemTemp.createTemp('issue7_undo_bs_');
      final gpkg = GeoPackageFile(
        const ['t.gpkg'],
        absolutePath: '${tmp.path}/t.gpkg',
      );
      final layer =
          (await PointLayerNode.createIn(GeoPackageNode(gpkg), 'pts'))!;
      await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
      final p0 = (await PointFeatureNode.createIn(
        layer,
        const LatLng(34.0, 136.0),
        'P0',
        null,
      ))!;
      addTearDown(() async {
        await gpkg.dispose();
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      // P0 -> P1 前視（AZ 90°, HD 40m）
      final p1 = (await TraverseRecorder.record(
        p0,
        _shot(90, 40, inc: 3, t: 1),
        trueAz: _identityAz,
      ))!
          .point;
      final originalP1Pos = p1.point;

      // 先に P1 -> P2 も前視していたとする（下流点の平行移動検証）
      final p2 = (await TraverseRecorder.record(
        p1,
        _shot(0, 20, t: 2),
        trueAz: _identityAz,
      ))!
          .point;
      final originalP2Pos = p2.point;

      // P1 -> P0 を誤った角度（274° → 4°誤差）で後視してしまった
      final badBs = (await TraverseRecorder.record(
        p1,
        _shot(274, 40.8, inc: -5, t: 3),
        trueAz: _identityAz,
      ))!;
      expect(badBs.kind, TraverseShotKind.backsight);
      expect(TraverseRecorder.isBacksighted(p1), isTrue);
      expect(TraverseRecorder.canUndoBacksight(p1), isTrue);
      expect(
        const Distance().distance(p1.point, originalP1Pos),
        greaterThan(0.5),
      );

      // 後視だけを取り消す → P1 も下流の P2 も元の前視位置へ正確に戻る！
      final undone = await TraverseRecorder.undoBacksight(
        p1,
        trueAz: _identityAz,
      );
      expect(undone, isTrue);
      expect(TraverseRecorder.isBacksighted(p1), isFalse);
      expect(TraverseRecorder.canUndoBacksight(p1), isFalse);
      expect(surveyNumber(p1.properties['survey_az']), closeTo(90, 1e-9));
      expect(surveyNumber(p1.properties['survey_hd']), closeTo(40, 1e-9));
      expect(p1.properties['survey_fs_az'], isNull);
      expect(p1.properties['survey_bs_az'], isNull);
      expect(
        const Distance().distance(p1.point, originalP1Pos),
        lessThan(0.005),
      );
      expect(
        const Distance().distance(p2.point, originalP2Pos),
        lessThan(0.005),
      );

      // 前の器械点 P0 へ歩かず、P1 に立ったまま正しい後視（270.4°, 40.2m）を撃ち直せる！
      final goodBs = (await TraverseRecorder.record(
        p1,
        _shot(270.4, 40.2, inc: -3.2, t: 4),
        trueAz: _identityAz,
      ))!;
      expect(goodBs.kind, TraverseShotKind.backsight);
      expect(TraverseRecorder.isBacksighted(p1), isTrue);
      expect(surveyNumber(p1.properties['survey_az']), closeTo(90.2, 1e-9));
      expect(surveyNumber(p1.properties['survey_hd']), closeTo(40.1, 1e-9));
    });

    testWidgets(
      'TruPulseStatusPanel の「後視をやり直す」ボタンと SurveyConversionDialog の未確定除外・DeviceConnectionLogSection 表示',
      (tester) async {
        late final Directory tmp;
        late final GeoPackageFile gpkg;
        late final PointLayerNode ptLayer;
        late final LineLayerNode lineLayer;
        late final PointFeatureNode p0;
        late final PointFeatureNode p1;

        final container = ProviderContainer();
        final tool = container.read(trupulseToolProvider);

        await tester.runAsync(() async {
          tmp = await Directory.systemTemp.createTemp('issue7_ui_');
          gpkg = GeoPackageFile(
            const ['t.gpkg'],
            absolutePath: '${tmp.path}/t.gpkg',
          );
          final gpkgNode = GeoPackageNode(gpkg);
          ptLayer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
          lineLayer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
          await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
          p0 = (await PointFeatureNode.createIn(
            ptLayer,
            const LatLng(34.0, 136.0),
            'P0',
            null,
          ))!;

          container.read(selectedLayerNodeProvider.notifier).select(ptLayer);
          tool.onActivate();

          // P0 -> P1 前視＋後視
          p1 = (await TraverseRecorder.record(
            p0,
            _shot(90, 20, t: 1),
            trueAz: TruPulseTool.trueAzimuth,
          ))!
              .point;
          await TraverseRecorder.record(
            p1,
            _shot(273.5, 20, t: 2),
            trueAz: TruPulseTool.trueAzimuth,
          );
          await gpkg.flushChanges();
          tool.debugStation = p1;
        });

        addTearDown(() async {
          tool.onDeactivate();
          container.dispose();
        });

        // オーバーレイ線が confirmed スタイルを持つ
        expect(
          tool.overlayLines().single.properties[kStyleProp],
          'confirmed',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: Stack(
                    children: [
                      TruPulseStatusPanel(tool: tool),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        // ステータスパネルに「後視をやり直す」ボタンが表示されており、タップ（sqflite FFI 実行）で未確定（後視待ち）に戻る
        final undoBtn = find.byKey(const Key('trupulse_undo_backsight_button'));
        expect(undoBtn, findsOneWidget);
        await tester.runAsync(() async {
          await tool.undoBacksightOf(p1);
          await gpkg.flushChanges();
        });
        await tester.pump();

        expect(TraverseRecorder.isBacksighted(p1), isFalse);
        expect(
          tool.overlayLines().single.properties[kStyleProp],
          'provisional',
        );
        expect(find.text(t.trupulse.panel.provisionalBadge), findsOneWidget);

        // 未確定しかないチェーンで SurveyConversionDialog を開くと、既定で変換ボタンが無効化され確定を防げる
        final chains = SurveyChainResolver.resolveAll(ptLayer);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: SurveyConversionDialog(
                    sourceLayer: ptLayer,
                    chains: chains,
                    availableLayers: [lineLayer],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.textContaining(t.surveyConversion.noConfirmedPoints),
          findsOneWidget,
        );

        // GpsStatusPanel の切断時「内蔵GPSへ一時切替」ボタンと DeviceConnectionLogSection 表示検証
        DeviceConnectionLogService.instance.record(
          category: DeviceConnectionCategory.gnss,
          type: DeviceConnectionEventType.disconnected,
          deviceName: 'DG-PRO1RWS',
          detail: 'link_loss',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: Column(
                    children: [
                      const Expanded(
                        child: SingleChildScrollView(
                          child: DeviceConnectionLogSection(),
                        ),
                      ),
                      SizedBox(
                        height: 220,
                        child: Stack(
                          children: [
                            GpsStatusPanel(
                              tool: container.read(gpsToolProvider),
                              infoOverride: const GpsInfo(
                                sourceType: GpsSourceType.external,
                                selectedDevice: 'DG-PRO1RWS',
                                isExternalConnected: false,
                                isExternalReconnecting: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('gps_use_internal_fallback_button')),
          findsOneWidget,
        );
        expect(find.text('DG-PRO1RWS'), findsWidgets);
        expect(find.text(t.devices.connectionLog.evDisconnected), findsOneWidget);

        await tester.runAsync(() async {
          await gpkg.dispose();
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });
      },
    );

    test(
      '電源OFF時の省電力ガード: 外部GNSS・測距器ともに上限回数で自動再接続を停止して待機モードへ移行し、1タップ手動再接続で即復帰する',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        // --- 1) 外部GNSS: maxExternalReconnectAttempts = 3 で打ち切り検証 ---
        final manager = container.read(gpsManagerServiceProvider);
        manager.debugFixSoundMonitor = GnssFixSoundMonitor(
          onPlayAsset: (_) async {},
        );
        manager.maxExternalReconnectAttempts = 3;
        manager.externalReconnectBackoff = const [
          Duration(milliseconds: 25),
          Duration(milliseconds: 25),
          Duration(milliseconds: 25),
        ];

        var gnssPowerOn = true;
        var gnssAttempts = 0;
        manager.externalConnectOverride = (_) async {
          gnssAttempts++;
          if (!gnssPowerOn) throw Exception('device_powered_off');
          manager.ensureExternalServiceForTesting.debugSetConnected(true);
        };

        await manager.initialize();
        await manager.switchGpsSource(
          GpsSourceType.external,
          const BluetoothDevice(address: 'AA:BB:CC:00:11:22', name: 'DG-PRO1RWS'),
        );
        expect(manager.isExternalConnected, isTrue);

        // 手動で外部GNSSの電源をOFFにした（Bluetooth SPP では link_loss として届く）
        gnssPowerOn = false;
        gnssAttempts = 0;
        await manager.ensureExternalServiceForTesting
            .debugSimulateUnexpectedDisconnect('power_off');
        expect(manager.isExternalReconnecting, isTrue);

        // 3回の試行後に自動再接続タイマーが完全停止し、それ以上試行が増えない（電池消費ゼロの待機状態）
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(gnssAttempts, 3);
        expect(manager.isExternalReconnecting, isFalse);
        expect(manager.hasExternalStandby, isTrue);

        // さらに待っても4回目の Bluetooth ページスキャンは一切走らない
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(gnssAttempts, 3);

        // 電源がOFFのまま手動「再接続」を押しても1回だけ試して再び待機に戻り、バックグラウンド無限ループには入らない
        await manager.reconnectExternalGnssNow();
        expect(gnssAttempts, 4);
        expect(manager.isExternalReconnecting, isFalse);
        expect(manager.hasExternalStandby, isTrue);

        // 電源を入れ直して1タップ「再接続」→ 即座に外部GNSSへ復帰
        gnssPowerOn = true;
        await manager.reconnectExternalGnssNow();
        expect(gnssAttempts, 5);
        expect(manager.isExternalConnected, isTrue);
        expect(manager.hasExternalStandby, isFalse);

        // --- 2) TruPulse 360R: オートパワーオフ後もツールと器械点を維持したまま待機し、1タップで再接続 ---
        final tp = container.read(trupulseServiceProvider);
        tp.maxReconnectAttempts = 2;
        tp.reconnectBackoff = const [
          Duration(milliseconds: 25),
          Duration(milliseconds: 25),
        ];

        var tpPowerOn = true;
        var tpAttempts = 0;
        tp.connectOverride = (_) async {
          tpAttempts++;
          if (!tpPowerOn) throw Exception('trupulse_auto_power_off');
        };

        await tp.connectToDevice(
          const BluetoothDevice(address: '77:88:99:00:11:22', name: 'TruPulse 360R'),
        );
        expect(tp.isConnected, isTrue);

        tpPowerOn = false;
        tpAttempts = 0;
        await tp.debugSimulateUnexpectedDisconnect('auto_power_off');
        await Future<void>.delayed(const Duration(milliseconds: 140));

        expect(tpAttempts, 2);
        expect(tp.isReconnecting, isFalse);
        expect(tp.hasStandbyDevice, isTrue);
        // 待機中もツールバーからコンパスツールが消えない！
        expect(container.read(connectedDeviceToolsProvider), isNotEmpty);

        // TruPulse の FIRE ボタンを押して電源ON → パネルの「再接続」で即復帰
        tpPowerOn = true;
        await tp.reconnectStandby();
        expect(tp.isConnected, isTrue);
        expect(tp.hasStandbyDevice, isFalse);
      },
    );

    testWidgets(
      '待機モード時に GpsStatusPanel と TruPulseStatusPanel の双方に1タップ「再接続」ボタンが表示される',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final tp = container.read(trupulseServiceProvider);
        tp.maxReconnectAttempts = 0;
        tp.connectOverride = (_) async {};
        await tp.connectToDevice(
          const BluetoothDevice(address: '77:88:99:00:11:22', name: 'TruPulse 360R'),
        );
        await tp.debugSimulateUnexpectedDisconnect('power_off');
        expect(tp.hasStandbyDevice, isTrue);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: Column(
                    children: [
                      SizedBox(
                        height: 220,
                        child: Stack(
                          children: [
                            TruPulseStatusPanel(
                              tool: container.read(trupulseToolProvider),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 240,
                        child: Stack(
                          children: [
                            GpsStatusPanel(
                              tool: container.read(gpsToolProvider),
                              infoOverride: const GpsInfo(
                                sourceType: GpsSourceType.external,
                                selectedDevice: 'DG-PRO1RWS',
                                isExternalConnected: false,
                                isExternalReconnecting: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('trupulse_reconnect_standby_button')),
          findsOneWidget,
        );
        expect(find.text(t.trupulse.panel.standbyBadge), findsOneWidget);

        expect(
          find.byKey(const Key('gps_reconnect_external_button')),
          findsOneWidget,
        );
        expect(find.text(t.gps.panel.standbyBadge), findsOneWidget);

        // TruPulse の「再接続」ボタンを1タップするとその場で接続が復活する
        await tester.tap(find.byKey(const Key('trupulse_reconnect_standby_button')));
        await tester.pumpAndSettle();
        expect(tp.isConnected, isTrue);
      },
    );

    test(
      '2台同時接続安定化: 外部GNSSと測距器の接続ハンドシェイクが同時に発火しても Page Scan が重ならず直列実行される',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        var activeHandshakes = 0;
        var maxConcurrentHandshakes = 0;
        final events = <String>[];

        final gm = container.read(gpsManagerServiceProvider);
        gm.externalConnectOverride = (_) async {
          activeHandshakes++;
          if (activeHandshakes > maxConcurrentHandshakes) {
            maxConcurrentHandshakes = activeHandshakes;
          }
          events.add('gnss:start');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          gm.ensureExternalServiceForTesting.debugSetConnected(true);
          events.add('gnss:end');
          activeHandshakes--;
        };

        final tp = container.read(trupulseServiceProvider);
        tp.connectOverride = (_) async {
          activeHandshakes++;
          if (activeHandshakes > maxConcurrentHandshakes) {
            maxConcurrentHandshakes = activeHandshakes;
          }
          events.add('tp:start');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          events.add('tp:end');
          activeHandshakes--;
        };

        await gm.initialize();

        // 起動時や同時瞬断からの復帰のように、2台へ同一フレームで同時に接続要求を投げる
        await Future.wait([
          gm.switchGpsSource(
            GpsSourceType.external,
            const BluetoothDevice(address: '11:22:33:44:55:66', name: 'DG-PRO1RWS'),
          ),
          tp.connectToDevice(
            const BluetoothDevice(address: '77:88:99:AA:BB:CC', name: 'TruPulse 360R'),
          ),
        ]);

        expect(gm.isExternalConnected, isTrue);
        expect(tp.isConnected, isTrue);
        // 決して2本の RFCOMM connect() が同時並行で走らない（start -> end が入れ子にならない）
        expect(maxConcurrentHandshakes, 1);
        expect(
          events,
          anyOf(
            equals(['gnss:start', 'gnss:end', 'tp:start', 'tp:end']),
            equals(['tp:start', 'tp:end', 'gnss:start', 'gnss:end']),
          ),
        );
      },
    );
  });
}
