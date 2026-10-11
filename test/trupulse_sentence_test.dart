// 文例は LTI TruPulse 360 User's Manual 4th Edition, Section 8 p.43–45 の Examples から
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/devices/trupulse/trupulse_sentence.dart';

void main() {
  group('HT（高さ）', () {
    test('マニュアルの例: 22.10 F → メートル', () {
      final s = TruPulseSentence.parse(r'$PLTIT,HT,22.10,F*0C');
      expect(s, isA<TruPulseHeight>());
      expect((s as TruPulseHeight).heightM, closeTo(22.10 * 0.3048, 1e-9));
    });

    test('メートル設定の文（チェックサムを計算して付ける）', () {
      const body = 'PLTIT,HT,18.45,M';
      final cs = TruPulseSentence.checksum(body).toRadixString(16).toUpperCase().padLeft(2, '0');
      final s = TruPulseSentence.parse('\$$body*$cs\r\n');
      expect((s as TruPulseHeight).heightM, 18.45);
    });

    test('チェックサム違いは捨てる', () {
      expect(TruPulseSentence.parse(r'$PLTIT,HT,22.10,F*0D'), isNull);
    });

    test('値が空なら捨てる', () {
      expect(TruPulseSentence.parse(r'$PLTIT,HT,,F'), isNull);
    });
  });

  group('HV（計測）', () {
    test('高品質ターゲット（M）', () {
      final s = TruPulseSentence.parse(r'$PLTIT,HV,7.01,M,0.00,D,3.00,D,7.01,M*64') as TruPulseVector;
      expect(s.hd, 7.01);
      expect(s.az, 0.0);
      expect(s.inc, 3.0);
      expect(s.sd, 7.01);
    });

    test('フィート・ヤードはメートルに換算', () {
      final f = TruPulseSentence.parse(r'$PLTIT,HV,18.00,F,185.20,D,6.90,D,18.00,F*66') as TruPulseVector;
      expect(f.hd, closeTo(18 * 0.3048, 1e-9));
      expect(f.az, 185.2);
      final y = TruPulseSentence.parse(r'$PLTIT,HV,5.90,Y,265.70,D,11.60,D,6.00,Y*5D') as TruPulseVector;
      expect(y.sd, closeTo(6 * 0.9144, 1e-9));
    });

    test('低品質ターゲット・方位のみは距離が空なので計測にしない', () {
      expect(TruPulseSentence.parse(r'$PLTIT,HV,,,187.10,D,8.40,D,,*64'), isNull);
      expect(TruPulseSentence.parse(r'$PLTIT,HV,,,347.20,D,,,,*3F'), isNull);
    });

    test('チェックサムなしの行も読む', () {
      expect(TruPulseSentence.parse(r'$PLTIT,HV,10.00,M,90.00,D,0.00,D,10.00,M'), isA<TruPulseVector>());
    });
  });

  test('ML は連結ベクトルとして分ける（計測と混ぜない）', () {
    final s = TruPulseSentence.parse(r'$PLTIT,ML,8.10,Y,316.90,D,3.20,D,8.10,Y*74');
    expect(s, isA<TruPulseMissingLine>());
  });

  test(r'ID 応答や $OK は文として扱わない', () {
    expect(TruPulseSentence.parse(r'$PLTIT,ID,TP360 MAIN,2.42*74'), isNull);
    expect(TruPulseSentence.parse(r'$OK'), isNull);
  });
}
