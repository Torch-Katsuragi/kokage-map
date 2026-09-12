// `.qgs` インポータ（寛容側）のテスト
//
// 「読むときは寛容に」を機械的に確かめる。他人が作ったファイルは
// 古い形式で来るし、こちらでは開けない参照も混ざっている。
// **飲めるぶんだけ取り込み、飲めなかったものは必ず報告する**のが要件。
//
// ここで検証するのは、ツリーもDBも要らない純粋な部分:
//   1. OGRのデータソース文字列の分解（subset に `|` が入っても壊れない）
//   2. QGIS 3.x の `<Option>` と、それ以前の `<prop>` の両方を読む
//   3. 単位（QGISはMM、RootMapはpx）と色（R,G,B,A）の変換
//
// ツリーに View を差し込む経路は DB とファイルシステムが要るため、
// integration_test 側の担当（[[docs/technical/qgis-interop]]）。
import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:xml/xml.dart';

/// `<maplayer>` のXMLからスタイルを読む（テスト用の薄いラッパー）
KMetaLayerStyle? readStyleForTest(String maplayerXml) =>
    const QgsImporter().readStyle(XmlDocument.parse(maplayerXml).rootElement);

void main() {
  group('データソース文字列の分解', () {
    test('パスとレイヤ名を取り出す', () {
      final source = QgsDataSource.parse('./林小班.gpkg|layername=rinshoban');
      expect(source, isNotNull);
      expect(source!.path, './林小班.gpkg');
      expect(source.layerName, 'rinshoban');
      expect(source.subset, isNull);
    });

    test('subset を取り出す', () {
      final source = QgsDataSource.parse(
        "./a.gpkg|layername=t|subset=\"樹種\" = 'スギ'",
      );
      expect(source!.subset, '"樹種" = \'スギ\'');
    });

    test('subset の中に | があっても壊れない', () {
      // SQLに `|` は普通に入る（文字列連結の `||` など）
      final source = QgsDataSource.parse(
        "./a.gpkg|layername=t|subset=name || '_' = 'x_'",
      );
      expect(source!.layerName, 't');
      expect(source.subset, "name || '_' = 'x_'");
    });

    test('layername より前のキーがあっても読む', () {
      final source = QgsDataSource.parse(
        './a.gpkg|layerid=0|layername=t|geometrytype=Point',
      );
      expect(source!.layerName, 't');
    });

    test('絶対パスもそのまま返す（root外判定は呼び出し側の仕事）', () {
      final source = QgsDataSource.parse(r'C:\work\data.gpkg|layername=t');
      expect(source!.path, r'C:\work\data.gpkg');
    });

    test('空なら null', () {
      expect(QgsDataSource.parse(''), isNull);
      expect(QgsDataSource.parse('   '), isNull);
    });
  });

  group('レンダラの読み取り', () {
    /// QGIS 3.x が書く形（`<Option>`）
    const modernPoint = '''
<maplayer type="vector" geometry="Point">
  <id>l1</id>
  <datasource>./a.gpkg|layername=t</datasource>
  <layername>スギ</layername>
  <provider>ogr</provider>
  <renderer-v2 type="singleSymbol">
    <symbols>
      <symbol name="0" type="marker">
        <layer class="SimpleMarker">
          <Option type="Map">
            <Option name="color" type="QString" value="30,144,255,255"/>
            <Option name="size" type="QString" value="4"/>
          </Option>
        </layer>
      </symbol>
    </symbols>
  </renderer-v2>
</maplayer>
''';

    /// QGIS 3.x より前が書く形（`<prop>`）。**他人のファイルはこれで来る**
    const legacyLine = '''
<maplayer type="vector" geometry="Line">
  <id>l2</id>
  <datasource>./a.gpkg|layername=t</datasource>
  <layername>路網</layername>
  <provider>ogr</provider>
  <renderer-v2 type="singleSymbol">
    <symbols>
      <symbol name="0" type="line">
        <layer class="SimpleLine">
          <prop k="line_color" v="255,0,0,255"/>
          <prop k="line_width" v="1.06"/>
        </layer>
      </symbol>
    </symbols>
  </renderer-v2>
</maplayer>
''';

    test('新しい形式（Option）を読む', () {
      final style = readStyleForTest(modernPoint);
      expect(style, isNotNull);
      expect(style!.pointColor?.toARGB32(), 0xFF1E90FF);
      // QGIS の size は直径(MM)、RootMap は半径感覚の px
      expect(style.pointSize, closeTo(4 * 96 / 25.4 / 2, 0.01));
    });

    test('古い形式（prop）も読む', () {
      final style = readStyleForTest(legacyLine);
      expect(style, isNotNull);
      expect(style!.lineColor?.toARGB32(), 0xFFFF0000);
      expect(style.lineWidth, closeTo(1.06 * 96 / 25.4, 0.01));
    });

    test('塗りは色と不透明度を分けて拾う', () {
      const fill = '''
<maplayer>
  <renderer-v2 type="singleSymbol">
    <symbols>
      <symbol name="0" type="fill">
        <layer class="SimpleFill">
          <prop k="color" v="255,127,0,128"/>
          <prop k="outline_color" v="0,0,0,255"/>
          <prop k="outline_width" v="0.26"/>
        </layer>
      </symbol>
    </symbols>
  </renderer-v2>
</maplayer>
''';
      final style = readStyleForTest(fill);
      expect(style!.polygonFillColor?.toARGB32(), 0xFFFF7F00,
          reason: '色は不透明で持ち、透明度は別フィールドに分ける');
      expect(style.polygonFillOpacity, closeTo(128 / 255, 0.01));
      expect(style.polygonBorderOpacity, 1.0);
    });

    test('レンダラが無ければ null（QGISの既定に任せる）', () {
      final style = readStyleForTest(
        '<maplayer><layername>x</layername></maplayer>',
      );
      expect(style, isNull);
    });

    test('知らないシンボル型は null（黙って壊れた見た目にしない）', () {
      const weird = '''
<maplayer>
  <renderer-v2 type="singleSymbol">
    <symbols>
      <symbol name="0" type="hairline">
        <layer class="Whatever"><prop k="color" v="1,2,3,4"/></layer>
      </symbol>
    </symbols>
  </renderer-v2>
</maplayer>
''';
      expect(readStyleForTest(weird), isNull);
    });
  });

  // ---------------------------------------------------------------
  // 本物の QGIS が書いたファイル
  // ---------------------------------------------------------------
  //
  // `test/fixtures/qgis_3_44_written.qgs` は **QGIS 3.44.12 に書かせたもの**
  // （PyQGIS で生成。手順は docs/technical/qgis-interop）。
  // 手で書いたXMLでは気づけない差がここで出る。実際2件見つかっている:
  //   - 色に浮動小数表記が付く: `30,144,255,255,rgb:0.1176471,...`
  //   - `<layer>` の中に `<data_defined_properties>` があり、
  //     そこにも `name="name"` の `<Option>` が入っている
  group('QGIS 3.44 が実際に書いた .qgs', () {
    late XmlDocument doc;
    late List<XmlElement> mapLayers;

    setUpAll(() {
      doc = XmlDocument.parse(
        File('test/fixtures/qgis_3_44_written.qgs').readAsStringSync(),
      );
      mapLayers =
          doc.rootElement
              .findElements('projectlayers')
              .single
              .findElements('maplayer')
              .toList();
    });

    XmlElement layerNamed(String name) =>
        mapLayers.firstWhere((e) => e.findElements('layername').single.innerText == name);

    test('ユーザーのレイヤだけが projectlayers に入っている', () {
      // ⚠ 文書全体から maplayer を探すと `<main-annotation-layer>` まで拾う
      expect(
        mapLayers.map((e) => e.findElements('layername').single.innerText),
        ['スギ', '全部', 'root外'],
      );
    });

    test('データソースとフィルタを読める', () {
      final source = QgsDataSource.parse(
        layerNamed('スギ').findElements('datasource').single.innerText,
      );
      expect(source!.layerName, 'rinshoban');
      expect(source.subset, 'area > 105');
      expect(source.path, endsWith('.gpkg'));
    });

    test('root外への参照は相対パスで大量の .. になって出てくる', () {
      final source = QgsDataSource.parse(
        layerNamed('root外').findElements('datasource').single.innerText,
      );
      expect(source!.path, startsWith('..'),
          reason: 'この形を「root外」と判定できないと、開けない参照を取り込んでしまう');
    });

    test('色に付く浮動小数表記に引きずられない', () {
      // QGIS が書くのは `30,144,255,255,rgb:0.1176471,0.5647059,1,1`
      final style = const QgsImporter().readStyle(layerNamed('スギ'));
      expect(style, isNotNull);
      expect(style!.pointColor?.toARGB32(), 0xFF1E90FF);
    });

    test('data_defined_properties があっても size を読める', () {
      final style = const QgsImporter().readStyle(layerNamed('スギ'));
      expect(style!.pointSize, isNotNull, reason: 'size を読めていない');
      expect(style.pointSize, closeTo(4 * 96 / 25.4 / 2, 0.01));
    });

    test('入れ子の Option を拾わない', () {
      // QGIS は `<layer>` の中に `<data_defined_properties>` も書き、
      // そこにも `<Option name="name">` などが入っている。再帰で読むと
      // 本物の値を上書きしてしまう。
      //
      // 実物では衝突するキー（name / type）を今は使っていないので実害が無いが、
      // 「入れ子は読まない」を性質として固定しておく。
      const nested = '''
<maplayer>
  <renderer-v2 type="singleSymbol">
    <symbols>
      <symbol name="0" type="marker">
        <layer class="SimpleMarker">
          <Option type="Map">
            <Option name="color" type="QString" value="30,144,255,255"/>
            <Option name="size" type="QString" value="4"/>
          </Option>
          <data_defined_properties>
            <Option type="Map">
              <Option name="color" type="QString" value="0,0,0,0"/>
              <Option name="size" type="QString" value="99"/>
            </Option>
          </data_defined_properties>
        </layer>
      </symbol>
    </symbols>
  </renderer-v2>
</maplayer>
''';
      final style = readStyleForTest(nested);
      expect(style!.pointColor?.toARGB32(), 0xFF1E90FF,
          reason: 'data_defined_properties の色に上書きされている');
      expect(style.pointSize, closeTo(4 * 96 / 25.4 / 2, 0.01),
          reason: 'data_defined_properties の size に上書きされている');
    });
  });

  group('ラベルの読み戻し', () {
    XmlElement layer(String inner, {String? enabled}) => XmlDocument.parse(
          '<maplayer type="vector"${enabled == null ? '' : ' labelsEnabled="$enabled"'}>$inner</maplayer>',
        ).rootElement;
    const simple = '<labeling type="simple"><settings><text-style fieldName="FIELD" isExpression="EXPR" '
        'fontSize="9" fontSizeUnit="Point" textColor="17,34,51,255">'
        '<text-buffer bufferDraw="1" bufferColor="255,255,255,255"/></text-style></settings></labeling>';

    test('isExpression=0 の列名は "列" の式に', () {
      final style = const QgsImporter().readLabel(layer(simple.replaceAll('FIELD', 'name').replaceAll('EXPR', '0'), enabled: '1'))!;
      expect(style.labelEnabled, isTrue);
      expect(style.labelProperty, '"name"');
      expect(style.labelFontSize, closeTo(12, 0.01), reason: '9pt → 12px');
      expect(style.labelColor, const Color(0xFF112233));
      expect(style.labelHaloColor, const Color(0xFFFFFFFF));
    });

    test('式はそのまま。labelsEnabled="0" は無効', () {
      final xml = simple.replaceAll('FIELD', 'concat(&quot;a&quot;, ' ', &quot;b&quot;)').replaceAll('EXPR', '1');
      final style = const QgsImporter().readLabel(layer(xml, enabled: '0'))!;
      expect(style.labelEnabled, isFalse);
      expect(style.labelProperty, 'concat("a", ' ', "b")');
    });

    test('ラベルが無ければ null、シンボルと合成される', () {
      expect(const QgsImporter().readLabel(layer('')), isNull);
      final withBoth = layer(
        '<renderer-v2 type="singleSymbol"><symbols><symbol type="marker"><layer>'
        '<Option type="Map"><Option name="color" value="255,0,0,255"/><Option name="size" value="4"/></Option>'
        '</layer></symbol></symbols></renderer-v2>${simple.replaceAll('FIELD', 'name').replaceAll('EXPR', '0')}',
        enabled: '1',
      );
      final style = const QgsImporter().readStyleWithLabel(withBoth)!;
      expect(style.pointColor, const Color(0xFFFF0000));
      expect(style.labelProperty, '"name"');
    });
  });
}
