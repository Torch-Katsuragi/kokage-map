// 「URL から背景地図を追加」の入力が重くならないこと（2026-10-12）
//
// web で 95 文字ほどの XYZ の URL をブラウザ拡張から一気に打ち込んだらタブが固まった、という観察を受けて
// アプリ側に 1 打鍵ごとの重い仕事が無いことを押さえる:
// - 1 打鍵でやるのは URL の検査（正規表現・組み込みとの突き合わせ）だけ。通信（probeTile）はしない
// - setState が自分を呼び直して止まらない、ということが無い（打ち終われば次のフレームは要らない）
// - 検査の正規表現は長い・意地の悪い入力でも線形に近い時間で終わる
// - 確かめている途中で URL を変えたら、戻ってきた古い結果は捨てる
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/basemap_provider.dart';
import 'package:root_maps/services/basemap_service.dart';
import 'package:root_maps/widgets/custom_basemap_dialog.dart';

/// 通信しない差し替え。probeTile が呼ばれた回数を数え、結果は [next] を待って返す
class _FakeService implements BaseMapService {
  int probes = 0;
  Completer<TileProbeResult>? next;

  @override
  Future<TileProbeResult> probeTile(BaseMapProvider provider, int z, int x, int y) {
    probes++;
    return (next ??= Completer<TileProbeResult>()).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// 観察時と同じくらいの長さ（約 95 文字）
const _longUrl = 'https://tiles.example-forest-agency.go.jp/xyz/ortho_2024_cs_relief/{z}/{x}/{y}.png?style=default';

Future<_FakeService> _open(WidgetTester tester) async {
  await LocaleSettings.setLocale(AppLocale.ja);
  final svc = _FakeService();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showCustomBaseMapDialog(
              context,
              service: svc,
              center: const LatLng(33.9, 135.9),
              zoom: 14,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return svc;
}

/// 落ち着くまでのフレーム数（入力欄の枠やエラー表示のアニメーションで十数枚）。
/// 自分を呼び直す setState があれば 2 秒で落ち着かず例外になる
Future<int> _settleFrames(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));

Finder get _urlField => find.byType(TextField).at(1);

void main() {
  setUp(() => BaseMapProvider.customProviders = const []);

  testWidgets('長い URL を一度に入れても、通信せず、フレームも止まる', (tester) async {
    expect(_longUrl.length, greaterThan(90));
    final svc = await _open(tester);
    final sw = Stopwatch()..start();
    await tester.enterText(_urlField, _longUrl);
    expect(await _settleFrames(tester), lessThan(40), reason: '入力のあとに再描画が続かない（setState の自己ループが無い）');
    sw.stop();
    expect(svc.probes, 0, reason: '打鍵では確かめに行かない');
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(find.text(_longUrl), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1 文字ずつ速く打っても（約 95 回の変更）同じ', (tester) async {
    final svc = await _open(tester);
    final sw = Stopwatch()..start();
    for (var i = 1; i <= _longUrl.length; i++) {
      await tester.enterText(_urlField, _longUrl.substring(0, i));
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(await _settleFrames(tester), lessThan(40));
    // 消して打ち直す（エラー表示が出たり消えたりを往復させる）
    for (var i = _longUrl.length; i >= 0; i -= 7) {
      await tester.enterText(_urlField, _longUrl.substring(0, i));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    sw.stop();
    expect(svc.probes, 0);
    // テストの枠組みだけで 1 回の入力に 20〜30 ms 掛かる（素の TextField のダイアログでも半分ほど）。
    // 固まりの検出が目的なので緩くとる。長さを 10 倍にしても 1 回あたりは変わらない（2026-10-12 に計測）
    expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('確かめている途中で URL を変えたら、古い結果は出さない', (tester) async {
    final svc = await _open(tester);
    await tester.enterText(_urlField, _longUrl);
    await tester.pump();
    await tester.tap(find.text(t.basemap.custom.check));
    await tester.pump();
    expect(svc.probes, 1);
    expect(find.text(t.basemap.custom.checking), findsOneWidget);

    await tester.enterText(_urlField, '${_longUrl}x');
    await tester.pump();
    svc.next!.complete(const TileProbeResult(TileProbeStatus.ok));
    await tester.pumpAndSettle();
    expect(find.text(t.basemap.custom.probeOk), findsNothing, reason: '前の URL の結果を今の URL に付けない');
    expect(find.text(t.basemap.custom.checking), findsNothing);
  });

  group('検査の正規表現は長い入力でも速い', () {
    // 破滅的なバックトラックがあれば数千文字で秒〜分単位になる。線形なら数十 ms
    const n = 20000;
    final inputs = <String, String>{
      'ドットの連続': 'https://${'a.' * n}google.',
      'google. のあとに長い英字と記号': 'https://google.${'a.' * n}-',
      'スキーム無しの長い文字列': 'http${'s' * n}',
      'スラッシュ無しの長いホスト': 'https://${'a' * n}',
      'テンプレートの断片だらけ': 'https://a.example/${'{z}{x}' * n}',
      'サブドメイン印の連続': 'https://${'{s}.' * n}example/{z}/{x}/{y}',
    };
    for (final MapEntry(key: name, value: url) in inputs.entries) {
      test(name, () {
        final sw = Stopwatch()..start();
        BaseMapProvider.isValidTemplate(url);
        BaseMapProvider.isForbiddenTileHost(url);
        BaseMapProvider.findByTileUrl(url);
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 500)));
      });
    }

    test('観察時の長さの URL を 1 文字ずつ全部検査しても一瞬', () {
      final sw = Stopwatch()..start();
      for (var i = 1; i <= _longUrl.length; i++) {
        final s = _longUrl.substring(0, i);
        BaseMapProvider.isValidTemplate(s);
        BaseMapProvider.isForbiddenTileHost(s);
        BaseMapProvider.findByTileUrl(s);
      }
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)));
    });
  });
}
