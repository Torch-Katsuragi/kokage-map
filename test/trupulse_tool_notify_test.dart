// TruPulse の道具の知らせ（計測・基準点・選んだレイヤの変化）は、道具を直接聞いているもの
// （地形・ステータスパネル）にだけ届き、プロバイダは進めない。
// 以前は知らせのたびにプロバイダも進めていて、地図ページがそれを聞いてページ全体を組み直していた。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/devices/trupulse/trupulse_providers.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/providers/selection_providers.dart';

final class _UpdateLog extends ProviderObserver {
  final updated = <String>[];

  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) {
    updated.add(context.provider.name ?? context.provider.toString());
  }
}

void main() {
  // 道具が音のプレイヤーを作る（プラグインは無いので黙って返す）
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

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
}
