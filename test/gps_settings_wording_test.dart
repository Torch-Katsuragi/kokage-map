// GPS・測位の設定の言葉: 軌跡の記録と測量の足切りで、精度の扱いが違う設定を同じ名前で並べない（2026-10-12 の結合点検）
//
// 軌跡の記録は精度の分からない測位を記録し、測量の足切りは弾く。画面ではどちらも「精度の上限」と並んでいた。
// 「指定しない」（足切り）と「なし」（軌跡）は同じ意味なので言葉をそろえる。保存の鍵は変えない
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';

void main() {
  for (final locale in [AppLocale.ja, AppLocale.en]) {
    test('${locale.languageCode}: 精度の設定の名前が軌跡と足切りで違い、精度の分からない測位の扱いを説明する', () async {
      final tr = await locale.build();
      final track = tr.trackRecording;
      final gate = tr.gnssQuality.settings;
      expect(track.maxAccuracy, isNot(gate.maxAccuracy));
      expect(track.maxAccuracyDesc, isNotEmpty);
      expect(gate.maxAccuracyDesc, isNotEmpty);
      expect(track.maxAccuracyDesc, isNot(gate.maxAccuracyDesc));
    });

    test('${locale.languageCode}: 「使わない」の言葉が軌跡と足切りで同じ', () async {
      final tr = await locale.build();
      expect(tr.trackRecording.off, tr.gnssQuality.settings.none);
    });
  }
}
