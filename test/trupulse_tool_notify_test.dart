// TruPulse の道具の知らせ（計測・基準点・選んだレイヤの変化）は、道具を直接聞いているもの
// （地形・ステータスパネル）にだけ届き、プロバイダは進めない。
// 以前は知らせのたびにプロバイダも進めていて、地図ページがそれを聞いてページ全体を組み直していた。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/devices/trupulse/trupulse_providers.dart';
import 'package:root_maps/models/app_notification.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/providers/selection_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _UpdateLog extends ProviderObserver {
  final updated = <String>[];

  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) {
    updated.add(context.provider.name ?? context.provider.toString());
  }
}

String _hvSentence(double hd, double az) {
  final body = 'PLTIT,HV,${hd.toStringAsFixed(2)},M,${az.toStringAsFixed(2)},D,0.00,D,${hd.toStringAsFixed(2)},M';
  var xor = 0;
  for (final c in body.codeUnits) {
    xor ^= c;
  }
  final hex = xor.toRadixString(16).toUpperCase().padLeft(2, '0');
  return '\$$body*$hex';
}

void main() {
  // 道具が音のプレイヤーを作る（プラグインは無いので黙って返す）
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('道具の知らせは道具の購読者にだけ届き、ほかのプロバイダは動かない', () {
    final log = _UpdateLog();
    final container = ProviderContainer(observers: [log]);
    addTearDown(container.dispose);

    final tool = container.read(trupulseToolProvider);
    var notified = 0;
    tool.addListener(() => notified++);
    tool.onActivate();
    addTearDown(tool.onDeactivate);

    // 選んだレイヤが変わると、道具は知らせる（計測のときと同じ _notifyUI を通る）
    final gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: 't.gpkg');
    final layer = PointLayerNode(gpkg, 'pts', parent: GeoPackageNode(gpkg));
    log.updated.clear();
    container.read(selectedLayerNodeProvider.notifier).select(layer);

    expect(notified, 1);
    expect(log.updated, ['selectedLayerNodeProvider']);
  });

  test('ポイントレイヤ未選択時は記録せずエラー音を鳴らし、選択時は前視・後視・許容差超過で音を分ける', () async {
    final tmp = await Directory.systemTemp.createTemp('trupulse_tool_');
    final gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    final gpkgNode = GeoPackageNode(gpkg);
    final ptLayer = (await PointLayerNode.createIn(gpkgNode, 'pts'))!;
    final lineLayer = (await LineLayerNode.createIn(gpkgNode, 'lines'))!;
    await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
    final p0 = (await PointFeatureNode.createIn(ptLayer, const LatLng(34.0, 136.0), 'P0', null))!;

    final container = ProviderContainer();
    addTearDown(() async {
      container.dispose();
      await gpkg.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final service = container.read(trupulseServiceProvider);
    final tool = container.read(trupulseToolProvider);
    tool.onActivate();
    addTearDown(tool.onDeactivate);

    tool.debugStation = p0;

    // 1. レイヤ未選択で測距 → 記録されずエラー音 + 警告通知
    tool.debugClearLastPlayedAsset();
    service.debugReceiveLine(_hvSentence(10.0, 90.0));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ptLayer.featureCount, 1);
    expect(tool.debugLastPlayedAsset, 'sounds/survey_error.wav');
    expect(container.read(notificationCenterProvider), isNotEmpty);

    // 2. ラインレイヤ選択中で測距 → 記録されずエラー音
    tool.debugClearLastPlayedAsset();
    container.read(selectedLayerNodeProvider.notifier).select(lineLayer);
    service.debugReceiveLine(_hvSentence(10.0, 90.0));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ptLayer.featureCount, 1);
    expect(tool.debugLastPlayedAsset, 'sounds/survey_error.wav');

    // 3. 正しいポイントレイヤを選択して前視 → 記録され point_created.wav + featuresRevisionNotifier 更新
    tool.debugClearLastPlayedAsset();
    final revBefore = ptLayer.featuresRevision;
    container.read(selectedLayerNodeProvider.notifier).select(ptLayer);
    service.debugReceiveLine(_hvSentence(10.0, 90.0));
    while (tool.debugLastPlayedAsset == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ptLayer.featureCount, 2);
    expect(ptLayer.featuresRevision, greaterThan(revBefore));
    expect(tool.debugLastPlayedAsset, 'sounds/point_created.wav');

    // 4. 振り返りで後視（270° = 逆向き、10.00m → 誤差0で基準内）→ backsight_applied.wav
    tool.debugClearLastPlayedAsset();
    service.debugReceiveLine(_hvSentence(10.0, 270.0));
    while (tool.debugLastPlayedAsset == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ptLayer.featureCount, 2);
    expect(tool.debugLastPlayedAsset, 'sounds/backsight_applied.wav');
    expect(container.read(notificationCenterProvider).first.level, NotificationLevel.success);

    // 5. 次の前視 P2（10.0m, 90.0°）→ point_created.wav
    tool.debugClearLastPlayedAsset();
    service.debugReceiveLine(_hvSentence(10.0, 90.0));
    while (tool.debugLastPlayedAsset == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ptLayer.featureCount, 3);
    expect(tool.debugLastPlayedAsset, 'sounds/point_created.wav');

    // 6. 振り返りで後視（273.5° → 角度差 3.5° > 既定上限 2.0°）→ backsight_warning.wav（ピポ↓ーン）+ 警告通知
    tool.debugClearLastPlayedAsset();
    service.debugReceiveLine(_hvSentence(10.0, 273.5));
    while (tool.debugLastPlayedAsset == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ptLayer.featureCount, 3);
    expect(tool.debugLastPlayedAsset, 'sounds/backsight_warning.wav');
    expect(container.read(notificationCenterProvider).first.level, NotificationLevel.warning);
  });
}
