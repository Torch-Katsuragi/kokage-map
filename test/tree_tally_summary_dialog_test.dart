// 毎木調査の集計: 材積式の地域を続けて切り替えたとき、先に頼んだ遅い集計が新しい集計を上書きしない
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/services/tree_tally/stem_volume.dart';
import 'package:root_maps/services/tree_tally/tree_tally_stats.dart';
import 'package:root_maps/services/tree_tally/tree_tally_store.dart';
import 'package:root_maps/widgets/tree_tally/tree_tally_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 集計だけ差し替える（頼まれた順に Completer を返す）
class _FakeLayers implements TreeTallyLayers {
  final calls = <Completer<List<PlotTally>>>[];

  @override
  Future<List<PlotTally>> summarize({double? Function(TallyTree)? volume}) {
    final c = Completer<List<PlotTally>>();
    calls.add(c);
    return c.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<PlotTally> _tallies(String plotId, int trees) => [
      PlotTally.of(plotId, [for (var i = 0; i < trees; i++) const TallyTree(species: 'スギ', dbhCm: 20, heightM: 15)], 500),
    ];

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocaleSettings.setLocale(AppLocale.ja);
  });

  testWidgets('地域を続けて切り替えても、最後に頼んだ集計が残る', (tester) async {
    final layers = _FakeLayers();
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showTreeTallySummary(context, ref, layers),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // 集計を待つ間はくるくるが回るので settle しない
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(layers.calls, hasLength(1));
    layers.calls[0].complete(_tallies('P0', 1));
    await tester.pumpAndSettle();
    expect(find.text('P0'), findsOneWidget);

    Future<void> pickRegion(String label) async {
      await tester.tap(find.byType(DropdownButton<VolumeRegion?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    // 西日本編 → 出さない と続けて切り替える。集計はまだ返さない
    await pickRegion(t.treeTally.volumeRegions.kinkiChugoku);
    await pickRegion(t.treeTally.volumeRegionNone);
    expect(layers.calls, hasLength(3));

    // 待っている間は CSV に保存させない（出ているのは前の地域の集計）
    final save = find.widgetWithText(TextButton, t.treeTally.saveCsv);
    expect(tester.widget<TextButton>(save).onPressed, isNull);

    // 新しい集計が先に返り、古い集計があとから返る
    layers.calls[2].complete(_tallies('NEW', 2));
    await tester.pumpAndSettle();
    layers.calls[1].complete(_tallies('OLD', 3));
    await tester.pumpAndSettle();

    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('OLD'), findsNothing);
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
  });
}
